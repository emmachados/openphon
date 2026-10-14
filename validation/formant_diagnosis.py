"""Diagnose bandwidth rejection against known synthesis poles only.

Rebuild the native tracks_csv example, synthesize the 19-file tier and the
252-cell formant grid in temporary storage, and compare raw/default tracks.
No public or private speech, reference cache, or Praat source is read.
"""

import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from compare import FORMANT_TRUTH, assign_poles, build_core_binary, read_csv
from formant_evidence import score_truth, summarize_errors
import synthesize

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MAX_BANDWIDTH_HZ = 400.0


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def frequency_regions(poles):
    """Midpoint-bounded regions around known poles; these are not an estimator."""
    poles = np.asarray(poles, dtype=float)
    boundaries = np.r_[50.0, (poles[:-1] + poles[1:]) / 2, 5450.0]
    return list(zip(boundaries[:-1], boundaries[1:]))


def diagnose_regions(raw, bandwidth, shipped, truth):
    """Keep filter-caused candidate loss separate from labelled-slot errors."""
    result = {}
    for k in range(truth.shape[1]):
        counts = {"n_frames": len(truth), "n_raw_region_empty": 0,
                  "n_shipped_region_empty": 0, "n_region_emptied_by_filter": 0}
        rejected_error, rejected_bandwidth = [], []
        for source, widths, filtered, poles in zip(raw, bandwidth, shipped, truth):
            lo, hi = frequency_regions(poles)[k]
            candidates = np.flatnonzero((source > lo) & (source < hi))
            survivors = np.flatnonzero((filtered > lo) & (filtered < hi))
            counts["n_raw_region_empty"] += int(not len(candidates))
            counts["n_shipped_region_empty"] += int(not len(survivors))
            counts["n_region_emptied_by_filter"] += int(bool(len(candidates)) and not len(survivors))
            if len(candidates):
                nearest = min(candidates, key=lambda i: abs(source[i] - poles[k]))
                if widths[nearest] > MAX_BANDWIDTH_HZ:
                    rejected_error.append(float(source[nearest] - poles[k]))
                    rejected_bandwidth.append(float(widths[nearest]))
        counts["n_rejected_nearest_candidates"] = len(rejected_error)
        errors = summarize_errors(rejected_error, len(rejected_error))
        counts["nearest_rejected_error"] = {key: errors[key] for key in
                                            ("median_abs_err_hz", "rmse_hz")}
        counts["nearest_rejected_bandwidth_median_hz"] = (
            float(np.median(rejected_bandwidth)) if rejected_bandwidth else None)
        result[f"F{k + 1}"] = counts
    return result


def labelled_errors(values, truth):
    """Keep this diagnosis compact; the full grid report retains all metrics."""
    scores = score_truth(values, truth)["labelled"]
    fields = ("n", "n_missing", "median_abs_err_hz", "rmse_hz", "p95_abs_err_hz")
    return {"labelled": {slot: {field: result[field] for field in fields}
                          for slot, result in scores.items() if slot in ("F1", "F2", "F3")}}


def representative(raw, shipped, truth_fn):
    times = raw["time_s"]
    middle = (times[0] + times[-1]) / 2
    i = int(np.argmin(np.abs(times - middle)))
    candidates = [{"slot": k, "frequency_hz": float(raw[f"f{k}_hz"][i]),
                   "bandwidth_hz": float(raw[f"b{k}_hz"][i]),
                   "passes_400_hz": bool(raw[f"b{k}_hz"][i] <= MAX_BANDWIDTH_HZ)}
                  for k in range(1, 6) if raw[f"f{k}_hz"][i] > 0]
    return {"frame_index": i, "time_s": float(times[i]),
            "known_poles_hz": list(truth_fn(times[i])), "raw_candidates": candidates,
            "shipped_slots_hz": [float(shipped[f"f{k}_hz"][i]) for k in range(1, 6)]}


