#!/usr/bin/env python3

import hashlib
import json
import pathlib
import struct
import tempfile
import unittest
import wave

from build_corpus_manifest import build_manifest


class CorpusManifestBuilderTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path):
        audio = root / "sample.wav"
        license_evidence = root / "LICENSE.txt"
        license_evidence.write_text(
            "Synthetic test fixture redistribution grant.\n", encoding="utf-8"
        )
        with wave.open(str(audio), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(16_000)
            handle.writeframes(struct.pack("<h", 0) * 16_000)
        inventory = root / "inventory.json"
        inventory.write_text(
            json.dumps(
                {
                    "corpusId": "synthetic-zh-v1",
                    "license": {
                        "name": "Test redistribution grant",
                        "redistributionAllowed": True,
                        "evidenceURL": "https://example.invalid/license",
                        "evidenceFile": license_evidence.name,
                    },
                    "utterances": [
                        {
                            "id": "clean-001",
                            "group": "clean",
                            "speakerId": "voice-01",
                            "gender": "female",
                            "audio": audio.name,
                            "reference": "本地中文听记",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return inventory, audio

    def test_measures_audio_instead_of_trusting_inventory_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, audio = self.fixture(root)
            document = build_manifest(inventory)
            utterance = document["utterances"][0]
            self.assertEqual(utterance["durationMs"], 1000)
            self.assertEqual(
                utterance["sha256"], hashlib.sha256(audio.read_bytes()).hexdigest()
            )

    def test_rejects_audio_outside_inventory_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, _ = self.fixture(root)
            document = json.loads(inventory.read_text())
            document["utterances"][0]["audio"] = "../outside.wav"
            inventory.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "escapes inventory root"):
                build_manifest(inventory)

    def test_rejects_unattested_redistribution_rights(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, _ = self.fixture(root)
            document = json.loads(inventory.read_text())
            document["license"]["redistributionAllowed"] = False
            inventory.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "redistributionAllowed"):
                build_manifest(inventory)

    def test_hash_locks_local_license_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, _ = self.fixture(root)
            document = build_manifest(inventory)
            evidence = root / "LICENSE.txt"
            self.assertEqual(document["license"]["evidenceFile"], "LICENSE.txt")
            self.assertEqual(
                document["license"]["evidenceSHA256"],
                hashlib.sha256(evidence.read_bytes()).hexdigest(),
            )

    def test_rejects_missing_empty_or_escaping_license_evidence(self):
        cases = (
            ("missing", "missing.txt", None, "evidenceFile missing"),
            ("empty", "empty.txt", b"", "must not be empty"),
            ("escape", "../outside.txt", b"grant", "escapes inventory root"),
        )
        for name, relative_path, contents, message in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                inventory, _ = self.fixture(root)
                document = json.loads(inventory.read_text())
                document["license"]["evidenceFile"] = relative_path
                inventory.write_text(json.dumps(document))
                if contents is not None:
                    target = (root / relative_path).resolve()
                    target.write_bytes(contents)
                with self.assertRaisesRegex(ValueError, message):
                    build_manifest(inventory)

    def test_rejects_non_conforming_audio_format(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, audio = self.fixture(root)
            with wave.open(str(audio), "wb") as handle:
                handle.setnchannels(2)
                handle.setsampwidth(2)
                handle.setframerate(16_000)
                handle.writeframes(struct.pack("<hh", 0, 0) * 16_000)
            with self.assertRaisesRegex(ValueError, "expected mono"):
                build_manifest(inventory)

    def test_rejects_duplicate_audio_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, _ = self.fixture(root)
            document = json.loads(inventory.read_text())
            duplicate = dict(document["utterances"][0])
            duplicate["id"] = "clean-002"
            duplicate["speakerId"] = "voice-02"
            document["utterances"].append(duplicate)
            inventory.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "duplicate audio file"):
                build_manifest(inventory)

    def test_rejects_conflicting_gender_for_speaker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inventory, _ = self.fixture(root)
            second_audio = root / "sample-2.wav"
            with wave.open(str(second_audio), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(16_000)
                handle.writeframes(struct.pack("<h", 0) * 16_000)
            document = json.loads(inventory.read_text())
            conflicting = dict(document["utterances"][0])
            conflicting["id"] = "clean-002"
            conflicting["audio"] = second_audio.name
            conflicting["gender"] = "male"
            document["utterances"].append(conflicting)
            inventory.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "conflicting gender"):
                build_manifest(inventory)


if __name__ == "__main__":
    unittest.main()
