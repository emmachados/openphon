"""Offline experimental three-track selection; not a shipped formant estimator.

The local frequency, relative-bandwidth and octave-transition terms follow the
published Praat Formant: Track manual, not implementation source:
https://www.fon.hum.uva.nl/praat/manual/Formant__Track___.html
The references 550/1650/2750 Hz are its adult-female vowel example. Unit cost
coefficients are the manual's illustrative values, not claimed Praat defaults.
This prior is not speaker-neutral and cannot establish resonance identity.
Continuity cannot resolve a stable wrong candidate that the prior also favours.

This experiment adds explicit missing slots. Each costs 2 per input frame.
Each observed/missing boundary costs half the largest permitted octave jump,
so a bounded gap cannot evade that jump more cheaply than a direct transition.
There is no latent frequency through a gap: reentry pays the other boundary.
Leading/trailing gaps pay only the boundary they have; the first frame has no
transition cost. Costs are per input frame, without time-step normalization.
Pass the full frame grid, including frames with no candidates.

All constants were fixed before scoring data. The sole predeclared ablation
sets transition_weight=0, also removing missing-boundary costs. No truth,
speaker labels, synthetic poles, reference tracks or evaluation scores enter
selection. Parameter tuning is restricted by CONTRIBUTING.md to public
calibration data; the public evaluation partition must be scored only once.
"""

import argparse
import csv
import hashlib
import itertools
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np


REFERENCE_HZ = (550.0, 1650.0, 2750.0)
FREQUENCY_WEIGHT_PER_KHZ = 1.0
BANDWIDTH_WEIGHT = 1.0
MISSING_COST = 2.0
MIN_FREQUENCY_HZ = 50.0
UPPER_MARGIN_HZ = 50.0
MAX_CANDIDATES_PER_FRAME = 8


@dataclass(frozen=True)
class TemporalConfig:
    """Fixed experiment, with the native ceiling and declared ablation only."""

    ceiling_hz: float = 5500.0
    transition_weight: float = 1.0

    def __post_init__(self):
        if not math.isfinite(self.ceiling_hz) or self.ceiling_hz <= 100:
            raise ValueError("ceiling_hz must be finite and greater than 100 Hz")
        if self.transition_weight not in (0.0, 1.0):
            raise ValueError("transition_weight must be 1, or 0 for the declared ablation")

    @property
    def gap_boundary_cost(self):
        return (0.5 * self.transition_weight
                * math.log2((self.ceiling_hz - UPPER_MARGIN_HZ) / MIN_FREQUENCY_HZ))

    def to_dict(self):
        return {
            "experiment": "ordered_three_track_viterbi_v1",
            "status": "experimental_not_shipped",
            "reference_hz": list(REFERENCE_HZ),
            "reference_assumption": "Adult-female vowel prior from the published manual; not speaker-neutral.",
            "frequency_weight_per_khz": FREQUENCY_WEIGHT_PER_KHZ,
            "bandwidth_weight": BANDWIDTH_WEIGHT,
            "transition_weight_per_octave": self.transition_weight,
            "missing_cost_per_track_frame": MISSING_COST,
            "observed_missing_boundary_cost": self.gap_boundary_cost,
            "ceiling_hz": self.ceiling_hz,
            "frequency_lower_bound_hz": MIN_FREQUENCY_HZ,
            "frequency_upper_margin_hz": UPPER_MARGIN_HZ,
            "frequency_bounds": "exclusive",
            "bandwidth_policy": "Finite nonnegative bandwidth; no maximum-bandwidth rejection.",
            "max_candidates_per_frame": MAX_CANDIDATES_PER_FRAME,
            "candidate_limit_policy": "Fail explicitly; no candidate pruning or beam search.",
            "cost_time_basis": "Per input frame; no elapsed-time scaling. Supply the complete frame grid.",
            "gap_policy": "Missing emission each frame; boundary charge on entry and reentry; no latent frequency.",
            "restart_policy": "No free restart; only the first frame has no incoming transition.",
            "tie_policy": "Lexicographic raw indices, missing after real indices; final state then predecessors.",
            "source": "https://www.fon.hum.uva.nl/praat/manual/Formant__Track___.html",
            "coefficient_source": "Manual illustrative unit costs, not asserted software defaults.",
            "limitation": "A stable wrong candidate can remain preferred; continuity does not identify resonances.",
        }


@dataclass
class TemporalResult:
    times_s: np.ndarray
    frequencies_hz: np.ndarray
    bandwidths_hz: np.ndarray
    candidate_indices: np.ndarray
    diagnostics: dict
    config: dict