def cutoff_conflict(resonance_frame, extra_frame, resonance_index=2):
    """Inspect a fixed pair of examples without searching for a new cutoff.

    The resonance case asks which cutoff would retain any candidate in its
    known-pole frequency region. The other case reports extra candidates
    excluded by monotone assignment to its known poles. The extra-candidate
    assignment is an explanatory diagnostic, not a deployable label rule.
    """
    poles = resonance_frame["known_poles_hz"]
    lo, hi = frequency_regions(poles)[resonance_index]
    nearby = [c for c in resonance_frame["raw_candidates"] if lo < c["frequency_hz"] < hi]
    required = min((c["bandwidth_hz"] for c in nearby), default=None)
    extra_candidates = extra_frame["raw_candidates"]
    assigned = assign_poles([c["frequency_hz"] for c in extra_candidates],
                            extra_frame["known_poles_hz"])
    used = {i for i in assigned if i is not None}
    extras = [c for i, c in enumerate(extra_candidates) if i not in used]
    admitted = [c for c in extras if required is not None and c["bandwidth_hz"] <= required]
    return {"resonance_case": "vg_f1300_f2900_f0400_p5", "extra_case": "child_i_400",
            "resonance_frame": resonance_frame, "extra_frame": extra_frame,
            "target_pole_hz": poles[resonance_index], "region_hz": [float(lo), float(hi)],
            "minimum_cutoff_to_retain_a_candidate_in_region_hz": required,
            "extra_candidates_admitted_at_that_cutoff": admitted,
            "conflict_in_this_configuration": bool(admitted) if required is not None else None,
            "interpretation": "Both signals have F0=400 Hz. If conflict is true, a cutoff depending only "
                              "on bandwidth and F0 cannot retain a candidate in the known resonance "
                              "region while rejecting these extra candidates at the two recorded frames."}


