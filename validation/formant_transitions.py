"""Deterministic vowel-like transitions for offline formant-selector tests.

The design is declared here, independently of tracker outcomes: four constant
F0 values crossed with two steady endpoints, both directions of a continuous
glide, both directions of an abrupt change, and both glides with an audio gap.
Only the eight continuous, gap-free glides are primary transition cases. The
other 24 files are diagnostic controls. These signals are cascades of known
time-varying resonators driven by the existing Rosenberg-source primitive;
they are not a model of natural-speech formant identity or consonants.

Truth is the instantaneous synthesis-pole frequency, evaluated analytically
at the requested frame centre. It is not the spectral peak of a finite window.
In particular, a window straddling an abrupt change contains both regimes.
Abrupt boundaries and gaps therefore do not enter the main accuracy mask.
Steady controls also retain high-F0 cases where sparse harmonic excitation
does not identify every resonance: known synthesis parameters do not imply
that every parameter is recoverable from each window.

All scores preserve the labelled F1/F2/F3 slots. Missing (nonpositive or
nonfinite) estimates reduce coverage and never become zero-valued errors.
Use ``labelled_errors`` to pool frame errors, not per-file medians. The fixed
60 ms guard covers the 25 ms half-window and resampling support of the current
analysis configuration; other window configurations require another protocol.

Generate WAVs and their manifest with::

    python validation/formant_transitions.py --output /private/tmp/transitions

No tracker is executed and no public audio is used by this module.
"""

import argparse
import hashlib
import json
import wave
from pathlib import Path

import numpy as np

try:
    from . import synthesize
except ImportError:
    import synthesize


SAMPLE_RATE_HZ = 44100
DURATION_S = 1.6
F0_VALUES_HZ = (100, 200, 300, 400)
ENDPOINT_A_HZ = (350.0, 2100.0, 2900.0, 3600.0, 4500.0)
ENDPOINT_B_HZ = (750.0, 1300.0, 2500.0, 3600.0, 4500.0)
BANDWIDTHS_HZ = (60.0, 90.0, 120.0, 150.0, 200.0)
GLIDE_START_S = 0.3
GLIDE_END_S = 1.3
STEP_TIME_S = 0.8
DROPOUT_S = (0.7, 0.9)
GUARD_S = 0.06
FADE_S = 0.02
PEAK_AMPLITUDE = 0.3


def fixture_specs():
    """Return the 32 declared fixture dictionaries, in a stable order.

    WAV paths are ``output_dir / (fixture['stem'] + '.wav')``. Specifications
    are JSON-compatible and include everything required by ``truth_at`` and
    the scoring masks; callers do not need a generated WAV to use them.
    """
    fixtures = []
    cases = (("steady", "a"), ("steady", "b"),
             ("linear", "ab"), ("linear", "ba"),
             ("step", "ab"), ("step", "ba"),
             ("dropout", "ab"), ("dropout", "ba"))
    for f0 in F0_VALUES_HZ:
        for condition, direction in cases:
            start = ENDPOINT_A_HZ if direction.startswith("a") else ENDPOINT_B_HZ
            end = ENDPOINT_B_HZ if direction == "ab" else ENDPOINT_A_HZ
            if condition == "steady":
                times = [0.0, DURATION_S]
                values = [start, start]
                interpolation = "constant"
                boundaries = []
            elif condition == "step":
                times = [0.0, STEP_TIME_S, DURATION_S]
                values = [start, end, end]
                interpolation = "step_right_continuous"
                boundaries = [STEP_TIME_S]
            else:
                times = [0.0, GLIDE_START_S, GLIDE_END_S, DURATION_S]
                values = [start, start, end, end]
                interpolation = "linear"
                boundaries = [GLIDE_START_S, GLIDE_END_S]
            stem = f"transition_{condition}_{direction}_f0{f0:03d}"
            fixtures.append({
                "stem": stem,
                "condition": condition,
                "direction": direction,
                "f0_hz": f0,
                "sample_rate_hz": SAMPLE_RATE_HZ,
                "duration_s": DURATION_S,
                "acceptance_group": ("primary_continuous" if condition == "linear"
                                     else "diagnostic"),
                "bandwidths_hz": list(BANDWIDTHS_HZ),
                "trajectory": {
                    "interpolation": interpolation,
                    "times_s": times,
                    "frequencies_hz": [list(row) for row in values],
                },
                "trajectory_boundaries_s": boundaries,
                "dropouts_s": [list(DROPOUT_S)] if condition == "dropout" else [],
                "guard_s": GUARD_S,
            })
    return fixtures


