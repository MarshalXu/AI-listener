#!/usr/bin/env python3

import json
import pathlib
import tempfile
import unittest

from aggregate_release_rounds import aggregate
import test_benchmark as benchmark_test_helpers


class AggregateReleaseRoundsTests(unittest.TestCase):
    def fixture(self, root):
        manifest, first_result, rows = (
            benchmark_test_helpers.BenchmarkTests().valid_fixture(root)
        )
        results = [first_result]
        for index in (2, 3):
            path = root / f"results-{index}.json"
            path.write_text(json.dumps({"utterances": rows}))
            results.append(path)
        environment = root / "environment.json"
        environment.write_text(
            json.dumps(
                {
                    "hardwareModel": "Mac17,6",
                    "soc": "Apple M5 Max",
                    "memoryBytes": 51539607552,
                    "osVersion": "26.5.2",
                    "osBuild": "25F84",
                    "architecture": "arm64",
                    "toolchain": "Xcode 26.6 (17F113)",
                    "configuration": "Release",
                    "power": "AC attached; low power mode off",
                    "thermal": "no warning",
                    "modelSha256": "a" * 64,
                    "runtimeSha256": "b" * 64,
                    "peakRssBytes": [100, 110, 105],
                    "installedBytes": 200,
                }
            )
        )
        return manifest, results, environment

    def test_aggregates_exactly_three_release_rounds_without_claiming_t01(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, results, environment = self.fixture(pathlib.Path(directory))
            report = aggregate(manifest, results, environment)
            self.assertEqual(report["releaseRoundCount"], 3)
            self.assertTrue(report["allAutomaticRoundsPassed"])
            self.assertFalse(report["t01Passed"])
            self.assertEqual(
                report["rounds"][1]["peakUnifiedMemoryFraction"],
                110 / 51539607552,
            )

    def test_rejects_missing_or_duplicate_rounds(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, results, environment = self.fixture(pathlib.Path(directory))
            with self.assertRaisesRegex(ValueError, "exactly 3"):
                aggregate(manifest, results[:2], environment)
            with self.assertRaisesRegex(ValueError, "distinct"):
                aggregate(manifest, [results[0]] * 3, environment)

    def test_rejects_non_release_or_incomplete_resource_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, results, environment = self.fixture(root)
            document = json.loads(environment.read_text())
            document["configuration"] = "Debug"
            environment.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "Release"):
                aggregate(manifest, results, environment)

            del document["configuration"]
            environment.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "missing fields"):
                aggregate(manifest, results, environment)


if __name__ == "__main__":
    unittest.main()
