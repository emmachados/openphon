"""Native constant-preservation and silent-gap invariants, without speech scoring.

The Rust driver links the current release openphon_core library. It contains
no copied resampling, preprocessing, LPC or root algorithm. Inputs are fresh
synthetic float64 arrays; the eight existing dropout fixtures are quantized
through PCM16 before analysis to match their WAV representation. Float64
transport preserves the additional 1e-12-amplitude control, which PCM16
would erase before it reached the estimator.

Exact constants must remain exact in complete resampling kernels. Gap checks
use the declared 60 ms guard around each audio discontinuity, exceeding the
25 ms formant half-window, resampler support and pre-emphasis delay. They
exercise both raw candidates and the shipped 400 Hz selection. Quiet-signal
checks test numerical scale invariance, not acoustic accuracy or a silence
threshold. No public audio, Praat implementation, or historical module is used.
"""

import argparse
import csv
import hashlib
import io
import json
import platform
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

import formant_transitions as transitions


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
INPUT_RATES_HZ = (8000, 11000, 16000, 44100, 44101, 48000, 96000, 192000)
OUTPUT_RATE_HZ = 11000
CONSTANT_LEVELS = (0.0, 0.1, 0.25, -0.2, 1e-12)
QUIET_SCALE = 1e-12
RESAMPLE_RELATIVE_TOLERANCE = 1e-12
TRACK_TOLERANCE_HZ = 1e-6
DIRECT_DURATION_S = 0.4
DIRECT_GUARD_S = 0.02
QUIET_FIXTURE = "transition_dropout_ab_f0100"
QUIET_ACTIVE_INTERVAL_S = (0.1, 0.6)

DRIVER = r'''use openphon_core::formant::{resample, track_formants, FormantParams};
use std::io::Write;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 { return Err("expected mode input rate setting output".into()); }
    let bytes = std::fs::read(&args[2])?;
    if bytes.len() % 8 != 0 { return Err("input must contain complete float64 samples".into()); }
    let samples: Vec<f64> = bytes.chunks_exact(8)
        .map(|b| f64::from_le_bytes(b.try_into().unwrap())).collect();
    if samples.is_empty() || samples.iter().any(|v| !v.is_finite()) {
        return Err("input must be nonempty and finite".into());
    }
    let mut out = std::io::BufWriter::new(std::fs::File::create(&args[5])?);
    match args[1].as_str() {
        "resample" => {
            let values = resample(&samples, args[3].parse()?, args[4].parse()?);
            for value in values { out.write_all(&value.to_le_bytes())?; }
        },
        "track" => {
            let mut params = FormantParams::default();
            match args[4].as_str() {
                "raw" => params.max_bandwidth_hz = f64::INFINITY,
                "default" => {},
                _ => return Err("track setting must be raw or default".into()),
            }
            let track = track_formants(&samples, args[3].parse()?, &params);
            writeln!(out, "time_s,f1_hz,f2_hz,f3_hz,f4_hz,f5_hz,b1_hz,b2_hz,b3_hz,b4_hz,b5_hz")?;
            for frame in track.frames {
                write!(out, "{:.17e}", frame.time_s)?;
                for values in [&frame.formants_hz, &frame.bandwidths_hz] {
                    for slot in 0..5 { write!(out, ",{:.17e}", values.get(slot).unwrap_or(&0.0))?; }
                }
                writeln!(out)?;
            }
        },
        _ => return Err("mode must be resample or track".into()),
    }
    Ok(())
}
'''


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _finite_vector(values):
    values = np.asarray(values, dtype=float)
    if values.ndim != 1 or not len(values) or not np.all(np.isfinite(values)):
        raise ValueError("Expected a nonempty finite sample vector")
    return values


def constant_metrics(values, level):
    values = _finite_vector(values)
    difference = np.abs(values - level)
    return {"n_samples": len(values), "n_samples_different": int(np.count_nonzero(difference)),
            "maximum_abs_difference": float(difference.max()),
            "peak_to_peak": float(np.ptp(values)),
            "passed": bool(np.all(values == level))}