def _frame_states(frequency, bandwidth, config):
    valid = (np.isfinite(frequency) & (frequency > MIN_FREQUENCY_HZ)
             & (frequency < config.ceiling_hz - UPPER_MARGIN_HZ)
             & np.isfinite(bandwidth) & (bandwidth >= 0))
    candidates = sorted(np.flatnonzero(valid), key=lambda i: (frequency[i], int(i)))
    if len(candidates) > MAX_CANDIDATES_PER_FRAME:
        raise ValueError(f"{len(candidates)} valid candidates exceed limit {MAX_CANDIDATES_PER_FRAME}")
    states = []
    for count in range(4):
        for slots in itertools.combinations(range(3), count):
            for indices in itertools.combinations(candidates, count):
                if any(frequency[a] >= frequency[b] for a, b in zip(indices, indices[1:])):
                    continue
                state = [-1, -1, -1]
                for slot, index in zip(slots, indices):
                    state[slot] = int(index)
                states.append(tuple(state))
    # Missing sorts after every source index, including invalid input columns.
    states.sort(key=lambda state: tuple(len(frequency) if i < 0 else i for i in state))
    indices = np.asarray(states, dtype=int)
    present = indices >= 0
    values = np.zeros(indices.shape)
    widths = np.zeros(indices.shape)
    if len(frequency):
        values[present] = frequency[indices[present]]
        widths[present] = bandwidth[indices[present]]
    local = np.full(indices.shape, MISSING_COST)
    deviations = np.abs(values - np.asarray(REFERENCE_HZ)) / 1000
    local[present] = (FREQUENCY_WEIGHT_PER_KHZ * deviations[present]
                      + BANDWIDTH_WEIGHT * widths[present] / values[present])
    log_values = np.zeros(indices.shape)
    log_values[present] = np.log2(values[present])
    return indices, values, widths, present, log_values, local.sum(axis=1)


def _transitions(previous, current, config):
    both = previous[3][:, None, :] & current[3][None, :, :]
    boundary = previous[3][:, None, :] ^ current[3][None, :, :]
    jumps = np.abs(previous[4][:, None, :] - current[4][None, :, :])
    return ((config.transition_weight * jumps * both).sum(axis=2)
            + config.gap_boundary_cost * boundary.sum(axis=2))


def _missing_runs(present):
    runs = []
    for slot in range(3):
        start = None
        for frame in range(len(present) + 1):
            missing = frame < len(present) and not present[frame, slot]
            if missing and start is None:
                start = frame
            elif not missing and start is not None:
                runs.append({"track": slot + 1, "first_frame": start,
                             "last_frame": frame - 1,
                             "bounded_by_observations": start > 0 and frame < len(present)})
                start = None
    return runs


def select_tracks(times_s, raw_frequency_hz, raw_bandwidth_hz, *, config=None):
    """Return exact ordered tracks of shape (frames, 3), with NaN missing.

    Input frequency and bandwidth matrices must have the same (frames,
    candidates) shape. Invalid/out-of-band frequency or invalid bandwidth
    entries are absent candidates; zero native frequency padding is absent.
    Input column indices are preserved in the result (-1 means missing).
    Candidate order may vary between frames. No two observed slots can reuse
    a candidate or have equal/crossed frequencies within a frame.

    At most C(8+3, 3)=165 states are evaluated per frame. Dynamic programming
    is exact, O(frames * states squared), with no beam or truth-based pruning.
    """
    config = config or TemporalConfig()
    times = np.asarray(times_s, dtype=float)
    frequency = np.asarray(raw_frequency_hz, dtype=float)
    bandwidth = np.asarray(raw_bandwidth_hz, dtype=float)
    if times.ndim != 1 or not np.all(np.isfinite(times)):
        raise ValueError("times_s must be a finite one-dimensional array")
    if np.any(np.diff(times) <= 0):
        raise ValueError("times_s must be strictly increasing")
    if frequency.ndim != 2 or frequency.shape != bandwidth.shape:
        raise ValueError("Frequency and bandwidth must be equally shaped two-dimensional arrays")
    if len(frequency) != len(times):
        raise ValueError("Candidate rows must match times_s")

    frames, parents, state_counts = [], [], []
    costs = None
    previous = None
    for frame_index, (f, b) in enumerate(zip(frequency, bandwidth)):
        try:
            frame = _frame_states(f, b, config)
        except ValueError as error:
            raise ValueError(f"Frame {frame_index}: {error}") from error
        # Retain source indices only; the raw matrices already hold the
        # frequencies/widths needed by backtracking. Transition arrays are
        # bounded by one pair of frames, not retained for the recording.
        frames.append(frame[0])
        state_counts.append(len(frame[0]))
        if previous is None:
            costs = frame[5].copy()
            parents.append(np.full(len(costs), -1, dtype=np.int16))
        else:
            transitions = costs[:, None] + _transitions(previous, frame, config)
            parent = np.argmin(transitions, axis=0)
            costs = transitions[parent, np.arange(len(parent))] + frame[5]
            parents.append(parent.astype(np.int16))
        previous = frame

    indices = np.full((len(times), 3), -1, dtype=int)
    values = np.full((len(times), 3), np.nan)
    widths = np.full((len(times), 3), np.nan)
    optimum = float(np.min(costs)) if len(times) else 0.0
    if len(times):
        state = int(np.argmin(costs))
        for frame_index in range(len(times) - 1, -1, -1):
            indices[frame_index] = frames[frame_index][state]
            observed = indices[frame_index] >= 0
            selected = indices[frame_index, observed]
            values[frame_index, observed] = frequency[frame_index, selected]
            widths[frame_index, observed] = bandwidth[frame_index, selected]
            state = int(parents[frame_index][state])

    present = indices >= 0
    frequency_cost = FREQUENCY_WEIGHT_PER_KHZ * np.nansum(
        np.abs(values - np.asarray(REFERENCE_HZ)) / 1000)
    bandwidth_cost = BANDWIDTH_WEIGHT * np.nansum(widths / values)
    observed_transition = 0.0
    boundary_count = 0
    for frame_index in range(1, len(times)):
        both = present[frame_index - 1] & present[frame_index]
        observed_transition += config.transition_weight * float(np.abs(np.log2(
            values[frame_index - 1, both] / values[frame_index, both])).sum())
        boundary_count += int(np.count_nonzero(present[frame_index - 1] ^ present[frame_index]))
    valid_frequency = (np.isfinite(frequency) & (frequency > MIN_FREQUENCY_HZ)
                       & (frequency < config.ceiling_hz - UPPER_MARGIN_HZ))
    valid_bandwidth = np.isfinite(bandwidth) & (bandwidth >= 0)
    diagnostics = {
        "n_frames": len(times), "input_candidate_columns": frequency.shape[1],
        "valid_candidates_per_frame": np.sum(valid_frequency & valid_bandwidth, axis=1).tolist(),
        "invalid_frequency_entries": int(np.count_nonzero(~valid_frequency)),
        "invalid_bandwidth_entries_with_valid_frequency": int(np.count_nonzero(valid_frequency & ~valid_bandwidth)),
        "states_per_frame": state_counts,
        "max_states": max(state_counts, default=0),
        "total_cost": optimum,
        "cost_breakdown": {
            "reference_frequency": float(frequency_cost),
            "relative_bandwidth": float(bandwidth_cost),
            "missing_emission": MISSING_COST * int(np.count_nonzero(~present)),
            "observed_transition": observed_transition,
            "missing_boundary": config.gap_boundary_cost * boundary_count,
        },
        "missing_per_track": np.sum(~present, axis=0).tolist(),
        "missing_runs": _missing_runs(present),
        "selected_above_400_hz_bandwidth_per_track": np.sum(widths > 400, axis=0).tolist(),
        "observed_missing_boundaries": boundary_count,
    }
    return TemporalResult(times.copy(), values, widths, indices, diagnostics, config.to_dict())


