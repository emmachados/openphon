"""Evaluate one fixed temporal selector without changing production selection.

The protocol is written before scoring. Accuracy uses labelled synthesis
resonances; missing outputs and paired-support errors remain explicit. The
no-continuity ablation distinguishes the frequency prior from temporal costs.
An unsuccessful experiment is a valid report, not a CI failure. Missing data,
changed sources and incomplete coverage are errors.
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

from compare import build_core_binary, read_csv
from formant_evidence import summarize_errors
import formant_transitions as transitions
import synthesize
from temporal_formants import TemporalConfig, select_tracks

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
METHODS = ("native_default", "temporal", "no_continuity")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def errors_for(values, truth):
    values, truth = np.asarray(values), np.asarray(truth)
    if values.shape != truth.shape or values.ndim != 2 or values.shape[1] != 3:
        raise ValueError("Scoring requires equally shaped, labelled F1-F3 arrays")
    if not np.all(np.isfinite(truth) & (truth > 0)):
        raise ValueError("Synthesis truth must be finite and positive")
    present = np.isfinite(values) & (values > 0)
    return np.where(present, values - truth, np.nan)


def summarize_matrix(errors):
    return {f"F{k + 1}": summarize_errors(column[np.isfinite(column)], len(column))
            for k, column in enumerate(np.asarray(errors).T)}


def coverage_changes(errors):
    baseline = np.isfinite(errors["native_default"])
    candidate = np.isfinite(errors["temporal"])
    return {f"F{k + 1}": {
        "baseline_present_temporal_missing": int(np.sum(baseline[:, k] & ~candidate[:, k])),
        "baseline_missing_temporal_present": int(np.sum(~baseline[:, k] & candidate[:, k])),
    } for k in range(3)}


def score_methods(values, truth):
    errors = {method: errors_for(values[method], truth) for method in METHODS}
    common = np.isfinite(errors["native_default"]) & np.isfinite(errors["temporal"])
    return {
        "methods": {method: summarize_matrix(value) for method, value in errors.items()},
        "common_support": {
            method: summarize_matrix(np.where(common, errors[method], np.nan))
            for method in ("native_default", "temporal")
        },
        "coverage_changes": coverage_changes(errors),
        "_errors": errors,
    }


def aggregate(cases):
    groups = sorted({group for case in cases for group in case["groups"]})
    result = {}
    for group in groups:
        chosen = [case for case in cases if group in case["groups"]]
        joined = {method: np.concatenate([case["_errors"][method] for case in chosen])
                  for method in METHODS}
        common = np.isfinite(joined["native_default"]) & np.isfinite(joined["temporal"])
        result[group] = {
            "n_recordings": len(chosen),
            "coverage_changes": coverage_changes(joined),
            "methods": {method: summarize_matrix(value) for method, value in joined.items()},
            "common_support": {
                method: summarize_matrix(np.where(common, joined[method], np.nan))
                for method in ("native_default", "temporal")
            },
        }
    return result


def acceptance(aggregates, protocol):
    """Apply the declared rule and audit exchanges of covered observations."""
    tolerance = protocol["acceptance"]["numerical_tolerance_hz"]
    checks = []
    for group in protocol["acceptance"]["required_groups"]:
        row = aggregates[group]
        for slot in ("F1", "F2", "F3"):
            baseline, candidate = (row["methods"][method][slot]
                                   for method in ("native_default", "temporal"))
            paired_baseline, paired_candidate = (row["common_support"][method][slot]
                                                 for method in ("native_default", "temporal"))
            supported = all(item["n"] > 0 for item in
                            (baseline, candidate, paired_baseline, paired_candidate))
            checks.append({
                "group": group, "slot": slot,
                "observed_support": supported,
                "no_missing_increase": candidate["n_missing"] <= baseline["n_missing"],
                "rmse_does_not_increase": supported and
                    candidate["rmse_hz"] <= baseline["rmse_hz"] + tolerance,
                "common_support_rmse_does_not_increase": supported and
                    paired_candidate["rmse_hz"] <= paired_baseline["rmse_hz"] + tolerance,
            })
    row = aggregates["transitions"]
    strictly_improved = []
    for slot in ("F1", "F2", "F3"):
        pairs = [tuple(row[domain][method][slot] for method in ("native_default", "temporal"))
                 for domain in ("methods", "common_support")]
        if all(a["n"] and b["n"] and b["rmse_hz"] < a["rmse_hz"] - tolerance
               for a, b in pairs):
            strictly_improved.append(slot)
    passed = bool(strictly_improved) and all(
        check[field] for check in checks for field in (
            "observed_support", "no_missing_increase", "rmse_does_not_increase",
            "common_support_rmse_does_not_increase"))
    no_observations_lost = all(
        aggregates[group]["coverage_changes"][slot]["baseline_present_temporal_missing"] == 0
        for group in protocol["acceptance"]["required_groups"] for slot in ("F1", "F2", "F3"))
    eligible = passed and no_observations_lost
    return {"passed_synthetic_screen": passed, "checks": checks,
            "strictly_improved_transition_slots": strictly_improved,
            "coverage_exchange_audit": {
                "no_baseline_observations_lost": no_observations_lost,
                "added_after_initial_screen": True,
                "reason": "Equal missing counts can conceal exchanging a difficult observed frame "
                          "for an easier previously missing frame. Count those losses separately. "
                          "This audit does not revise the original protocol or its reported outcome.",
            },
            "eligible_for_further_evaluation": eligible,
            "production_selector_changed": False,
            "decision": "Further evaluation required before deployment" if eligible else
                        "Reject this fixed selector for production; retain the experiment and current selector",
            "enforced_in_ci": False}


def extract(exe, wav, output):
    tracks = {}
    for method, extra in (("raw", ["raw"]), ("native_default", [])):
        subprocess.run([str(exe), str(wav), str(output), *extra], check=True, capture_output=True)
        tracks[method] = read_csv(output / f"{wav.stem}.formant.csv")
    raw, default = tracks["raw"], tracks["native_default"]
    if not np.array_equal(raw["time_s"], default["time_s"]):
        raise ValueError(f"Native frame grids differ: {wav.name}")
    times = raw["time_s"]
    frequency = np.column_stack([raw[f"f{k}_hz"] for k in range(1, 6)])
    bandwidth = np.column_stack([raw[f"b{k}_hz"] for k in range(1, 6)])
    values = {"native_default": np.column_stack([default[f"f{k}_hz"] for k in range(1, 4)])}
    diagnostics = {}
    for method, weight in (("temporal", 1.0), ("no_continuity", 0.0)):
        result = select_tracks(times, frequency, bandwidth,
                               config=TemporalConfig(transition_weight=weight))
        values[method] = result.frequencies_hz
        diagnostics[method] = result.diagnostics
    return times, values, diagnostics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE / "release_temporal_formant_check.json")
    args = parser.parse_args()
    sources = sorted((ROOT / "core/src").glob("*.rs")) + [
        ROOT / "core/Cargo.toml", ROOT / "core/Cargo.lock", ROOT / "core/examples/tracks_csv.rs",
        *[HERE / name for name in ("temporal_formant_check.py", "temporal_formant_protocol.json",
                                  "temporal_formants.py", "formant_transitions.py",
                                  "synthesize.py", "compare.py", "formant_evidence.py")],
    ]
    hashes = {str(path.relative_to(ROOT)): sha256(path) for path in sources}
    protocol = json.loads((HERE / "temporal_formant_protocol.json").read_text())
    exe = build_core_binary()
    params = json.loads(subprocess.check_output([str(exe), "--params"], text=True))
    if params["formant_max_bandwidth_hz"] != 400.0:
        raise ValueError("The baseline must use the existing 400 Hz default")
    cases = []
    with tempfile.TemporaryDirectory(prefix="openphon_temporal_") as temporary:
        work = Path(temporary)
        native = work / "native"
        native.mkdir()
        fixture_dir = work / "transitions"
        manifest = transitions.generate_fixtures(fixture_dir)
        synthesize.OUT = work / "wavs"
        synthesize.write_grid()
        grid_path = synthesize.OUT / "formantgrid/truth.json"
        grid = json.loads(grid_path.read_text())
        grid_hash = sha256(grid_path)
        for fixture in manifest["fixtures"]:
            stem = fixture["stem"]
            wav = fixture_dir / f"{stem}.wav"
            times, values, diagnostics = extract(exe, wav, native)
            truth = transitions.truth_at(fixture, times)[:, :3]
            mask = transitions.accuracy_mask(fixture, times)
            if fixture["condition"] == "linear":
                groups = ["transitions"]
                if fixture["f0_hz"] >= 300:
                    groups.append("transitions_high_f0")
            elif fixture["condition"] == "steady":
                groups = ["steady_controls"]
            else:
                groups = ["dropout_stress" if fixture["condition"] == "dropout" else "abrupt_stress"]
            scored = score_methods({name: array[mask] for name, array in values.items()}, truth[mask])
            regions = {}
            gap_presence = {}
            for region, selection in transitions.region_masks(fixture, times).items():
                if region in ("accuracy", "audio_interior"):
                    continue
                if region in ("gap", "gap_core", "gap_guard"):
                    gap_presence[region] = {
                        name: {f"F{k + 1}": {
                            "n_eligible": int(np.sum(selection)),
                            "n_present": int(np.sum(np.isfinite(array[selection, k])
                                                    & (array[selection, k] > 0))),
                        } for k in range(3)} for name, array in values.items()
                    }
                    continue
                regional = score_methods({name: array[selection] for name, array in values.items()},
                                         truth[selection])
                regional.pop("_errors")
                regions[region] = regional
            cases.append({"stem": stem, "groups": groups, "fixture": fixture,
                          "audio_sha256": sha256(wav), "n_native_frames": len(times),
                          "regions": regions, "gap_presence": gap_presence,
                          "selection_diagnostics": diagnostics, **scored})
        for index, cell in enumerate(grid["cells"], 1):
            wav = synthesize.OUT / "formantgrid" / f"{cell['stem']}.wav"
            times, values, diagnostics = extract(exe, wav, native)
            mask = (times >= 0.06) & (times <= times.max() - 0.06)
            truth = np.tile(cell["poles_hz"][:3], (int(np.sum(mask)), 1))
            scored = score_methods({name: array[mask] for name, array in values.items()}, truth)
            groups = ["steady_grid"]
            if cell["f0_hz"] >= 300:
                groups.append("steady_grid_high_f0")
            cases.append({"stem": cell["stem"], "groups": groups, "fixture": cell,
                          "audio_sha256": sha256(wav), "selection_diagnostics": diagnostics, **scored})
            if index % 25 == 0:
                print(f"  {index}/{len(grid['cells'])} steady cells", flush=True)
    if len(manifest["fixtures"]) != 32 or len(grid["cells"]) != 252:
        raise ValueError("The declared experiment requires all 32 transitions and 252 steady cells")
    summaries = aggregate(cases)
    decision = acceptance(summaries, protocol)
    for case in cases:
        case.pop("_errors")
    if hashes != {str(path.relative_to(ROOT)): sha256(path) for path in sources}:
        raise RuntimeError("Sources changed during the experiment; no report written")
    report = {"generated_at_utc": datetime.now(timezone.utc).isoformat(),
              "protocol": protocol, "source_sha256": hashes,
              "binary_sha256": sha256(exe), "operating_point": params,
              "selector_config": TemporalConfig().to_dict(),
              "ablation_config": TemporalConfig(transition_weight=0.0).to_dict(),
              "transition_manifest": manifest, "steady_grid_truth_sha256": grid_hash,
              "environment": {"python": platform.python_version(), "numpy": np.__version__,
                              "platform": platform.platform()},
              "aggregates": summaries, "acceptance": decision, "cases": cases}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"acceptance": decision, "output": str(args.out)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
