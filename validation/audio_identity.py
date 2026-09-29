"""Identify decoded WAV samples and format independently of RIFF metadata."""

import hashlib
from pathlib import Path
import struct
import wave


def pcm_sha256(path):
    """Hash <IIIQ format fields (rate, channels, sample bytes, frames), then PCM."""
    with wave.open(str(path), "rb") as audio:
        if audio.getcomptype() != "NONE":
            raise ValueError("Expected uncompressed PCM")
        digest = hashlib.sha256(struct.pack(
            "<IIIQ", audio.getframerate(), audio.getnchannels(),
            audio.getsampwidth(), audio.getnframes(),
        ))
        remaining = audio.getnframes()
        frame_bytes = audio.getnchannels() * audio.getsampwidth()
        while remaining:
            data = audio.readframes(min(remaining, 65536))
            if not data or len(data) % frame_bytes:
                raise ValueError("Truncated PCM payload")
            remaining -= len(data) // frame_bytes
            digest.update(data)
        return digest.hexdigest()


def matches_manifest(path, row):
    try:
        if row.get("pcm_sha256"):
            return pcm_sha256(path) == row["pcm_sha256"]
        return hashlib.sha256(Path(path).read_bytes()).hexdigest() == row["sha256"]
    except (OSError, EOFError, wave.Error, ValueError):
        return False
