import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from audio_identity import matches_manifest, pcm_sha256


class AudioIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "test.wav"
        with wave.open(str(self.path), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(struct.pack("<hhh", -100, 0, 100))
        self.original = self.path.read_bytes()
        self.row = {"sha256": hashlib.sha256(self.original).hexdigest(),
                    "pcm_sha256": pcm_sha256(self.path)}

    def test_encoder_metadata_does_not_change_audio_identity(self):
        data = self.original + b"LIST" + struct.pack("<I", 16) + b"INFOISFT" + struct.pack("<I", 4) + b"new\0"
        data = data[:4] + struct.pack("<I", len(data) - 8) + data[8:]
        self.path.write_bytes(data)
        self.assertNotEqual(hashlib.sha256(data).hexdigest(), self.row["sha256"])
        self.assertTrue(matches_manifest(self.path, self.row))

    def test_changed_samples_or_sample_rate_are_rejected(self):
        for data in (self.original[:-2] + struct.pack("<h", 101),
                     self.original[:24] + struct.pack("<I", 22050) + self.original[28:]):
            self.path.write_bytes(data)
            self.assertFalse(matches_manifest(self.path, self.row))

    def test_missing_truncated_and_legacy_files(self):
        self.assertTrue(matches_manifest(self.path, {"sha256": self.row["sha256"]}))
        self.path.write_bytes(self.original[:-2])
        self.assertFalse(matches_manifest(self.path, self.row))
        self.path.unlink()
        self.assertFalse(matches_manifest(self.path, self.row))


if __name__ == "__main__":
    unittest.main()