def scaled_signal_metrics(normal, quiet, scale=QUIET_SCALE):
    normal, quiet = _finite_vector(normal), _finite_vector(quiet)
    if normal.shape != quiet.shape or not np.isfinite(scale) or scale <= 0:
        raise ValueError("Scale comparison requires equal sample grids and a positive finite scale")
    peak = float(np.max(np.abs(normal)))
    if peak == 0:
        raise ValueError("The ordinary-amplitude control cannot be silent")
    difference = float(np.max(np.abs(quiet / scale - normal)))
    relative = difference / peak
    retained = bool(np.ptp(quiet) > 0)
    return {"n_samples": len(normal), "amplitude_scale": scale,
            "quiet_rms": float(np.sqrt(np.mean(quiet ** 2))),
            "quiet_peak_to_peak": float(np.ptp(quiet)),
            "maximum_normalized_abs_difference": difference,
            "relative_normalized_abs_difference": relative,
            "relative_tolerance": RESAMPLE_RELATIVE_TOLERANCE,
            "passed": retained and relative <= RESAMPLE_RELATIVE_TOLERANCE}


def _validate_track(track):
    times, frequency, bandwidth = track
    if (times.ndim != 1 or not len(times) or frequency.shape != (len(times), 5)
            or bandwidth.shape != frequency.shape or not np.all(np.isfinite(times))
            or np.any(np.diff(times) <= 0) or not np.all(np.isfinite(frequency))
            or not np.all(np.isfinite(bandwidth)) or np.any(frequency < 0)
            or np.any(bandwidth < 0)):
        raise ValueError("Native track must have finite ordered times and five valid nonnegative slots")


def gap_metrics(track, interval):
    _validate_track(track)
    times, frequency, _ = track
    selected = (times >= interval[0]) & (times <= interval[1])
    if not np.any(selected):
        raise ValueError("Gap control has no guarded native frames")
    present = frequency[selected] > 0
    return {"interval_s": list(interval), "n_frames": int(selected.sum()),
            "n_frames_with_candidates": int(present.any(axis=1).sum()),
            "n_present_per_slot": present.sum(axis=0).tolist(),
            "passed": not bool(present.any())}


def quiet_track_metrics(normal, quiet, interval=QUIET_ACTIVE_INTERVAL_S):
    _validate_track(normal)
    _validate_track(quiet)
    times, frequency, bandwidth = normal
    qt, qf, qb = quiet
    if not np.array_equal(times, qt):
        raise ValueError("Quiet and ordinary tracks must use identical frame times")
    selected = (times >= interval[0]) & (times <= interval[1])
    if not np.any(selected):
        raise ValueError("Quiet control has no active native frames")
    frequency, qf = frequency[selected], qf[selected]
    bandwidth, qb = bandwidth[selected], qb[selected]
    present, qpresent = frequency > 0, qf > 0
    paired = present & qpresent
    changes = present ^ qpresent
    supported = bool(np.all(paired[:, :3].any(axis=0)))
    fd = float(np.max(np.abs(frequency[paired] - qf[paired]))) if paired.any() else None
    bd = float(np.max(np.abs(bandwidth[paired] - qb[paired]))) if paired.any() else None
    return {"interval_s": list(interval), "amplitude_scale": QUIET_SCALE,
            "n_frames": int(selected.sum()), "n_present_per_slot": present.sum(axis=0).tolist(),
            "n_quiet_present_per_slot": qpresent.sum(axis=0).tolist(),
            "n_frames_with_presence_change": int(changes.any(axis=1).sum()),
            "n_slot_presence_changes": int(changes.sum()),
            "maximum_frequency_difference_hz": fd, "maximum_bandwidth_difference_hz": bd,
            "numerical_tolerance_hz": TRACK_TOLERANCE_HZ,
            "passed": supported and not changes.any() and fd <= TRACK_TOLERANCE_HZ
                      and bd <= TRACK_TOLERANCE_HZ}


def build_driver(work):
    """Select Cargo's current library artifact, avoiding stale cached rlibs."""
    command = ["cargo", "build", "--locked", "--release", "--lib", "--manifest-path",
               str(ROOT / "core/Cargo.toml"), "--message-format=json"]
    build = subprocess.run(command, check=True, capture_output=True, text=True)
    libraries = []
    for line in build.stdout.splitlines():
        message = json.loads(line)
        if (message.get("reason") == "compiler-artifact"
                and message.get("target", {}).get("name") == "openphon_core"):
            libraries.extend(Path(name) for name in message["filenames"] if name.endswith(".rlib"))
    if len(libraries) != 1:
        raise RuntimeError(f"Expected one current core library artifact, found {len(libraries)}")
    library = libraries[0]
    source, binary = work / "driver.rs", work / "resampling-proof"
    source.write_text(DRIVER, encoding="utf-8")
    subprocess.run(["rustc", "--edition=2024", "-O", str(source), "--extern",
                    f"openphon_core={library}", "-L", f"dependency={library.parent / 'deps'}",
                    "-o", str(binary)], check=True, capture_output=True)
    return binary, library