def _times(times, *, scalar_allowed=False, ordered=False):
    result = np.asarray(times, dtype=float)
    if result.ndim != 1 and not (scalar_allowed and result.ndim == 0):
        raise ValueError("times must be a one-dimensional array")
    if not np.all(np.isfinite(result)):
        raise ValueError("times must be finite")
    if ordered and len(result) > 1 and np.any(np.diff(result) <= 0):
        raise ValueError("frame times must be strictly increasing")
    return result


def truth_at(fixture, times):
    """Return exact instantaneous synthesis poles at arbitrary times.

    A scalar time returns five frequencies; a one-dimensional time array
    returns shape (frames, 5). Linear segments include their endpoints; a
    step takes its new value at the boundary itself. Out-of-file times fail
    explicitly instead of silently extrapolating.
    """
    t = _times(times, scalar_allowed=True)
    if np.any(t < 0) or np.any(t > fixture["duration_s"]):
        raise ValueError("truth times must lie within the fixture duration")
    trajectory = fixture["trajectory"]
    knots = np.asarray(trajectory["times_s"], dtype=float)
    values = np.asarray(trajectory["frequencies_hz"], dtype=float)
    kind = trajectory["interpolation"]
    if kind == "linear":
        return np.stack([np.interp(t, knots, values[:, i]) for i in range(5)], axis=-1)
    if kind == "constant":
        return np.broadcast_to(values[0], t.shape + (5,)).copy()
    if kind == "step_right_continuous":
        indices = np.searchsorted(knots, t, side="right") - 1
        return values[np.minimum(indices, len(values) - 1)]
    raise ValueError(f"unknown trajectory interpolation: {kind}")


def region_masks(fixture, times):
    """Return boolean masks for accuracy, holds, transitions and diagnostics.

    ``accuracy`` uses a common audio interior, removes gaps expanded by the
    60 ms guard, and removes step boundaries by the same guard. Continuous
    glide boundaries remain in accuracy, but ``hold`` and ``transition``
    omit their boundary neighbourhoods. ``boundary`` can be scored separately
    against instantaneous truth only as a window-boundary diagnostic.

    ``gap`` marks centres in the erased audio interval; ``gap_core`` contracts
    that interval by the guard to identify wholly silent analysis windows.
    Gap masks are presence diagnostics, not resonance-accuracy regions.
    """
    t = _times(times, ordered=True)
    guard = fixture["guard_s"]
    interior = (t >= guard) & (t <= fixture["duration_s"] - guard)
    gap = np.zeros(t.shape, dtype=bool)
    gap_core = gap.copy()
    gap_guard = gap.copy()
    for start, stop in fixture["dropouts_s"]:
        gap |= (t >= start) & (t < stop)
        gap_core |= (t >= start + guard) & (t <= stop - guard)
        gap_guard |= (t >= start - guard) & (t <= stop + guard)
    boundary = np.zeros(t.shape, dtype=bool)
    for value in fixture["trajectory_boundaries_s"]:
        boundary |= (t >= value - guard) & (t <= value + guard)
    observable = interior & ~gap_guard
    accuracy = observable.copy()
    if fixture["condition"] == "step":
        accuracy &= ~boundary
    if fixture["condition"] in ("linear", "dropout"):
        start, stop = fixture["trajectory"]["times_s"][1:3]
        moving = (t >= start) & (t < stop)
    else:
        moving = np.zeros(t.shape, dtype=bool)
    return {
        "accuracy": accuracy,
        "hold": accuracy & ~moving & ~boundary,
        "transition": accuracy & moving & ~boundary,
        "boundary": observable & boundary,
        "audio_interior": interior,
        "gap": interior & gap,
        "gap_core": interior & gap_core,
        "gap_guard": interior & gap_guard,
    }


