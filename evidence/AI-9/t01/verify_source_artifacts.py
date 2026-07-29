#!/usr/bin/env python3
"""Verify downloaded corpus archives against the reviewed source lock.

This verifier is offline. It does not extract archives and rejects unsafe tar
members before a later preparation step is allowed to consume staged sources.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import tarfile


def digest(path: pathlib.Path, algorithm: str) -> str:
    value = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def resolve_locked_evidence(
    lock_path: pathlib.Path, relative_path: object, expected_sha256: object, label: str
) -> pathlib.Path:
    if not isinstance(relative_path, str) or not relative_path:
        raise ValueError(f"{label}: evidence path missing")
    if not isinstance(expected_sha256, str) or not re.fullmatch(
        r"[0-9a-f]{64}", expected_sha256
    ):
        raise ValueError(f"{label}: invalid evidence SHA-256")
    path = (lock_path.parent.resolve() / relative_path).resolve()
    if not path.is_file():
        raise ValueError(f"{label}: evidence file missing")
    if digest(path, "sha256") != expected_sha256:
        raise ValueError(f"{label}: evidence SHA-256 mismatch")
    return path


def validate_license_evidence(lock_path: pathlib.Path, source: dict) -> dict:
    evidence = source.get("licenseEvidence")
    if not isinstance(evidence, dict):
        raise ValueError("source lock must contain licenseEvidence")
    declaration = resolve_locked_evidence(
        lock_path, evidence.get("declarationFile"),
        evidence.get("declarationSHA256"), "license declaration"
    )
    description = resolve_locked_evidence(
        lock_path, evidence.get("descriptionFile"),
        evidence.get("descriptionSHA256"), "license description"
    )
    terms = resolve_locked_evidence(
        lock_path, evidence.get("termsFile"),
        evidence.get("termsSHA256"), "license terms"
    )
    declaration_text = declaration.read_text(encoding="utf-8")
    terms_text = terms.read_text(encoding="utf-8")
    if source.get("license") != "Apache-2.0":
        raise ValueError("source license must be locked to Apache-2.0")
    if "license: Apache License v.2.0" not in declaration_text:
        raise ValueError("license declaration does not name Apache License v.2.0")
    if "Apache License" not in terms_text or "Version 2.0" not in terms_text:
        raise ValueError("license terms are not Apache License 2.0")
    if evidence.get("reviewStatus") != "evidence-locked-pending-final-corpus-review":
        raise ValueError("license review status must remain fail closed")
    return {
        "spdx": "Apache-2.0",
        "declarationSHA256": digest(declaration, "sha256"),
        "descriptionSHA256": digest(description, "sha256"),
        "termsSHA256": digest(terms, "sha256"),
        "reviewStatus": evidence["reviewStatus"],
    }


def validate_tar_members(path: pathlib.Path) -> int:
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            if not members:
                raise ValueError(f"{path.name}: archive is empty")
            for member in members:
                member_path = pathlib.PurePosixPath(member.name)
                if member_path.is_absolute() or ".." in member_path.parts:
                    raise ValueError(
                        f"{path.name}: unsafe archive member {member.name!r}"
                    )
                if member.issym() or member.islnk():
                    raise ValueError(
                        f"{path.name}: links are not accepted ({member.name!r})"
                    )
    except tarfile.TarError as error:
        raise ValueError(f"{path.name}: invalid gzip tar archive") from error
    return len(members)


def verify(lock_path: pathlib.Path, archive_directory: pathlib.Path) -> dict:
    document = json.loads(lock_path.read_text(encoding="utf-8"))
    source = document.get("source")
    if not isinstance(source, dict):
        raise ValueError("source lock must contain a source object")
    archives = source.get("archives")
    if not isinstance(archives, list) or not archives:
        raise ValueError("source lock must contain archives")

    license_report = validate_license_evidence(lock_path, source)
    results = []
    seen_names: set[str] = set()
    for item in archives:
        if not isinstance(item, dict):
            raise ValueError("every locked archive must be an object")
        name = item.get("name")
        expected_md5 = item.get("md5")
        if (
            not isinstance(name, str)
            or pathlib.PurePath(name).name != name
            or name in seen_names
        ):
            raise ValueError("locked archive names must be unique basenames")
        if not isinstance(expected_md5, str) or not re.fullmatch(
            r"[0-9a-f]{32}", expected_md5
        ):
            raise ValueError(f"{name}: invalid locked MD5")
        seen_names.add(name)
        path = archive_directory / name
        if not path.is_file():
            raise ValueError(f"{name}: locked archive missing")
        actual_md5 = digest(path, "md5")
        if actual_md5 != expected_md5:
            raise ValueError(f"{name}: MD5 mismatch")
        results.append(
            {
                "name": name,
                "md5": actual_md5,
                "sha256": digest(path, "sha256"),
                "tarMemberCount": validate_tar_members(path),
            }
        )
    return {
        "schemaVersion": 1,
        "sourceLock": lock_path.name,
        "licenseEvidence": license_report,
        "archives": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=pathlib.Path)
    parser.add_argument("--archive-directory", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    report = verify(arguments.lock.resolve(), arguments.archive_directory.resolve())
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
