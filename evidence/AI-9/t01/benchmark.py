#!/usr/bin/env python3
"""Deterministic T-01 corpus/result validator and metric calculator."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import sys
from collections import defaultdict


GROUP_TARGET_MS = 30 * 60 * 1000
MIN_SPEAKERS = 10
THRESHOLDS = {
    "cleanCER": 0.15,
    "noiseCER": 0.25,
    "rtf": 0.8,
    "partialP95Ms": 1500,
    "finalP95Ms": 3000,
}


def normalize_zh(text: str) -> str:
    return "".join(
        character.lower()
        for character in text
        if re.match(r"[\u3400-\u4dbf\u4e00-\u9fffA-Za-z0-9]", character)
    )


def edit_distance(reference: str, hypothesis: str) -> int:
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for column, actual in enumerate(hypothesis, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (expected != actual),
                )
            )
        previous = current
    return previous[-1]


def percentile95(values: list[float]) -> float:
    if not values:
        raise ValueError("latency sample list is empty")
    ordered = sorted(values)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_non_negative_number(value: object, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} must be a number")
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{field} must be finite and non-negative")
    return float(value)


def require_positive_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{field} must be a positive integer")
    return value


def require_non_empty_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value


def require_latency_samples(value: object, field: str) -> list[float]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{field} must be a non-empty list")
    return [
        require_non_negative_number(sample, f"{field}[{index}]")
        for index, sample in enumerate(value)
    ]


def validate_and_measure(manifest_path: pathlib.Path, results_path: pathlib.Path) -> dict:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    results = json.loads(results_path.read_text(encoding="utf-8"))
    base = manifest_path.parent
    errors: list[str] = []

    if manifest.get("license", {}).get("redistributionAllowed") is not True:
        errors.append("corpus license must explicitly allow redistribution")
    if not manifest.get("license", {}).get("evidenceURL"):
        errors.append("corpus license evidenceURL is required")
    evidence_relative = manifest.get("license", {}).get("evidenceFile")
    evidence_hash = manifest.get("license", {}).get("evidenceSHA256")
    if not isinstance(evidence_relative, str) or not evidence_relative.strip():
        errors.append("corpus license evidenceFile is required")
    elif not isinstance(evidence_hash, str) or not re.fullmatch(
        r"[0-9a-f]{64}", evidence_hash
    ):
        errors.append("corpus license evidenceSHA256 must be 64 lowercase hex")
    else:
        evidence_path = (base / evidence_relative).resolve()
        try:
            evidence_path.relative_to(base.resolve())
        except ValueError:
            errors.append("corpus license evidenceFile escapes corpus root")
        else:
            if not evidence_path.is_file():
                errors.append("corpus license evidenceFile is missing")
            elif sha256(evidence_path) != evidence_hash:
                errors.append("corpus license evidence hash mismatch")

    utterances = manifest.get("utterances", [])
    if not isinstance(utterances, list):
        raise ValueError("manifest utterances must be a list")
    ids = [item.get("id") for item in utterances if isinstance(item, dict)]
    if len(ids) != len(utterances) or any(not item_id for item_id in ids):
        errors.append("every corpus utterance requires a non-empty id")
    if len(set(ids)) != len(ids):
        errors.append("corpus utterance ids must be unique")
    by_id = {item_id: item for item_id, item in zip(ids, utterances) if item_id}
    grouped: dict[str, list[dict]] = defaultdict(list)
    for item in utterances:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        item_id = item["id"]
        group = item.get("group")
        if group not in ("clean", "noise"):
            errors.append(f"{item_id}: group must be clean or noise")
            continue
        try:
            speaker_id = require_non_empty_string(
                item.get("speakerId"), f"{item_id}: speakerId"
            )
            gender = require_non_empty_string(item.get("gender"), f"{item_id}: gender")
            if gender not in ("female", "male"):
                raise ValueError(f"{item_id}: gender must be female or male")
            duration_ms = require_positive_integer(
                item.get("durationMs"), f"{item_id}: durationMs"
            )
            audio_relative_path = require_non_empty_string(
                item.get("audio"), f"{item_id}: audio"
            )
            expected_sha256 = require_non_empty_string(
                item.get("sha256"), f"{item_id}: sha256"
            )
            if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
                raise ValueError(f"{item_id}: sha256 must be 64 lowercase hex characters")
            reference = require_non_empty_string(
                item.get("reference"), f"{item_id}: reference"
            )
        except ValueError as error:
            errors.append(str(error))
            continue
        validated_item = dict(item)
        validated_item.update(
            speakerId=speaker_id,
            gender=gender,
            durationMs=duration_ms,
            audio=audio_relative_path,
            sha256=expected_sha256,
            reference=reference,
        )
        grouped[group].append(validated_item)
        audio = (base / audio_relative_path).resolve()
        try:
            audio.relative_to(base.resolve())
        except ValueError:
            errors.append(f"{item_id}: audio escapes corpus root")
            continue
        if not audio.is_file():
            errors.append(f"{item_id}: audio missing")
        elif sha256(audio) != expected_sha256:
            errors.append(f"{item_id}: sha256 mismatch")
        if not normalize_zh(reference):
            errors.append(f"{item_id}: empty normalized reference")

    for group in ("clean", "noise"):
        entries = grouped[group]
        duration = sum(item.get("durationMs", 0) for item in entries)
        speakers = {item.get("speakerId") for item in entries}
        genders = {item.get("gender") for item in entries}
        if duration < GROUP_TARGET_MS:
            errors.append(f"{group}: duration {duration}ms is below {GROUP_TARGET_MS}ms")
        if len(speakers) < MIN_SPEAKERS:
            errors.append(f"{group}: speaker count {len(speakers)} is below {MIN_SPEAKERS}")
        if not {"female", "male"}.issubset(genders):
            errors.append(f"{group}: female and male speakers are required")
        if group == "noise":
            for item in entries:
                snr = item.get("snrDb")
                if not isinstance(snr, (int, float)) or not 10 <= snr <= 20:
                    errors.append(f'{item["id"]}: noise snrDb must be within 10..20')

    rows = results.get("utterances", [])
    if not isinstance(rows, list):
        raise ValueError("result utterances must be a list")
    result_ids = [row.get("id") for row in rows if isinstance(row, dict)]
    if len(result_ids) != len(rows) or any(not item_id for item_id in result_ids):
        errors.append("every result utterance requires a non-empty id")
    if len(set(result_ids)) != len(result_ids):
        errors.append("result utterance ids must be unique")
    if set(by_id) != set(result_ids):
        errors.append("result utterance ids must exactly match corpus ids")
    if errors:
        raise ValueError("; ".join(errors))

    group_edits = defaultdict(int)
    group_chars = defaultdict(int)
    total_audio_ms = 0
    total_process_ms = 0
    partial_latencies: list[float] = []
    final_latencies: list[float] = []
    for row in rows:
        source = by_id[row["id"]]
        reference = normalize_zh(source["reference"])
        hypothesis_value = row.get("hypothesis")
        if not isinstance(hypothesis_value, str):
            raise ValueError(f'{row["id"]}: hypothesis must be a string')
        hypothesis = normalize_zh(hypothesis_value)
        group = source["group"]
        group_edits[group] += edit_distance(reference, hypothesis)
        group_chars[group] += len(reference)
        total_audio_ms += source["durationMs"]
        total_process_ms += require_non_negative_number(
            row.get("processingMs"), f'{row["id"]}: processingMs'
        )
        partial_latencies.extend(
            require_latency_samples(
                row.get("partialFirstLatencyMs"),
                f'{row["id"]}: partialFirstLatencyMs',
            )
        )
        final_latencies.extend(
            require_latency_samples(
                row.get("finalLatencyMs"), f'{row["id"]}: finalLatencyMs'
            )
        )

    if not group_chars["clean"] or not group_chars["noise"]:
        raise ValueError("clean and noise groups require non-empty normalized references")
    if total_audio_ms <= 0:
        raise ValueError("total audio duration must be positive")
    metrics = {
        "cleanCER": group_edits["clean"] / group_chars["clean"],
        "noiseCER": group_edits["noise"] / group_chars["noise"],
        "rtf": total_process_ms / total_audio_ms,
        "partialP95Ms": percentile95(partial_latencies),
        "finalP95Ms": percentile95(final_latencies),
    }
    gates = {name: metrics[name] <= limit for name, limit in THRESHOLDS.items()}
    return {
        "schemaVersion": 1,
        "corpusManifestSHA256": sha256(manifest_path),
        "resultsSHA256": sha256(results_path),
        "utteranceCount": len(rows),
        "metrics": metrics,
        "thresholds": THRESHOLDS,
        "gates": gates,
        "automaticGatesPassed": all(gates.values()),
        "t01Passed": False,
        "t01PassedReason": "three-native-speaker intelligibility review is a separate required gate",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--results", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        report = validate_and_measure(arguments.manifest, arguments.results)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"benchmark validation failed: {error}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
