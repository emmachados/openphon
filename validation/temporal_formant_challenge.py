"""Additional known-resonance challenge after the fixed selector's first screen.

This extension was designed after the 32-transition/252-grid screen passed
and its no-continuity ablation had identical aggregate scores. The original
grid has F3=2600 Hz and the new glides have F3=2500..2900 Hz, near the fixed
2750 Hz reference. The existing 19-file tier includes higher resonances and
therefore checks a limitation that the first screen did not resolve.

The original protocol and result remain unchanged. This is an additional
diagnostic on existing synthetic signals, not a preregistered independent
holdout and not evidence about natural speech. No selector parameter, native
algorithm, bandwidth threshold, or public-evaluation result is changed here.
The fixed selector and its ablation are imported from the original harness.
"""

import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from compare import FORMANT_TRUTH, TRUTH_F0, build_core_binary, read_csv
import synthesize
from temporal_formant_check import METHODS, aggregate, extract, score_methods
from temporal_formants import TemporalConfig


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
EXPECTED_FILES = 19
TRUTH_MARGIN_S = 0.05
FIXED_TRACE_STEMS = ("child_i_400", "male_a_110_natural")
COMPARISONS = {"temporal_vs_no_continuity": ("temporal", "no_continuity"),
               "temporal_vs_native_default": ("temporal", "native_default")}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical_hash(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def count_differences(left, right):
    """Count exact output differences, distinguishing missing from frequency.

    Nonpositive/nonfinite outputs are missing. Two missing outputs are
    equivalent regardless of their storage representation. Finite observed
    values are compared exactly because all methods select from the same
    serialized native candidate values; no tolerance is tuned from results.
    """
    left, right = np.asarray(left, dtype=float), np.asarray(right, dtype=float)
    if left.shape != right.shape or left.ndim != 2 or left.shape[1] != 3:
        raise ValueError("Difference counts require equally shaped F1-F3 matrices")
    lp = np.isfinite(left) & (left > 0)
    rp = np.isfinite(right) & (right > 0)
    both = lp & rp
    presence_changed = lp ^ rp
    frequency_changed = both & (left != right)
    changed = presence_changed | frequency_changed
    per_slot = {}
    for k in range(3):
        paired = both[:, k]
        distances = np.abs(left[paired, k] - right[paired, k])
        per_slot[f"F{k + 1}"] = {
            "n_frames": len(left),
            "n_both_present": int(np.sum(paired)),
            "n_both_missing": int(np.sum(~lp[:, k] & ~rp[:, k])),
            "n_presence_differences": int(np.sum(presence_changed[:, k])),
            "n_frequency_differences_on_common_support": int(np.sum(frequency_changed[:, k])),
            "n_different": int(np.sum(changed[:, k])),
            "maximum_abs_frequency_difference_hz": float(distances.max()) if len(distances) else None,
        }
    return {"n_frames": len(left), "n_frames_any_slot_different": int(np.sum(changed.any(axis=1))),
            "n_frames_any_presence_different": int(np.sum(presence_changed.any(axis=1))),
            "n_slot_values_different": int(changed.sum()), "per_slot": per_slot}


def summarize_differences(cases):
    """Add frame counts without giving short recordings equal frame weight."""
    output = {}
    for group in sorted({group for row in cases for group in row["groups"]}):
        chosen = [row for row in cases if group in row["groups"]]
        output[group] = {}
        for domain in ("full_tracks", "eligible_interior"):
            output[group][domain] = {}
            for comparison in COMPARISONS:
                matrices = [row["_values"][domain] for row in chosen]
                left, right = COMPARISONS[comparison]
                output[group][domain][comparison] = count_differences(
                    np.concatenate([values[left] for values in matrices]),
                    np.concatenate([values[right] for values in matrices]))
    return output


def regression_rows(rows, tolerance_hz):
    """List observed regressions; do not silently replace the initial screen.

    Apply its unchanged numerical comparison tolerance to additional groups
    or individual files. Conditional and common-support RMSE are reported
    separately, alongside added missing values. These are diagnostics, not
    newly tuned acceptance thresholds.
    """
    output = []
    for name, row in rows.items():
        for slot in ("F1", "F2", "F3"):
            baseline = row["methods"]["native_default"][slot]
            candidate = row["methods"]["temporal"][slot]
            paired_baseline = row["common_support"]["native_default"][slot]
            paired_candidate = row["common_support"]["temporal"][slot]
            observed = baseline["n"] > 0 and candidate["n"] > 0
            paired = paired_baseline["n"] > 0 and paired_candidate["n"] > 0
            delta = candidate["rmse_hz"] - baseline["rmse_hz"] if observed else None
            paired_delta = (paired_candidate["rmse_hz"] - paired_baseline["rmse_hz"]
                            if paired else None)
            missing_delta = candidate["n_missing"] - baseline["n_missing"]
            if ((delta is not None and delta > tolerance_hz)
                    or (paired_delta is not None and paired_delta > tolerance_hz)
                    or missing_delta > 0 or not observed or not paired):
                output.append({
                    "case": name, "slot": slot,
                    "baseline_rmse_hz": baseline["rmse_hz"],
                    "temporal_rmse_hz": candidate["rmse_hz"],
                    "rmse_increase_hz": delta,
                    "common_support_baseline_rmse_hz": paired_baseline["rmse_hz"],
                    "common_support_temporal_rmse_hz": paired_candidate["rmse_hz"],
                    "common_support_rmse_increase_hz": paired_delta,
                    "baseline_missing": baseline["n_missing"],
                    "temporal_missing": candidate["n_missing"],
                    "missing_increase": missing_delta,
                    "n_common_present": paired_candidate["n"],
                    "has_observed_and_common_support": observed and paired,
                })
    return output


def verify_frozen_screen(screen, current_hashes):
    """Require the same estimator, selector and harness as the first screen."""
    if type(screen["acceptance"]["passed_synthetic_screen"]) is not bool:
        raise ValueError("The completed first screen must record a boolean pass/fail result")
    for name, digest in screen["source_sha256"].items():
        if current_hashes.get(name) != digest:
            raise ValueError(f"Source differs from frozen first screen: {name}")
    if screen["selector_config"] != TemporalConfig().to_dict():
        raise ValueError("Selector configuration differs from first screen")
    if screen["ablation_config"] != TemporalConfig(transition_weight=0.0).to_dict():
        raise ValueError("Ablation configuration differs from first screen")


def _nullable_values(values):
    return [[float(value) if np.isfinite(value) and value > 0 else None for value in row]
            for row in values]


def _trace(row, raw, reasons):
    times = row["_times"]
    if not np.array_equal(times, raw["time_s"]):
        raise ValueError(f"Trace raw frame grid differs: {row['stem']}")
    return {
        "stem": row["stem"], "selection_reasons": reasons,
        "scope": "Diagnostic trace selection does not change any estimator parameter.",
        "times_s": times.tolist(), "eligible_mask": row["_mask"].tolist(),
        "known_poles_hz": row["_truth"].tolist(),
        "raw_frequencies_hz": np.column_stack([raw[f"f{k}_hz"] for k in range(1, 6)]).tolist(),
        "raw_bandwidths_hz": np.column_stack([raw[f"b{k}_hz"] for k in range(1, 6)]).tolist(),
        "raw_padding": "Native zero frequency is an absent candidate.",
        "selected_frequencies_hz": {name: _nullable_values(values)
                                    for name, values in row["_values"]["full_tracks"].items()},
        "missing_output": "null",
    }


def run_challenge(screen_path, output_path):
    screen_path, output_path = Path(screen_path), Path(output_path)
    screen_sha256 = sha256(screen_path)
    screen = json.loads(screen_path.read_text())
    # Include every source frozen in the original screen, even sources not
    # directly executed by this extension, plus this extension's own source.
    sources = [ROOT / name for name in screen["source_sha256"]]
    sources.append(Path(__file__).resolve())
    hashes = {str(path.relative_to(ROOT)): sha256(path) for path in sources}
    verify_frozen_screen(screen, hashes)
    exe = build_core_binary()
    params = json.loads(subprocess.check_output([str(exe), "--params"], text=True))
    if params != screen["operating_point"] or params["formant_max_bandwidth_hz"] != 400.0:
        raise ValueError("Native operating point differs from the first screen")
    cases = []
    previous_output = synthesize.OUT
    with tempfile.TemporaryDirectory(prefix="openphon_temporal_challenge_") as temporary:
        work = Path(temporary)
        synthesize.OUT = work / "wavs"
        try:
            synthesize.main()
            wavs = sorted(synthesize.OUT.glob("*.wav"))
            if len(wavs) != EXPECTED_FILES:
                raise ValueError(f"Expected all {EXPECTED_FILES} top-level fixtures, got {len(wavs)}")
            if not set(FIXED_TRACE_STEMS) <= {wav.stem for wav in wavs}:
                raise ValueError("Missing a fixed diagnostic fixture")
            native = work / "native"
            native.mkdir()
            for index, wav in enumerate(wavs, 1):
                if wav.stem not in FORMANT_TRUTH:
                    raise ValueError(f"No known pole truth for {wav.stem}")
                times, values, diagnostics = extract(exe, wav, native)
                if not len(times):
                    raise ValueError(f"No native frames for {wav.stem}")
                mask = (times >= TRUTH_MARGIN_S) & (times <= times.max() - TRUTH_MARGIN_S)
                if not np.any(mask):
                    raise ValueError(f"No eligible truth frames for {wav.stem}")
                truth = np.asarray([FORMANT_TRUTH[wav.stem](t) for t in times])
                scoring = score_methods({name: array[mask] for name, array in values.items()},
                                        truth[mask, :3])
                f0_fn = TRUTH_F0.get(wav.stem)
                f0 = np.array([f0_fn(t) for t in times[mask]]) if f0_fn is not None else None
                f0_range = [float(f0.min()), float(f0.max())] if f0 is not None else None
                groups = ["known_synthetic_all"]
                if f0 is not None and np.all(f0 >= 300.0):
                    groups.append("known_synthetic_high_f0")
                with wave.open(str(wav), "rb") as audio:
                    sr, samples = audio.getframerate(), audio.getnframes()
                matrices = {"full_tracks": values,
                            "eligible_interior": {name: array[mask] for name, array in values.items()}}
                differences = {domain: {name: count_differences(arrays[left], arrays[right])
                                       for name, (left, right) in COMPARISONS.items()}
                               for domain, arrays in matrices.items()}
                cases.append({
                    "stem": wav.stem, "groups": groups, "audio_sha256": sha256(wav),
                    "sample_rate_hz": sr, "duration_s": samples / sr,
                    "nominal_f0_range_hz": f0_range,
                    "known_pole_ranges_hz": [[float(column.min()), float(column.max())]
                                             for column in truth[mask].T],
                    "truth_sha256": canonical_hash({"times_s": times.tolist(), "poles_hz": truth.tolist()}),
                    "n_native_frames": len(times), "n_eligible_frames": int(mask.sum()),
                    "first_eligible_time_s": float(times[mask][0]),
                    "last_eligible_time_s": float(times[mask][-1]),
                    "differences": differences, "selection_diagnostics": diagnostics, **scoring,
                    "_times": times, "_mask": mask, "_truth": truth, "_values": matrices,
                })
                print(f"  {index}/{len(wavs)} {wav.stem}", flush=True)

            summaries = aggregate(cases)
            differences = summarize_differences(cases)
            tolerance = screen["protocol"]["acceptance"]["numerical_tolerance_hz"]
            regressions = {"groups": regression_rows(summaries, tolerance),
                           "per_file": regression_rows({row["stem"]: row for row in cases}, tolerance)}
            scored_slots = [(row["methods"]["temporal"][slot]["rmse_hz"], row["stem"], slot)
                            for row in cases for slot in ("F1", "F2", "F3")
                            if row["methods"]["temporal"][slot]["rmse_hz"] is not None]
            worst = max(scored_slots)
            reasons = {stem: ["fixed example declared before this challenge run"]
                       for stem in FIXED_TRACE_STEMS}
            reasons.setdefault(worst[1], []).append(f"largest temporal labelled RMSE: {worst[2]}")
            worsening = [row for row in regressions["per_file"]
                         if row["common_support_rmse_increase_hz"] is not None
                         and row["common_support_rmse_increase_hz"] > tolerance]
            worst_regression = max(worsening, key=lambda row: row["common_support_rmse_increase_hz"],
                                   default=None)
            if worst_regression is not None:
                reasons.setdefault(worst_regression["case"], []).append(
                    f"largest common-support RMSE increase: {worst_regression['slot']}")
            traces = []
            for row in cases:
                if row["stem"] in reasons:
                    wav = synthesize.OUT / (row["stem"] + ".wav")
                    subprocess.run([str(exe), str(wav), str(native), "raw"],
                                   check=True, capture_output=True)
                    raw = read_csv(native / f"{row['stem']}.formant.csv")
                    traces.append(_trace(row, raw, reasons[row["stem"]]))
        finally:
            synthesize.OUT = previous_output

    if hashes != {str(path.relative_to(ROOT)): sha256(path) for path in sources}:
        raise RuntimeError("Sources changed during challenge; no report written")
    if sha256(screen_path) != screen_sha256:
        raise RuntimeError("First screen report changed during challenge; no report written")
    for row in cases:
        for field in [key for key in row if key.startswith("_")]:
            row.pop(field)
    any_regression = bool(regressions["groups"] or regressions["per_file"])
    full_ablation = differences["known_synthetic_all"]["full_tracks"]["temporal_vs_no_continuity"]
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Additional 19-file known-resonance synthetic challenge; no public or private speech.",
        "chronology": {
            "designed_after_first_screen": True,
            "first_screen_generated_at_utc": screen["generated_at_utc"],
            "first_screen_report": str(screen_path.relative_to(ROOT)) if screen_path.is_relative_to(ROOT) else str(screen_path),
            "first_screen_sha256": screen_sha256,
            "first_screen_passed": screen["acceptance"]["passed_synthetic_screen"],
            "reason": "The first grid has F3=2600 Hz and glides F3=2500..2900 Hz, near the fixed 2750 Hz prior. "
                      "Its ablation had identical aggregate scores. Broader known resonances are an additional check.",
            "status": "Post-screen diagnostic extension using existing fixtures, not an independent preregistered holdout.",
            "original_protocol_and_results_changed": False,
            "selector_parameters_changed": False,
        },
        "source_sha256": hashes, "binary_sha256": sha256(exe), "operating_point": params,
        "selector_config": TemporalConfig().to_dict(),
        "ablation_config": TemporalConfig(transition_weight=0.0).to_dict(),
        "environment": {"python": platform.python_version(), "numpy": np.__version__, "platform": platform.platform()},
        "scoring": {
            "labels": ["F1", "F2", "F3"], "n_files": len(cases),
            "truth_source": "compare.FORMANT_TRUTH evaluated at each native frame centre",
            "eligible_rule": "0.05 <= native frame time <= maximum native frame time - 0.05 seconds",
            "high_f0_rule": "Nominal synthesis F0 at every eligible frame is at least 300 Hz",
            "missing_policy": "Nonpositive/nonfinite estimates are missing; no zero-error substitution",
            "pooling": "Individual frame errors pooled, not recording-level averages",
            "common_support": "Per labelled slot, finite positive outputs shared by native default and temporal selector",
            "numerical_tolerance_hz": tolerance,
            "trace_selection": "Fixed child_i_400 and male_a_110_natural; largest temporal labelled RMSE; largest paired RMSE increase",
            "error_scope": "Synthesis pole identity; windowing and sparse excitation can make instantaneous poles unrecoverable",
        },
        "aggregates": summaries, "differences": differences, "regressions": regressions,
        "diagnostic_conclusion": {
            "has_additional_regressions": any_regression,
            "temporal_equals_ablation_on_all_full_tracks": full_ablation["n_slot_values_different"] == 0,
            "worst_temporal_labelled_slot": {"stem": worst[1], "slot": worst[2], "rmse_hz": worst[0]},
            "worst_common_support_regression": worst_regression,
            "production_selector_changed": False,
            "recommendation": ("Do not deploy this fixed selector: additional known-resonance regressions remain."
                               if any_regression else
                               "No regression detected in this extension; natural-speech validity is still unestablished."),
            "enforced_in_ci": False,
        },
        "cases": cases, "representative_traces": traces,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"output": str(output_path), "diagnostic_conclusion": report["diagnostic_conclusion"]}, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screen", type=Path, default=HERE / "release_temporal_formant_check.json")
    parser.add_argument("--out", type=Path, default=HERE / "release_temporal_formant_challenge.json")
    args = parser.parse_args()
    run_challenge(args.screen.resolve(), args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