def write_samples(work, name, samples):
    path = work / (name + ".f64")
    _finite_vector(samples).astype("<f8").tofile(path)
    return path


def native_resample(binary, work, path, rate):
    output = work / "resampled.f64"
    subprocess.run([str(binary), "resample", str(path), str(rate), str(OUTPUT_RATE_HZ), str(output)],
                   check=True, capture_output=True)
    return _finite_vector(np.fromfile(output, dtype="<f8"))


def native_track(binary, work, path, rate, mode):
    output = work / "track.csv"
    subprocess.run([str(binary), "track", str(path), str(rate), mode, str(output)],
                   check=True, capture_output=True)
    rows = list(csv.DictReader(io.StringIO(output.read_text())))
    times = np.array([float(row["time_s"]) for row in rows])
    frequency = np.array([[float(row[f"f{k}_hz"]) for k in range(1, 6)] for row in rows])
    bandwidth = np.array([[float(row[f"b{k}_hz"]) for k in range(1, 6)] for row in rows])
    track = times, frequency, bandwidth
    _validate_track(track)
    return track


def run_check(output):
    sources = sorted((ROOT / "core/src").glob("*.rs")) + [
        ROOT / "core/Cargo.toml", ROOT / "core/Cargo.lock", Path(__file__).resolve(),
        HERE / "formant_transitions.py", HERE / "synthesize.py",
    ]
    hashes = {str(path.relative_to(ROOT)): sha256(path) for path in sources}
    direct, gaps, quiet_rows = [], [], []
    with tempfile.TemporaryDirectory(prefix="openphon_resampling_") as temporary:
        work = Path(temporary)
        binary, library = build_driver(work)
        binary_hash, library_hash = sha256(binary), sha256(library)
        for rate in INPUT_RATES_HZ:
            n = int(DIRECT_DURATION_S * rate)
            times = np.arange(n) / rate
            constants = []
            for index, level in enumerate(CONSTANT_LEVELS):
                path = write_samples(work, f"constant_{rate}_{index}", np.full(n, level))
                values = native_resample(binary, work, path, rate)
                t = np.arange(len(values)) / OUTPUT_RATE_HZ
                inside = (t >= DIRECT_GUARD_S) & (t <= n / rate - DIRECT_GUARD_S)
                constants.append({"input_level": level, "input_sha256": sha256(path),
                                  **constant_metrics(values[inside], level)})
            signal = np.sin(2 * np.pi * 1000 * times) + 0.2 * np.cos(2 * np.pi * 3000 * times)
            normal_path = write_samples(work, f"tone_{rate}", signal)
            quiet_path = write_samples(work, f"tone_{rate}_quiet", signal * QUIET_SCALE)
            normal = native_resample(binary, work, normal_path, rate)
            quiet = native_resample(binary, work, quiet_path, rate)
            t = np.arange(len(normal)) / OUTPUT_RATE_HZ
            inside = (t >= DIRECT_GUARD_S) & (t <= n / rate - DIRECT_GUARD_S)
            direct.append({"input_rate_hz": rate, "output_rate_hz": OUTPUT_RATE_HZ,
                           "n_input_samples": n, "n_output_samples": len(normal),
                           "constants": constants,
                           "scaled_signal": {"input_sha256": sha256(normal_path),
                                             "quiet_input_sha256": sha256(quiet_path),
                                             **scaled_signal_metrics(normal[inside], quiet[inside])}})
            pulse = np.zeros(round(1.6 * rate))
            pulse[round(0.1 * rate):round(0.2 * rate)] = 0.25
            pulse_path = write_samples(work, f"pulse_{rate}", pulse)
            gaps.append({"stem": f"pulse_{rate}", "input_rate_hz": rate,
                         "construction": "0.25 over [0.1,0.2) seconds, otherwise exactly zero; duration 1.6 s",
                         "input_sha256": sha256(pulse_path),
                         "modes": {mode: gap_metrics(native_track(binary, work, pulse_path, rate, mode), (0.76, 0.84))
                                   for mode in ("raw", "default")}})
            print(f"  rate {rate}: constants, scale invariance and pulse gap", flush=True)

        fixtures = [f for f in transitions.fixture_specs() if f["condition"] == "dropout"]
        if len(fixtures) != 8 or QUIET_FIXTURE not in {f["stem"] for f in fixtures}:
            raise ValueError("Expected all eight declared dropout fixtures and the fixed quiet control")
        for fixture in fixtures:
            pcm = (np.clip(transitions.synthesize_fixture(fixture), -1, 1) * 32767).astype("<i2")
            samples = pcm.astype(float) / 32768.0
            path = write_samples(work, fixture["stem"], samples)
            start, stop = fixture["dropouts_s"][0]
            interval = start + fixture["guard_s"], stop - fixture["guard_s"]
            tracks = {mode: native_track(binary, work, path, fixture["sample_rate_hz"], mode)
                      for mode in ("raw", "default")}
            gaps.append({"stem": fixture["stem"], "input_rate_hz": fixture["sample_rate_hz"],
                         "construction": "Existing deterministic dropout fixture after PCM16 quantization",
                         "fixture": fixture, "input_sha256": sha256(path),
                         "modes": {mode: gap_metrics(track, interval) for mode, track in tracks.items()}})
            if fixture["stem"] == QUIET_FIXTURE:
                quiet_path = write_samples(work, fixture["stem"] + "_quiet", samples * QUIET_SCALE)
                for mode, normal_track in tracks.items():
                    quiet_track = native_track(binary, work, quiet_path, fixture["sample_rate_hz"], mode)
                    quiet_rows.append({"stem": fixture["stem"], "mode": mode,
                                       "input_sha256": sha256(path), "quiet_input_sha256": sha256(quiet_path),
                                       **quiet_track_metrics(normal_track, quiet_track)})
            print(f"  {fixture['stem']}: guarded dropout", flush=True)
    if hashes != {str(path.relative_to(ROOT)): sha256(path) for path in sources}:
        raise RuntimeError("Sources changed during the native check; no report written")
    checks = ([c["passed"] for row in direct for c in row["constants"]]
              + [row["scaled_signal"]["passed"] for row in direct]
              + [mode["passed"] for row in gaps for mode in row["modes"].values()]
              + [row["passed"] for row in quiet_rows])
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "purpose": "Exact constant preservation, silent-gap rejection and quiet-signal numerical invariance",
        "scope": "Fresh synthetic inputs only; no public or private speech and no formant-accuracy claim",
        "source_sha256": hashes, "driver_sha256": hashlib.sha256(DRIVER.encode()).hexdigest(),
        "native_binary_sha256": binary_hash, "core_library_sha256": library_hash,
        "environment": {"python": platform.python_version(), "numpy": np.__version__, "platform": platform.platform(),
                        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip()},
        "design": {"input_rates_hz": list(INPUT_RATES_HZ), "output_rate_hz": OUTPUT_RATE_HZ,
                   "rate_paths": "11000: identity; 44101: generic coefficient-table fallback; other rates: polyphase",
                   "constant_levels": list(CONSTANT_LEVELS), "direct_guard_s": DIRECT_GUARD_S,
                   "direct_duration_s": DIRECT_DURATION_S, "dropout_guard_s": 0.06,
                   "active_tones_hz": [1000, 3000], "second_tone_amplitude": 0.2,
                   "quiet_scale": QUIET_SCALE, "relative_scale_tolerance": RESAMPLE_RELATIVE_TOLERANCE,
                   "track_numerical_tolerance_hz": TRACK_TOLERANCE_HZ,
                   "constant_policy": "Exact equality in complete-kernel interiors; no amplitude threshold",
                   "boundary_scope": "Zero-padding boundary equivalence is checked by core unit tests; excluded here",
                   "quiet_control": "Same float64 samples attenuated by 1e-12 after PCM16 fixture construction",
                   "raw_max_bandwidth_hz": None, "default_max_bandwidth_hz": 400.0},
        "resampling": direct, "silent_regions": gaps, "quiet_tracks": quiet_rows,
        "n_checks": len(checks), "n_passed": int(sum(checks)), "passed": bool(all(checks)),
        "enforced_in_ci": True,
    }
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Resampling invariants: {report['n_passed']}/{len(checks)} passed; {output}")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE / "resampling_check.json")
    args = parser.parse_args()
    return 0 if run_check(args.out)["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
