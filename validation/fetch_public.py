"""Download the preserved public benchmark and verify exact WAV file hashes."""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile

from sample_public import _download

HERE = Path(__file__).resolve().parent


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def restore(archive, manifest, destination):
    """Stage and verify all members before replacing any destination file."""
    with manifest.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    names = [f"{row['stem']}.wav" for row in rows]
    if not names or len(set(names)) != len(names) or any(
        not re.fullmatch(r"(?:cp|cv)\d+_\d+\.wav", name) for name in names
    ):
        raise ValueError("Invalid or duplicate public recording identifiers")
    metadata = {"manifest.csv", "provenance.json", "PUBLIC_AUDIO_LICENSES.md"}
    expected = set(names) | metadata
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".public-audio-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            if (len(members) != len(expected)
                    or {member.name for member in members} != expected
                    or any(not member.isfile() for member in members)
                    or sum(member.size for member in members) > 256 * 1024 * 1024):
                raise ValueError("Unexpected public archive contents")
            for member in members:
                with bundle.extractfile(member) as source, (staging / member.name).open("wb") as output:
                    shutil.copyfileobj(source, output)
        if (staging / "manifest.csv").read_bytes() != manifest.read_bytes():
            raise ValueError("Archived manifest differs from the committed manifest")
        for row, name in zip(rows, names):
            if sha256(staging / name) != row["sha256"]:
                raise ValueError(f"Changed public recording: {row['stem']}")
        for name in sorted(expected):
            (staging / name).replace(destination / name)
    return len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path, default=HERE / "wavs/public")
    parser.add_argument("--archive", type=Path, help="Verify and restore an already downloaded archive")
    args = parser.parse_args()
    descriptor = json.loads((HERE / "public_audio_archive.json").read_text())
    with tempfile.TemporaryDirectory(prefix="openphon-public-download-") as temporary:
        archive = args.archive or Path(temporary) / "public-audio.tar.gz"
        if args.archive is None:
            _download(descriptor["url"], archive)
        if archive.stat().st_size != descriptor["bytes"] or sha256(archive) != descriptor["sha256"]:
            raise ValueError("Public archive size or SHA-256 mismatch")
        count = restore(archive, HERE / "wavs/public/manifest.csv", args.dest.resolve())
    print(f"Verified archive and all {count} original WAV file hashes")


if __name__ == "__main__":
    main()
