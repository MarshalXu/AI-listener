#!/usr/bin/env python3

import io
import json
import pathlib
import tarfile
import tempfile
import unittest

from verify_source_artifacts import digest, validate_license_evidence, verify


class SourceArtifactVerifierTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path, member_name: str = "resource/file.txt"):
        archive = root / "resource.tgz"
        with tarfile.open(archive, "w:gz") as handle:
            contents = b"official public fixture"
            info = tarfile.TarInfo(member_name)
            info.size = len(contents)
            handle.addfile(info, io.BytesIO(contents))
        lock = root / "lock.json"
        declaration = root / "info.txt"
        declaration.write_text("license: Apache License v.2.0\n", encoding="utf-8")
        description = root / "about.html"
        description.write_text("public corpus description\n", encoding="utf-8")
        terms = root / "LICENSE"
        terms.write_text(
            "Apache License\nVersion 2.0, January 2004\n", encoding="utf-8"
        )
        lock.write_text(
            json.dumps(
                {
                    "source": {
                        "license": "Apache-2.0",
                        "licenseEvidence": {
                            "declarationFile": declaration.name,
                            "declarationSHA256": digest(declaration, "sha256"),
                            "descriptionFile": description.name,
                            "descriptionSHA256": digest(description, "sha256"),
                            "termsFile": terms.name,
                            "termsSHA256": digest(terms, "sha256"),
                            "reviewStatus": "evidence-locked-pending-final-corpus-review",
                        },
                        "archives": [
                            {
                                "name": archive.name,
                                "md5": digest(archive, "md5"),
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        return lock, archive

    def test_emits_md5_sha256_and_member_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            lock, archive = self.fixture(root)
            report = verify(lock, root)
            self.assertEqual(report["archives"][0]["md5"], digest(archive, "md5"))
            self.assertEqual(
                report["archives"][0]["sha256"], digest(archive, "sha256")
            )
            self.assertEqual(report["archives"][0]["tarMemberCount"], 1)
            self.assertEqual(report["licenseEvidence"]["spdx"], "Apache-2.0")

    def test_rejects_changed_or_missing_archive(self):
        for mode, expected in (("changed", "MD5 mismatch"), ("missing", "missing")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                lock, archive = self.fixture(root)
                if mode == "changed":
                    archive.write_bytes(archive.read_bytes() + b"changed")
                else:
                    archive.unlink()
                with self.assertRaisesRegex(ValueError, expected):
                    verify(lock, root)

    def test_rejects_changed_or_unreviewed_license_evidence(self):
        for mode, expected in (
            ("changed", "evidence SHA-256 mismatch"),
            ("unreviewed", "review status"),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                lock, _ = self.fixture(root)
                document = json.loads(lock.read_text(encoding="utf-8"))
                evidence = document["source"]["licenseEvidence"]
                if mode == "changed":
                    (root / evidence["declarationFile"]).write_text(
                        "license: unknown\n", encoding="utf-8"
                    )
                else:
                    evidence["reviewStatus"] = "approved"
                    lock.write_text(json.dumps(document), encoding="utf-8")
                current = json.loads(lock.read_text(encoding="utf-8"))
                with self.assertRaisesRegex(ValueError, expected):
                    validate_license_evidence(lock, current["source"])

    def test_rejects_path_traversal_member(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            lock, _ = self.fixture(root, "../escape.txt")
            with self.assertRaisesRegex(ValueError, "unsafe archive member"):
                verify(lock, root)


if __name__ == "__main__":
    unittest.main()
