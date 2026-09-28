"""Integrity failures must stop release scoring before references are generated."""

import csv
import json
import tempfile
import unittest
from pathlib import Path

import release_check
import split


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.audio = self.directory / "cp01_01.wav"
        self.audio.write_bytes(b"test audio content")
        self.rows = [{"stem": "cp01_01", "sha256": release_check.sha256(self.audio)}]
        self.partition = self.directory / "partition.json"
        self.partition.write_text(json.dumps(split.partition(["cp01_01"])))
        self.write_manifest()

    def write_manifest(self):
        with (self.directory / "manifest.csv").open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=["stem", "sha256"])
            writer.writeheader()
            writer.writerows(self.rows)

    def verify(self):
        return release_check.verify_public(self.directory, self.partition)

    def test_verified_manifest_ignores_unlisted_files(self):
        (self.directory / "unlisted.wav").write_bytes(b"not benchmark audio")
        rows, assignment = self.verify()
        self.assertEqual(rows, self.rows)
        self.assertEqual(assignment, split.partition(["cp01_01"]))

    def test_missing_and_modified_audio_are_rejected(self):
        self.audio.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Missing or changed"):
            self.verify()
        self.audio.unlink()
        with self.assertRaisesRegex(ValueError, "Missing or changed"):
            self.verify()

    def test_partition_drift_is_rejected(self):
        self.partition.write_text('{}')
        with self.assertRaisesRegex(ValueError, "partition differs"):
            self.verify()

    def test_empty_duplicate_and_unknown_recordings_are_rejected(self):
        for rows in ([], self.rows * 2, [{"stem": "unknown", "sha256": "unused"}]):
            with self.subTest(rows=rows):
                self.rows = rows
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.verify()

    def test_undefined_diagnostics_are_standard_json_null(self):
        value = {"diagnostics": [float("nan"), float("inf"), 0.5]}
        encoded = json.dumps(release_check.json_safe(value), allow_nan=False)
        self.assertEqual(json.loads(encoded), {"diagnostics": [None, None, 0.5]})


if __name__ == "__main__":
    unittest.main()
