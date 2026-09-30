"""Regenerate release track evidence without reading the private speech tier.

Requires the preserved public WAVs downloaded by fetch_public.py.
Verifies their hashes and speaker partition, synthesizes fresh test signals,
and generates new Praat references in a temporary directory. The existing
public-voicing CI exception is recorded explicitly; its 90% target is unchanged.
"""

import argparse
import csv
import hashlib
import json
import math
import platform
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import parselmouth

import compare
import generate_references
import split
import synthesize

HERE = Path(__file__).resolve().parent
REPORT_ONLY = []


def json_safe(value):
    """Represent undefined diagnostics as JSON null, never non-standard NaN."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    return value


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_public(directory, partition_file):
    with (directory / "manifest.csv").open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    stems = [row["stem"] for row in rows]
    if not stems or len(set(stems)) != len(stems):
        raise ValueError("The public manifest must contain unique recordings")
    if any(split.corpus_of(stem) not in ("ciempiess_light", "common_voice_es") for stem in stems):
        raise ValueError("The public manifest contains an unrecognized speaker identifier")
    for row in rows:
        path = directory / f"{row['stem']}.wav"
        if not path.is_file() or sha256(path) != row["sha256"]:
            raise ValueError(f"Missing or changed public recording: {row['stem']}")
    assignment = split.partition(stems)
    expected = json.loads(partition_file.read_text(encoding="utf-8-sig"))
    if assignment != expected:
        raise ValueError("Public speaker partition differs from the committed partition")
    return rows, assignment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE / "release_report.json")
    parser.add_argument("--public-directory", type=Path, default=HERE / "wavs/public")
    args = parser.parse_args()
    output = args.out.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if parselmouth.__version__ != "0.4.7" or parselmouth.PRAAT_VERSION != "6.1.38":
        raise RuntimeError("Release references require praat-parselmouth 0.4.7 / Praat 6.1.38")

    public = args.public_directory.resolve()
    partition_file = HERE / "partition_public.json"
    rows, assignment = verify_public(public, partition_file)
    print(f"Verified {len(rows)} original public WAV hashes and {len(assignment)} speaker assignments")
    with tempfile.TemporaryDirectory(prefix="openphon_release_") as tmp:
        work = Path(tmp)
        wavs, refs = work / "wavs", work / "refs"
        synthesize.OUT = wavs
        synthesize.main()
        (wavs / "public").mkdir()
        # Copy only manifest-listed recordings. Extra local files cannot enter
        # a release score, and the participant corpus is never traversed.
        shutil.copy2(public / "manifest.csv", wavs / "public/manifest.csv")
        for row in rows:
            name = f"{row['stem']}.wav"
            shutil.copy2(public / name, wavs / "public" / name)
        generate_references.WAVS = wavs
        generate_references.REFS = refs
        generate_references.SUBDIRS = ("", "stress", "public")
        generate_references.main()
        compare.WAVS, compare.REFS = wavs, refs
        raw_report = work / "tracks.json"
        status = compare.main([
            "--split", "eval", "--json", str(raw_report),
            *(["--report-only", *REPORT_ONLY] if REPORT_ONLY else []),
        ])
        report = json.loads(raw_report.read_text())
        expected_public = sum(
            split.half_for(row["stem"], assignment) == "eval" for row in rows
        )
        if report["aggregates"].get("public", {}).get("n_recordings") != expected_public:
            raise RuntimeError("The evaluation score omitted public recordings")
        if report["aggregates"]["synth"]["n_recordings"] != len(list(wavs.glob("*.wav"))):
            raise RuntimeError("The score omitted synthetic recordings")

    checks = []
    for tier, gates in (("synth", compare.GATES), ("public", compare.REAL_GATES)):
        for metric, threshold in gates.items():
            value = report["aggregates"][tier][metric]
            relation = ">" if metric == "voicing_agreement_pct" else "<"
            checks.append({
                "tier": tier, "metric": metric, "value": value,
                "relation": relation, "threshold": threshold,
                "passed": value > threshold if relation == ">" else value < threshold,
                "enforced_in_ci": f"{tier}:{metric}" not in REPORT_ONLY,
            })
    root = HERE.parent
    sources = sorted((root / "core/src").glob("*.rs")) + [
        root / "core/Cargo.toml", root / "core/Cargo.lock",
        root / "core/examples/tracks_csv.rs",
        *[HERE / name for name in (
            "compare.py", "gridalign.py", "generate_references.py",
            "synthesize.py", "split.py", "release_check.py", "audio_identity.py", "sample_public.py",
            "fetch_public.py", "public_audio_archive.json",
        )],
    ]
    report.pop("match_tol_s", None)  # Legacy nearest-frame metadata in compare.py.
    report.update({
        "scoring": "Balanced common frame grid; see gridalign.py and coverage diagnostics",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "checks": checks,
        "all_targets_passed": all(check["passed"] for check in checks),
        "report_only": REPORT_ONLY,
        "reference": {"parselmouth": parselmouth.__version__, "praat": parselmouth.PRAAT_VERSION},
        "environment": {"python": platform.python_version(), "numpy": np.__version__,
                        "platform": platform.platform(),
                        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip()},
        "source_sha256": {str(path.relative_to(root)): sha256(path) for path in sources},
        "manifest_sha256": sha256(public / "manifest.csv"),
        "audio_identity": "SHA-256 of original WAV file bytes; sha256 column in the committed manifest",
        "partition_sha256": sha256(partition_file),
        "evaluation_speakers": sum(half == "eval" for half in assignment.values()),
    })
    output.write_text(json.dumps(json_safe(report), indent=2, allow_nan=False) + "\n")
    print(f"Release evidence: {output}")
    print(f"All numerical targets met: {report['all_targets_passed']}; CI checks passed: {not status}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