def summarize(rows):
    result = {}
    for tier in ("synth", "grid"):
        selected = [r for r in rows if r["tier"] == tier]
        groups = {"all": selected}
        if tier == "grid":
            groups.update({f"f0={int(f0)}": [r for r in selected if r["cell"]["f0_hz"] == f0]
                           for f0 in sorted({r["cell"]["f0_hz"] for r in selected})})
        result[tier] = {}
        for name, cells in groups.items():
            result[tier][name] = {}
            for k in ("F1", "F2", "F3"):
                pairs = [(r["raw"]["labelled"][k]["rmse_hz"],
                          r["shipped"]["labelled"][k]["rmse_hz"]) for r in cells]
                comparable = [(raw, shipped) for raw, shipped in pairs
                              if raw is not None and shipped is not None]
                result[tier][name][k] = {
                    "n_recordings": len(cells),
                    "n_frames": sum(r["truth_regions"][k]["n_frames"] for r in cells),
                    "n_region_emptied_by_filter": sum(r["truth_regions"][k]["n_region_emptied_by_filter"] for r in cells),
                    "n_labelled_rmse_improved": sum(shipped < raw for raw, shipped in comparable),
                    "n_labelled_rmse_worsened": sum(shipped > raw for raw, shipped in comparable),
                    "n_labelled_rmse_uncomparable": len(pairs) - len(comparable),
                }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE / "release_formant_diagnosis.json")
    args = parser.parse_args()
    sources = sorted((ROOT / "core/src").glob("*.rs")) + [
        ROOT / "core/Cargo.toml", ROOT / "core/Cargo.lock", ROOT / "core/examples/tracks_csv.rs",
        HERE / "formant_diagnosis.py", HERE / "compare.py", HERE / "synthesize.py",
        HERE / "formant_evidence.py",
    ]
    source_hashes = {str(p.relative_to(ROOT)): sha256(p) for p in sources}
    exe = build_core_binary()
    params = json.loads(subprocess.check_output([str(exe), "--params"], text=True))
    if params["formant_max_bandwidth_hz"] != MAX_BANDWIDTH_HZ:
        raise ValueError("This diagnosis requires the unchanged 400 Hz default")
    rows = []
    with tempfile.TemporaryDirectory(prefix="openphon_formant_diagnosis_") as tmp:
        work = Path(tmp)
        synthesize.OUT = work / "wavs"
        synthesize.main()
        synthesize.write_grid()
        grid_truth_path = synthesize.OUT / "formantgrid/truth.json"
        grid_truth = json.loads(grid_truth_path.read_text())
        items = [(c["stem"], synthesize.OUT / "formantgrid" / f"{c['stem']}.wav", "grid",
                  lambda t, poles=c["poles_hz"]: poles, c) for c in grid_truth["cells"]]
        for wav in sorted(synthesize.OUT.glob("*.wav")):
            if wav.stem not in FORMANT_TRUTH:
                raise ValueError(f"Missing synthesis pole truth for {wav.stem}")
            items.append((wav.stem, wav, "synth", FORMANT_TRUTH[wav.stem], {}))
        native = work / "native"
        native.mkdir()
        for index, (stem, wav, tier, truth_fn, cell) in enumerate(items, 1):
            tracks = {}
            for config, arguments in (("raw", ["raw"]), ("shipped", [])):
                subprocess.run([str(exe), str(wav), str(native), *arguments],
                               check=True, capture_output=True)
                tracks[config] = read_csv(native / f"{stem}.formant.csv")
            raw, shipped = tracks["raw"], tracks["shipped"]
            if not np.array_equal(raw["time_s"], shipped["time_s"]):
                raise ValueError(f"Raw/shipped grids differ in {stem}")
            for k in range(1, 6):
                if f"b{k}_hz" not in raw:
                    raise ValueError("Native tracks_csv must include raw candidate bandwidths")
            times = raw["time_s"]
            margin = 0.06 if tier == "grid" else 0.05
            mask = (times >= margin) & (times <= times.max() - margin)
            truth = np.array([truth_fn(t) for t in times[mask]])
            F = np.column_stack([raw[f"f{k}_hz"] for k in range(1, 6)])[mask]
            B = np.column_stack([raw[f"b{k}_hz"] for k in range(1, 6)])[mask]
            G = np.column_stack([shipped[f"f{k}_hz"] for k in range(1, 6)])[mask]
            rows.append({"stem": stem, "tier": tier, "cell": cell, "audio_sha256": sha256(wav),
                         "margin_s": margin, "raw": labelled_errors(F, truth),
                         "shipped": labelled_errors(G, truth),
                         "truth_regions": diagnose_regions(F, B, G, truth),
                         "representative": representative(raw, shipped, truth_fn)})
            if index % 25 == 0:
                print(f"  {index}/{len(items)}", flush=True)
        truth_hash = sha256(grid_truth_path)
    if source_hashes != {str(p.relative_to(ROOT)): sha256(p) for p in sources}:
        raise RuntimeError("Diagnostic sources changed during the run; no report written")
    examples = {r["stem"]: r["representative"] for r in rows}
    selected = {"vg_f1300_f2900_f0400_p5", "child_i_400", "male_a_110_natural"}
    for tier in ("grid", "synth"):
        for slot in ("F2", "F3"):
            eligible = [r for r in rows if r["tier"] == tier
                        and r["shipped"]["labelled"][slot]["rmse_hz"] is not None]
            selected.update(r["stem"] for r in sorted(
                eligible, key=lambda r: r["shipped"]["labelled"][slot]["rmse_hz"],
                reverse=True)[:5 if tier == "grid" else 2])
    for row in rows:
        if row["stem"] not in selected:
            row.pop("representative")
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "n_grid_cells": sum(r["tier"] == "grid" for r in rows),
        "n_synthetic_files": sum(r["tier"] == "synth" for r in rows),
        "operating_point": params,
        "source_sha256": source_hashes, "native_binary_sha256": sha256(exe),
        "grid_truth_sha256": truth_hash,
        "environment": {"python": platform.python_version(), "numpy": np.__version__,
                        "platform": platform.platform(),
                        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip()},
        "frequency_serialization_resolution_hz": 0.001,
        "bandwidth_serialization": "Full-precision native float",
        "scope": "Fresh synthetic signals only; no public evaluation or private speech",
        "region_rule": "Frequency regions are bounded by adjacent known-pole midpoints and 50/5450 Hz. "
                       "Their emptiness diagnoses candidate loss, not anatomical identity on natural speech.",
        "summary": summarize(rows),
        "fixed_example_cutoff_check": cutoff_conflict(examples["vg_f1300_f2900_f0400_p5"], examples["child_i_400"]),
        "per_file": rows,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Diagnostic evidence: {args.out}")
    print(f"Core formant source SHA-256: {source_hashes['core/src/formant.rs']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