def _read_candidates(path):
    with path.open(newline="") as source:
        reader = csv.DictReader(source)
        fields = reader.fieldnames or []
        columns = sorted(int(match.group(1)) for name in fields
                         if (match := re.fullmatch(r"f([1-9][0-9]*)_hz", name)))
        if "time_s" not in fields or not columns:
            raise ValueError("Input CSV requires time_s and f1_hz,b1_hz,... candidate columns")
        if any(f"b{k}_hz" not in fields for k in columns):
            raise ValueError("Every frequency column requires a matching bandwidth column")
        rows = list(reader)
    def number(value):
        return float(value) if value and value.strip() else float("nan")
    times = np.array([number(row["time_s"]) for row in rows])
    frequency = np.array([[number(row[f"f{k}_hz"]) for k in columns] for row in rows])
    bandwidth = np.array([[number(row[f"b{k}_hz"]) for k in columns] for row in rows])
    return times, frequency.reshape(len(rows), len(columns)), bandwidth.reshape(len(rows), len(columns))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Native raw-candidate CSV")
    parser.add_argument("--out", type=Path, required=True, help="Selected three-track CSV")
    parser.add_argument("--metadata", type=Path, help="Diagnostic JSON; defaults to OUT.json")
    parser.add_argument("--ceiling-hz", type=float, default=5500.0)
    parser.add_argument("--no-continuity", action="store_true", help="Predeclared zero-transition ablation")
    args = parser.parse_args()
    metadata_path = args.metadata or Path(str(args.out) + ".json")
    if len({path.resolve() for path in (args.input, args.out, metadata_path)}) != 3:
        parser.error("Input CSV, output CSV and metadata JSON must be different paths")
    config = TemporalConfig(ceiling_hz=args.ceiling_hz,
                            transition_weight=0.0 if args.no_continuity else 1.0)
    result = select_tracks(*_read_candidates(args.input), config=config)
    with args.out.open("w", newline="") as destination:
        writer = csv.writer(destination)
        writer.writerow(["time_s"] + [name for k in range(1, 4)
                                      for name in (f"f{k}_hz", f"b{k}_hz", f"candidate{k}_index")])
        for time, frequency, bandwidth, indices in zip(result.times_s, result.frequencies_hz,
                                                      result.bandwidths_hz, result.candidate_indices):
            row = [float(time)]
            for f, b, index in zip(frequency, bandwidth, indices):
                row.extend([float(f) if np.isfinite(f) else "",
                            float(b) if np.isfinite(b) else "", int(index)])
            writer.writerow(row)
    metadata = {"config": result.config, "diagnostics": result.diagnostics,
                "input_file": str(args.input),
                "candidate_index_semantics": "Zero-based position among input fN_hz columns sorted by N; -1 is missing.",
                "input_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
                "selector_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    metadata_path.write_text(
        json.dumps(metadata, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