def accuracy_mask(fixture, times):
    """Return the declared common accuracy mask, independent of estimates."""
    return region_masks(fixture, times)["accuracy"]


def labelled_errors(fixture, times, formants, mask=None):
    """Return per-labelled-slot finite signed errors and coverage masks.

    ``formants`` must have shape (frames, at least 3), with columns F1, F2,
    F3 in that order. No nearest-pole reassignment is performed. An explicit
    boolean ``mask`` replaces the default accuracy mask, so boundary or
    paired-support diagnostics can use exactly their declared frame set.

    Each F1/F2/F3 entry contains full-length ``eligible_mask`` and
    ``present_mask`` arrays, and compact ``signed_errors_hz`` in time order.
    For comparisons on common support, intersect methods' present masks
    and call this function again with that common mask.
    """
    t = _times(times, ordered=True)
    values = np.asarray(formants, dtype=float)
    if values.ndim != 2 or values.shape[0] != len(t) or values.shape[1] < 3:
        raise ValueError("formants must have shape (number of times, at least 3)")
    truth = truth_at(fixture, t)
    if mask is None:
        eligible = accuracy_mask(fixture, t)
    else:
        eligible = np.asarray(mask)
        if eligible.shape != t.shape or eligible.dtype != np.bool_:
            raise ValueError("mask must be a boolean array with one entry per frame")
    result = {}
    for i in range(3):
        present = eligible & np.isfinite(values[:, i]) & (values[:, i] > 0)
        result[f"F{i + 1}"] = {
            "eligible_mask": eligible.copy(),
            "present_mask": present,
            "signed_errors_hz": values[present, i] - truth[present, i],
        }
    return result


def summarize_errors(signed_errors_hz, n_eligible):
    """Summarize pooled finite errors with an explicit coverage denominator."""
    errors = np.asarray(signed_errors_hz, dtype=float)
    if errors.ndim != 1 or not np.all(np.isfinite(errors)):
        raise ValueError("signed errors must be a finite one-dimensional array")
    if (not isinstance(n_eligible, (int, np.integer)) or n_eligible < 0
            or n_eligible < len(errors)):
        raise ValueError("n_eligible must be an integer at least the error count")
    n_present = len(errors)
    absolute = np.abs(errors)
    return {
        "n_eligible": int(n_eligible),
        "n_present": n_present,
        "n_missing": int(n_eligible - n_present),
        "missing_pct": (100.0 * (n_eligible - n_present) / n_eligible
                        if n_eligible else None),
        "rmse_hz": float(np.sqrt(np.mean(errors ** 2))) if n_present else None,
        "median_abs_err_hz": float(np.median(absolute)) if n_present else None,
        "p95_abs_err_hz": float(np.percentile(absolute, 95)) if n_present else None,
        "p99_abs_err_hz": float(np.percentile(absolute, 99)) if n_present else None,
    }


def _score_region(fixture, times, formants, mask):
    return {
        name: summarize_errors(slot["signed_errors_hz"], int(slot["eligible_mask"].sum()))
        for name, slot in labelled_errors(fixture, times, formants, mask).items()
    }


def score_fixture(fixture, times, formants):
    """Return JSON-compatible accuracy/region scores and gap presence counts."""
    regions = region_masks(fixture, times)
    scores = _score_region(fixture, times, formants, regions["accuracy"])
    region_scores = {
        name: _score_region(fixture, times, formants, regions[name])
        for name in ("hold", "transition", "boundary")
    }
    gap_presence = {}
    for region in ("gap", "gap_core"):
        gap_presence[region] = {
            name: {key: score[key] for key in ("n_eligible", "n_present", "n_missing", "missing_pct")}
            for name, score in _score_region(fixture, times, formants, regions[region]).items()
        }
    return {"stem": fixture["stem"], "acceptance_group": fixture["acceptance_group"],
            "scores": scores, "regions": region_scores,
            "gap_presence": gap_presence}


