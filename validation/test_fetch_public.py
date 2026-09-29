"""A corrupt or unexpected benchmark archive must not replace local audio."""

import csv
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

import fetch_public


class PublicArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / "restored"
        self.destination.mkdir()
        self.original = self.destination / "cp01_01.wav"
        self.original.write_bytes(b"original")
        self.manifest = self.root / "manifest.csv"
        with self.manifest.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=["stem", "sha256"])
            writer.writeheader()
            writer.writerow({"stem": "cp01_01", "sha256": fetch_public.sha256(self.original)})
        self.members = {
            "cp01_01.wav": b"original", "manifest.csv": self.manifest.read_bytes(),
            "provenance.json": b"{}", "PUBLIC_AUDIO_LICENSES.md": b"test notice",
        }

    def restore(self):
        archive = self.root / "audio.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for name, data in self.members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                bundle.addfile(info, io.BytesIO(data))
        return fetch_public.restore(archive, self.manifest, self.destination)

    def test_exact_archive_restored(self):
        self.original.write_bytes(b"old local bytes")
        self.assertEqual(self.restore(), 1)
        self.assertEqual(self.original.read_bytes(), b"original")

    def test_changed_audio_and_manifest_preserve_destination(self):
        for name in ("cp01_01.wav", "manifest.csv"):
            with self.subTest(name=name):
                before = self.members[name]
                self.members[name] = b"changed"
                with self.assertRaises(ValueError):
                    self.restore()
                self.assertEqual(self.original.read_bytes(), b"original")
                self.members[name] = before

    def test_missing_extra_and_traversal_members_rejected(self):
        for name in ("extra.wav", "../outside.wav"):
            self.members[name] = b"unexpected"
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                self.restore()
            del self.members[name]
        del self.members["cp01_01.wav"]
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            self.restore()
        self.assertEqual(self.original.read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
