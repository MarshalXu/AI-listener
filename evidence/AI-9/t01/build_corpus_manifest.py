#!/usr/bin/env python3
"""Build a deterministic T-01 corpus manifest from an explicit source inventory.

The builder does not synthesize, download, copy, or modify audio.  It only accepts
PCM WAV files below the inventory directory, measures their actual duration, and
records their content hash.  Licensing remains an explicit caller attestation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import wave


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def wav_duration_ms(path: pathlib.Path) -> int:
    try:
        with wave.open(str(path), "rb") as handle:
            if handle.getnchannels() != 1:
                raise ValueError(f"{path}: expected mono WAV")
            if handle.getsampwidth() != 2:
                raise ValueError(f"{path}: expected 16-bit PCM WAV")
            if handle.getframerate() != 16_000:
                raise ValueError(f"{path}: expected 16000 Hz WAV")
            frames = handle.getnframes()
    except wave.Error as error:
        raise ValueError(f"{path}: invalid PCM WAV: {error}") from error
    if frames <= 0:
        raise ValueError(f"{path}: WAV contains no audio frames")
    return round(frames * 1000 / 16_000)


def required_string(item: dict, field: str, item_id: str) -> str:
    value = item.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{item_id}: {field} must be a non-empty string")
    return value.strip()


def build_manifest(inventory_path: pathlib.Path) -> dict:
    inventory_path = inventory_path.resolve()
    root = inventory_path.parent
    document = json.loads(inventory_path.read_text(encoding="utf-8"))
    license_info = document.get("license")
    if not isinstance(license_info, dict):
        raise ValueError("license must be an object")
    if license_info.get("redistributionAllowed") is not True:
        raise ValueError("license.redistributionAllowed must be true")
    evidence_url = license_info.get("evidenceURL")
    if not isinstance(evidence_url, str) or not re.fullmatch(
        r"https://[^ \t\r\n]+", evidence_url
    ):
        raise ValueError("license.evidenceURL must be an HTTPS URL")
    evidence_relative = pathlib.Path(
        required_string(license_info, "evidenceFile", "license")
    )
    evidence_file = (root / evidence_relative).resolve()
    try:
        evidence_file.relative_to(root)
    except ValueError as error:
        raise ValueError("license: evidenceFile escapes inventory root") from error
    if not evidence_file.is_file():
        raise ValueError("license: evidenceFile missing")
    if evidence_file.stat().st_size == 0:
        raise ValueError("license: evidenceFile must not be empty")

    sources = document.get("utterances")
    if not isinstance(sources, list) or not sources:
        raise ValueError("utterances must be a non-empty list")

    output = []
    seen_ids: set[str] = set()
    seen_audio: set[pathlib.Path] = set()
    speaker_genders: dict[str, str] = {}
    for source in sources:
        if not isinstance(source, dict):
            raise ValueError("every utterance must be an object")
        item_id = required_string(source, "id", "utterance")
        if item_id in seen_ids:
            raise ValueError(f"{item_id}: duplicate id")
        seen_ids.add(item_id)
        group = source.get("group")
        if group not in ("clean", "noise"):
            raise ValueError(f"{item_id}: group must be clean or noise")
        relative_audio = pathlib.Path(required_string(source, "audio", item_id))
        audio = (root / relative_audio).resolve()
        try:
            audio.relative_to(root)
        except ValueError as error:
            raise ValueError(f"{item_id}: audio escapes inventory root") from error
        if not audio.is_file():
            raise ValueError(f"{item_id}: audio missing")
        if audio in seen_audio:
            raise ValueError(f"{item_id}: duplicate audio file")
        seen_audio.add(audio)

        gender = required_string(source, "gender", item_id)
        if gender not in ("female", "male"):
            raise ValueError(f"{item_id}: gender must be female or male")
        speaker_id = required_string(source, "speakerId", item_id)
        existing_gender = speaker_genders.get(speaker_id)
        if existing_gender is not None and existing_gender != gender:
            raise ValueError(f"{item_id}: speakerId has conflicting gender")
        speaker_genders[speaker_id] = gender
        item = {
            "id": item_id,
            "group": group,
            "speakerId": speaker_id,
            "gender": gender,
            "durationMs": wav_duration_ms(audio),
            "audio": relative_audio.as_posix(),
            "sha256": sha256(audio),
            "reference": required_string(source, "reference", item_id),
        }
        if group == "noise":
            snr = source.get("snrDb")
            if isinstance(snr, bool) or not isinstance(snr, (int, float)):
                raise ValueError(f"{item_id}: noise snrDb must be numeric")
            item["snrDb"] = snr
        output.append(item)

    return {
        "schemaVersion": 1,
        "corpusId": required_string(document, "corpusId", "inventory"),
        "license": {
            "name": required_string(license_info, "name", "license"),
            "redistributionAllowed": True,
            "evidenceURL": evidence_url,
            "evidenceFile": evidence_relative.as_posix(),
            "evidenceSHA256": sha256(evidence_file),
        },
        "utterances": output,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    manifest = build_manifest(arguments.inventory)
    arguments.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
