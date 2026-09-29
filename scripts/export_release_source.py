#!/usr/bin/env python3
"""Copy an explicit public-source selection into a new, history-free directory.

Never copy the research repository's .git history or all of validation/.
The output must be inspected before publishing. No network operations occur.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
TOP_LEVEL = {"README.md", "LICENSE", ".gitignore", "CHANGELOG.md"}
DOCS = {"GUIDE.md", "PRIVACY.md", "VALIDATION.md", "RELEASE.md", "STORE_LISTING.md", "index.html", "privacy.html"}
VALIDATION = {
    ".gitignore", "README.md", "compare.py", "gridalign.py", "split.py",
    "synthesize.py", "generate_references.py", "sample_public.py",
    "release_check.py", "test_release_check.py", "voice_quality_check.py",
    "spectral_check.py", "formant_grid.py", "partition_public.json",
    "release_report.json", "release_voice_quality.txt", "release_spectral.txt",
    "wavs/public/manifest.csv", "wavs/public/provenance.json",
    "audio_identity.py", "test_audio_identity.py", "test_sample_public.py",
    "fetch_public.py", "test_fetch_public.py", "public_audio_archive.json", "PUBLIC_AUDIO_LICENSES.md",
}
EXCLUDED_PARTS = {
    "build", "target", ".dart_tool", ".git", ".gradle", "Pods", "ephemeral",
    "__pycache__", "xcuserdata", "node_modules",
}
PRIVATE_SUFFIXES = {".jks", ".keystore", ".p12", ".mobileprovision", ".wav", ".zip"}


def selected(path):
    if any(part in EXCLUDED_PARTS for part in path.parts):
        return False
    if path.suffix.lower() in PRIVATE_SUFFIXES:
        return False
    if path.name in {"key.properties", "local.properties", ".env"}:
        return False
    if len(path.parts) == 1:
        return path.name in TOP_LEVEL
    if path.parts[0] in {"app", "core", "cli", "scripts"}:
        return True
    if path.parts[0] == ".github":
        return path.parts[1] == "workflows"
    if path.parts[0] == "docs":
        return len(path.parts) == 2 and path.name in DOCS
    return path.parts[0] == "validation" and path.relative_to("validation").as_posix() in VALIDATION


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        parser.error("Destination must not exist; existing work is never overwritten")
    candidates = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT,
    ).decode().split("\0")
    paths = sorted({Path(name) for name in candidates if name and selected(Path(name))})
    destination.mkdir(parents=True)
    manifest = {}
    for relative in paths:
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f"Source is not a regular file: {relative}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        manifest[relative.as_posix()] = hashlib.sha256(target.read_bytes()).hexdigest()
    (destination / "SOURCE_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Copied {len(paths)} files to {destination}; no Git history was copied")


if __name__ == "__main__":
    main()
