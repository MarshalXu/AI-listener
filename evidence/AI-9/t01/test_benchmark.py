#!/usr/bin/env python3

import hashlib
import json
import pathlib
import tempfile
import unittest

from benchmark import edit_distance, normalize_zh, percentile95, validate_and_measure


class BenchmarkTests(unittest.TestCase):
    def valid_fixture(self, root):
        utterances = []
        results = []
        license_evidence = root / "LICENSE.txt"
        license_evidence.write_text("Synthetic test redistribution grant.\n")
        for group in ("clean", "noise"):
            for index in range(10):
                audio = root / f"{group}-{index}.wav"
                audio.write_bytes(f"synthetic-{group}-{index}".encode())
                utterance_id = f"{group}-{index}"
                utterances.append(
                    {
                        "id": utterance_id,
                        "group": group,
                        "speakerId": f"{group}-speaker-{index}",
                        "gender": "female" if index % 2 == 0 else "male",
                        "durationMs": 180_000,
                        "audio": audio.name,
                        "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                        "reference": "本地实时中文听记",
                        **({"snrDb": 15} if group == "noise" else {}),
                    }
                )
                results.append(
                    {
                        "id": utterance_id,
                        "hypothesis": "本地实时中文听记",
                        "processingMs": 18_000,
                        "partialFirstLatencyMs": [400, 600],
                        "finalLatencyMs": [900],
                    }
                )
        manifest = root / "manifest.json"
        output = root / "results.json"
        manifest.write_text(
            json.dumps(
                {
                    "license": {
                        "redistributionAllowed": True,
                        "evidenceURL": "https://example.invalid/license",
                        "evidenceFile": license_evidence.name,
                        "evidenceSHA256": hashlib.sha256(
                            license_evidence.read_bytes()
                        ).hexdigest(),
                    },
                    "utterances": utterances,
                }
            )
        )
        output.write_text(json.dumps({"utterances": results}))
        return manifest, output, results

    def test_chinese_normalization_and_character_edit_distance(self):
        self.assertEqual(normalize_zh("你好，AI Listener！"), "你好ailistener")
        self.assertEqual(edit_distance("中文听记", "中文笔记"), 1)

    def test_nearest_rank_p95(self):
        self.assertEqual(percentile95(list(range(1, 101))), 95)

    def test_valid_fixture_reports_metrics_without_claiming_t01(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, output, _ = self.valid_fixture(root)
            report = validate_and_measure(manifest, output)
            self.assertTrue(report["automaticGatesPassed"])
            self.assertFalse(report["t01Passed"])
            self.assertEqual(report["metrics"]["cleanCER"], 0)
            self.assertAlmostEqual(report["metrics"]["rtf"], 0.1)

    def test_rejects_incomplete_or_unlicensed_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest = root / "manifest.json"
            results = root / "results.json"
            manifest.write_text(
                json.dumps(
                    {
                        "license": {"redistributionAllowed": False},
                        "utterances": [],
                    }
                )
            )
            results.write_text(json.dumps({"utterances": []}))
            with self.assertRaisesRegex(ValueError, "license"):
                validate_and_measure(manifest, results)

    def test_rejects_changed_license_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, output, _ = self.valid_fixture(root)
            (root / "LICENSE.txt").write_text("changed after manifest assembly\n")
            with self.assertRaisesRegex(ValueError, "license evidence hash mismatch"):
                validate_and_measure(manifest, output)

    def test_rejects_duplicate_ids_instead_of_silently_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            audio = root / "duplicate.wav"
            audio.write_bytes(b"synthetic")
            item = {
                "id": "duplicate",
                "group": "clean",
                "speakerId": "speaker",
                "gender": "female",
                "durationMs": 1_800_000,
                "audio": audio.name,
                "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                "reference": "中文",
            }
            manifest = root / "manifest.json"
            results = root / "results.json"
            manifest.write_text(
                json.dumps(
                    {
                        "license": {
                            "redistributionAllowed": True,
                            "evidenceURL": "https://example.invalid/license",
                        },
                        "utterances": [item, dict(item)],
                    }
                )
            )
            results.write_text(json.dumps({"utterances": []}))
            with self.assertRaisesRegex(ValueError, "unique"):
                validate_and_measure(manifest, results)

    def test_rejects_unknown_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            audio = root / "unknown.wav"
            audio.write_bytes(b"synthetic")
            manifest = root / "manifest.json"
            results = root / "results.json"
            manifest.write_text(
                json.dumps(
                    {
                        "license": {
                            "redistributionAllowed": True,
                            "evidenceURL": "https://example.invalid/license",
                        },
                        "utterances": [
                            {
                                "id": "unknown",
                                "group": "other",
                                "speakerId": "speaker",
                                "gender": "female",
                                "durationMs": 3_600_000,
                                "audio": audio.name,
                                "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                                "reference": "中文",
                            }
                        ],
                    }
                )
            )
            results.write_text(json.dumps({"utterances": []}))
            with self.assertRaisesRegex(ValueError, "group must be clean or noise"):
                validate_and_measure(manifest, results)

    def test_rejects_negative_processing_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, output, results = self.valid_fixture(root)
            results[0]["processingMs"] = -1
            output.write_text(json.dumps({"utterances": results}))
            with self.assertRaisesRegex(ValueError, "processingMs"):
                validate_and_measure(manifest, output)

    def test_rejects_empty_or_non_finite_latency_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, output, results = self.valid_fixture(root)
            results[0]["partialFirstLatencyMs"] = []
            output.write_text(json.dumps({"utterances": results}))
            with self.assertRaisesRegex(ValueError, "non-empty"):
                validate_and_measure(manifest, output)

            results[0]["partialFirstLatencyMs"] = [float("nan")]
            output.write_text(json.dumps({"utterances": results}))
            with self.assertRaisesRegex(ValueError, "finite"):
                validate_and_measure(manifest, output)

    def test_rejects_invalid_manifest_field_types(self):
        invalid_values = [
            ("durationMs", True, "positive integer"),
            ("durationMs", "180000", "positive integer"),
            ("speakerId", " ", "non-empty string"),
            ("gender", "unknown", "female or male"),
            ("audio", None, "non-empty string"),
            ("sha256", "ABC", "64 lowercase hex"),
            ("reference", 123, "non-empty string"),
        ]
        for field, value, expected_error in invalid_values:
            with self.subTest(field=field, value=value):
                with tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    manifest, output, _ = self.valid_fixture(root)
                    document = json.loads(manifest.read_text())
                    document["utterances"][0][field] = value
                    manifest.write_text(json.dumps(document))
                    with self.assertRaisesRegex(ValueError, expected_error):
                        validate_and_measure(manifest, output)

    def test_rejects_non_positive_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, output, _ = self.valid_fixture(root)
            document = json.loads(manifest.read_text())
            document["utterances"][0]["durationMs"] = 0
            manifest.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "positive integer"):
                validate_and_measure(manifest, output)


if __name__ == "__main__":
    unittest.main()
