#!/usr/bin/env python3
"""Fail-closed aggregation for the three required T-01 Release rounds."""

from __future__ import annotations

import argparse
import json
import pathlib

from benchmark import sha256, validate_and_measure


REQUIRED_ROUNDS = 3


def aggregate(
    manifest_path: pathlib.Path,
    result_paths: list[pathlib.Path],
    environment_path: pathlib.Path,
) -> dict:
    if len(result_paths) != REQUIRED_ROUNDS:
        raise ValueError(f"exactly {REQUIRED_ROUNDS} result files are required")
    if len({path.resolve() for path in result_paths}) != REQUIRED_ROUNDS:
        raise ValueError("result files must be distinct")

    environment = json.loads(environment_path.read_text(encoding="utf-8"))
    required_environment = {
        "hardwareModel",
        "soc",
        "memoryBytes",
        "osVersion",
        "osBuild",
        "architecture",
        "toolchain",
        "configuration",
        "power",
        "thermal",
        "modelSha256",
        "runtimeSha256",
        "peakRssBytes",
        "installedBytes",
    }
    missing = sorted(required_environment - environment.keys())
    if missing:
        raise ValueError(f"environment evidence missing fields: {', '.join(missing)}")
    if environment["configuration"] != "Release":
        raise ValueError("configuration must be Release")
    if not isinstance(environment["memoryBytes"], int) or environment["memoryBytes"] <= 0:
        raise ValueError("memoryBytes must be a positive integer")
    if (
        not isinstance(environment["peakRssBytes"], list)
        or len(environment["peakRssBytes"]) != REQUIRED_ROUNDS
        or any(
            isinstance(value, bool) or not isinstance(value, int) or value <= 0
            for value in environment["peakRssBytes"]
        )
    ):
        raise ValueError("peakRssBytes must contain three positive integers")
    if not isinstance(environment["installedBytes"], int) or environment["installedBytes"] <= 0:
        raise ValueError("installedBytes must be a positive integer")

    rounds = [
        validate_and_measure(manifest_path, result_path)
        for result_path in result_paths
    ]
    manifest_hashes = {round_report["corpusManifestSHA256"] for round_report in rounds}
    if len(manifest_hashes) != 1:
        raise ValueError("rounds did not use the same corpus manifest")

    for index, report in enumerate(rounds, 1):
        report["round"] = index
        report["peakRssBytes"] = environment["peakRssBytes"][index - 1]
        report["peakUnifiedMemoryFraction"] = (
            report["peakRssBytes"] / environment["memoryBytes"]
        )

    return {
        "schemaVersion": 1,
        "releaseRoundCount": REQUIRED_ROUNDS,
        "corpusManifestSHA256": rounds[0]["corpusManifestSHA256"],
        "environmentSHA256": sha256(environment_path),
        "environment": environment,
        "rounds": rounds,
        "allAutomaticRoundsPassed": all(
            report["automaticGatesPassed"] for report in rounds
        ),
        "t01Passed": False,
        "t01PassedReason": (
            "three-native-speaker intelligibility review is a separate required gate"
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--results", required=True, type=pathlib.Path, nargs="+")
    parser.add_argument("--environment", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    report = aggregate(arguments.manifest, arguments.results, arguments.environment)
    arguments.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
