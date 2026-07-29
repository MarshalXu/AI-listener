#!/usr/bin/env python3
"""Prepare the fixed T-01 AISHELL-1 clean/noise inventory.

This program is intentionally offline. It reads an already extracted AISHELL-1
tree, deterministically selects test utterances across speakers/genders, copies
clean PCM, and creates a distinct office-ambience derivative at 15 dB SNR.
The separate build_corpus_manifest.py remains the trust boundary for measuring
duration and hashing every output.
"""

from __future__ import annotations

import argparse
import audioop
import json
import math
import pathlib
import random
import shutil
import struct
import wave

MINIMUM_MS = 30 * 60 * 1000
SNR_DB = 15.0
SEED = 20260729


def find_one(root: pathlib.Path, name: str) -> pathlib.Path:
    matches = sorted(root.rglob(name))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def read_transcripts(root: pathlib.Path) -> dict[str, str]:
    path = find_one(root, "aishell_transcript_v0.8.txt")
    transcripts: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2:
            transcripts[parts[0]] = parts[1].replace(" ", "")
    if not transcripts:
        raise ValueError("transcript file contains no entries")
    return transcripts


def read_genders(root: pathlib.Path) -> dict[str, str]:
    path = find_one(root, "speaker.info")
    genders: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        fields = line.strip().replace("\t", " ").split()
        if len(fields) < 2:
            continue
        speaker = fields[0]
        labels = {field.lower() for field in fields[1:]}
        gender = "female" if labels & {"f", "female"} else "male" if labels & {"m", "male"} else None
        if gender:
            genders[speaker] = gender
    if not genders:
        raise ValueError("speaker.info contains no recognized gender rows")
    return genders


def pcm(path: pathlib.Path) -> tuple[bytes, int]:
    with wave.open(str(path), "rb") as handle:
        if (
            handle.getnchannels(),
            handle.getsampwidth(),
            handle.getframerate(),
            handle.getcomptype(),
        ) != (1, 2, 16_000, "NONE"):
            raise ValueError(f"{path}: expected mono 16-bit 16 kHz PCM WAV")
        frames = handle.readframes(handle.getnframes())
    if not frames:
        raise ValueError(f"{path}: empty audio")
    return frames, round(len(frames) / 2 * 1000 / 16_000)


def office_noise(sample_count: int, seed: int) -> bytes:
    rng = random.Random(seed)
    samples = []
    for index in range(sample_count):
        # HVAC hum plus broad ventilation noise and sparse keyboard-like impulses.
        hum = 1800 * math.sin(2 * math.pi * 60 * index / 16_000)
        ventilation = rng.uniform(-900, 900)
        impulse = rng.choice((-5000, 5000)) if rng.random() < 0.0008 else 0
        samples.append(max(-32768, min(32767, round(hum + ventilation + impulse))))
    return struct.pack(f"<{sample_count}h", *samples)


def mix_at_snr(clean: bytes, seed: int, snr_db: float = SNR_DB) -> bytes:
    noise = office_noise(len(clean) // 2, seed)
    clean_rms = audioop.rms(clean, 2)
    noise_rms = audioop.rms(noise, 2)
    if clean_rms == 0 or noise_rms == 0:
        raise ValueError("cannot derive SNR from silent input")
    target_noise_rms = clean_rms / (10 ** (snr_db / 20))
    scaled_noise = audioop.mul(noise, 2, target_noise_rms / noise_rms)
    return audioop.add(clean, scaled_noise, 2)


def write_wav(path: pathlib.Path, frames: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16_000)
        handle.writeframes(frames)


def select(source: pathlib.Path) -> list[tuple[pathlib.Path, str, str, str, bytes, int]]:
    transcripts = read_transcripts(source)
    genders = read_genders(source)
    wavs = sorted(path for path in source.rglob("*.wav") if "test" in path.parts)
    by_speaker: dict[str, list[pathlib.Path]] = {}
    for path in wavs:
        speaker = path.parent.name
        if speaker in genders and path.stem in transcripts:
            by_speaker.setdefault(speaker, []).append(path)
    female = sorted(s for s in by_speaker if genders[s] == "female")[:5]
    male = sorted(s for s in by_speaker if genders[s] == "male")[:5]
    speakers = female + male
    if len(female) < 5 or len(male) < 5:
        raise ValueError("test split needs at least five female and five male speakers")
    chosen = []
    elapsed = 0
    position = 0
    while elapsed < MINIMUM_MS:
        progressed = False
        for speaker in speakers:
            items = by_speaker[speaker]
            if position >= len(items):
                continue
            path = items[position]
            frames, duration = pcm(path)
            chosen.append((path, path.stem, speaker, genders[speaker], frames, duration))
            elapsed += duration
            progressed = True
        if not progressed:
            raise ValueError(f"selected speakers provide only {elapsed} ms")
        position += 1
    return chosen


def prepare(source: pathlib.Path, output: pathlib.Path, license_snapshot: pathlib.Path) -> dict:
    if output.exists() and any(output.iterdir()):
        raise ValueError("output directory must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    snapshot_target = output / "LICENSE-AISHELL-1.txt"
    shutil.copyfile(license_snapshot, snapshot_target)
    transcripts = read_transcripts(source)
    utterances = []
    for index, (path, item_id, speaker, gender, frames, _) in enumerate(select(source)):
        clean_name = pathlib.Path("audio/clean") / f"{item_id}.wav"
        noise_name = pathlib.Path("audio/noise") / f"{item_id}-office-snr15.wav"
        write_wav(output / clean_name, frames)
        write_wav(output / noise_name, mix_at_snr(frames, SEED + index))
        common = {"speakerId": speaker, "gender": gender, "reference": transcripts[item_id]}
        utterances.append({"id": f"clean-{item_id}", "group": "clean", "audio": clean_name.as_posix(), **common})
        utterances.append({"id": f"noise-{item_id}", "group": "noise", "audio": noise_name.as_posix(), "snrDb": SNR_DB, **common})
    inventory = {
        "corpusId": "ai-listener-t01-aishell1-test-clean-office-snr15-v1",
        "license": {
            "name": "Apache-2.0",
            "redistributionAllowed": True,
            "evidenceURL": "https://www.aishelltech.com/kysjcp",
            "evidenceFile": snapshot_target.name,
        },
        "utterances": utterances,
    }
    (output / "inventory.json").write_text(
        json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return inventory


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--license-snapshot", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    prepare(arguments.source.resolve(), arguments.output.resolve(), arguments.license_snapshot.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