def synthesize_fixture(fixture):
    """Synthesize mono float samples with the existing clean-room primitives."""
    sr = fixture["sample_rate_hz"]
    source = synthesize.rosenberg_train(
        fixture["f0_hz"], fixture["duration_s"], sr=sr,
        jitter=0.0, shimmer=0.0, seed=987, open_q=0.6, close_q=0.3)
    times = np.arange(len(source), dtype=float) / sr
    poles = truth_at(fixture, times)
    samples = source
    for i, bandwidth in enumerate(fixture["bandwidths_hz"]):
        frequencies = poles[:, i]
        if np.all(frequencies == frequencies[0]):
            samples = synthesize.resonator(samples, frequencies[0], bandwidth, sr=sr)
        else:
            # resonator_glide calls the function at i/sr. Evaluate the same
            # analytic trajectory once on that grid, then recover its index.
            samples = synthesize.resonator_glide(
                samples, lambda t, values=frequencies: values[round(t * sr)],
                bandwidth, sr=sr)
    fade = min(len(samples), round(FADE_S * sr))
    samples[:fade] *= np.linspace(0.0, 1.0, fade)
    samples[-fade:] *= np.linspace(1.0, 0.0, fade)
    peak = np.max(np.abs(samples))
    if not np.isfinite(peak) or peak <= 0:
        raise ValueError("synthesis did not produce a finite nonzero signal")
    samples = samples / peak * PEAK_AMPLITUDE
    # Erase output after filtering: this represents missing recorded audio,
    # not a silent glottal source with a resonator's decaying tail.
    for start, stop in fixture["dropouts_s"]:
        samples[(times >= start) & (times < stop)] = 0.0
    return samples


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def generate_fixtures(output_dir):
    """Write all 32 PCM16 WAVs plus manifest.json and return the manifest."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    fixtures = fixture_specs()
    for fixture in fixtures:
        samples = synthesize_fixture(fixture)
        pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
        path = output_dir / (fixture["stem"] + ".wav")
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(fixture["sample_rate_hz"])
            wav.writeframes(pcm.tobytes())
        fixture["wav_sha256"] = _sha256(path)
        truth_json = json.dumps(fixture["trajectory"], sort_keys=True, separators=(",", ":"))
        fixture["truth_sha256"] = hashlib.sha256(truth_json.encode("utf-8")).hexdigest()
    manifest = {
        "schema": "openphon.formant-transitions.v1",
        "scope": "Known instantaneous poles of vowel-like synthetic resonators; not natural-speech labels.",
        "primary_condition": "linear",
        "n_fixtures": len(fixtures),
        "n_primary_fixtures": sum(f["acceptance_group"] == "primary_continuous" for f in fixtures),
        "source": {"kind": "Rosenberg-B derivative", "seed": 987, "jitter": 0.0,
                   "shimmer": 0.0, "open_q": 0.6, "close_q": 0.3},
        "audio": {"format": "mono PCM16", "sample_rate_hz": SAMPLE_RATE_HZ,
                  "duration_s": DURATION_S, "edge_fade_s": FADE_S,
                  "peak_amplitude_before_gap": PEAK_AMPLITUDE},
        "scoring": {"labels": ["F1", "F2", "F3"], "guard_s": GUARD_S,
                    "gap_policy": "Exclude erased intervals expanded by guard; report gap presence separately.",
                    "step_policy": "Exclude boundary plus/minus guard from accuracy; report boundary separately.",
                    "missing_policy": "Nonpositive/nonfinite estimates are missing; no zero-error substitution.",
                    "quantiles": "numpy.percentile, linear interpolation"},
        "source_sha256": {"formant_transitions.py": _sha256(__file__),
                          "synthesize.py": _sha256(synthesize.__file__)},
        "fixtures": fixtures,
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="Directory for generated WAVs and manifest.json")
    args = parser.parse_args()
    manifest = generate_fixtures(args.output)
    print(f"Generated {manifest['n_fixtures']} fixtures, "
          f"{manifest['n_primary_fixtures']} primary: {args.output / 'manifest.json'}")


if __name__ == "__main__":
    main()
