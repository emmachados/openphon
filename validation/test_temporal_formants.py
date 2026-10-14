"""Algorithmic contract checks, not calibration or acoustic accuracy scores."""

import itertools
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np

from temporal_formants import TemporalConfig, select_tracks


def exhaustive_cost(frequency, bandwidth, config):
    """Independent tiny-case enumeration of every admissible joint path."""
    choices = []
    for frame in frequency:
        states = []
        for state in itertools.product(range(-1, len(frame)), repeat=3):
            selected = [i for i in state if i >= 0]
            if len(set(selected)) != len(selected):
                continue
            if any(frame[a] >= frame[b] for a, b in zip(selected, selected[1:])):
                continue
            states.append(state)
        choices.append(states)
    best = math.inf
    for path in itertools.product(*choices):
        cost = 0.0
        for frame, state in enumerate(path):
            for slot, index in enumerate(state):
                if index < 0:
                    cost += 2.0
                else:
                    f = frequency[frame, index]
                    cost += abs(f - (550, 1650, 2750)[slot]) / 1000
                    cost += bandwidth[frame, index] / f
                if frame:
                    old = path[frame - 1][slot]
                    if old >= 0 and index >= 0:
                        cost += config.transition_weight * abs(math.log2(
                            frequency[frame - 1, old] / frequency[frame, index]))
                    elif (old >= 0) != (index >= 0):
                        cost += 0.5 * config.transition_weight * math.log2(
                            (config.ceiling_hz - 50) / 50)
        best = min(best, cost)
    return best


class TemporalFormantTests(unittest.TestCase):
    def test_exact_dynamic_program_matches_exhaustive_paths(self):
        frequency = np.array([[540, 2700], [610, 1690], [560, 2800]])
        bandwidth = np.array([[70, 150], [90, 600], [80, 120]])
        for weight in (1.0, 0.0):
            config = TemporalConfig(transition_weight=weight)
            result = select_tracks([0.0, 0.01, 0.02], frequency, bandwidth, config=config)
            self.assertAlmostEqual(result.diagnostics["total_cost"],
                                   exhaustive_cost(frequency, bandwidth, config), places=12)
            self.assertAlmostEqual(result.diagnostics["total_cost"],
                                   sum(result.diagnostics["cost_breakdown"].values()), places=12)

    def test_internal_missing_slot_does_not_renumber_survivors(self):
        result = select_tracks([0.0], [[550, 2750]], [[50, 80]])
        np.testing.assert_array_equal(result.candidate_indices, [[0, -1, 1]])
        self.assertEqual(result.frequencies_hz[0, 0], 550)
        self.assertTrue(np.isnan(result.frequencies_hz[0, 1]))
        self.assertEqual(result.frequencies_hz[0, 2], 2750)

    def test_temporal_support_can_select_a_broad_candidate(self):
        frequency = np.array([[550, 1650, 2750, 0],
                              [550, 1650, 1850, 2750],
                              [550, 1650, 2750, 0]])
        bandwidth = np.array([[60, 60, 100, 0],
                              [60, 500, 20, 100],
                              [60, 60, 100, 0]])
        tracked = select_tracks([0.0, 0.01, 0.02], frequency, bandwidth)
        ablated = select_tracks([0.0, 0.01, 0.02], frequency, bandwidth,
                               config=TemporalConfig(transition_weight=0.0))
        self.assertEqual(tracked.frequencies_hz[1, 1], 1650)
        self.assertEqual(tracked.bandwidths_hz[1, 1], 500)
        self.assertEqual(ablated.frequencies_hz[1, 1], 1850)
        self.assertEqual(tracked.diagnostics["selected_above_400_hz_bandwidth_per_track"], [0, 1, 0])
        self.assertEqual(ablated.config["observed_missing_boundary_cost"], 0)
        self.assertEqual(ablated.diagnostics["cost_breakdown"]["observed_transition"], 0)

    def test_empty_frame_has_missing_values_and_conservative_restart_cost(self):
        frequency = np.tile([550.0, 1650.0, 2750.0], (11, 1))
        bandwidth = np.full((11, 3), 80.0)
        frequency[5] = 0
        bandwidth[5] = 0
        result = select_tracks(np.arange(11) * 0.01, frequency, bandwidth)
        self.assertTrue(np.all(np.isnan(result.frequencies_hz[5])))
        self.assertTrue(np.all(np.isfinite(result.frequencies_hz[np.arange(11) != 5])))
        self.assertEqual(result.diagnostics["missing_per_track"], [1, 1, 1])
        self.assertEqual(result.diagnostics["observed_missing_boundaries"], 6)
        self.assertEqual(len(result.diagnostics["missing_runs"]), 3)
        self.assertTrue(all(run["bounded_by_observations"]
                            for run in result.diagnostics["missing_runs"]))
        boundary = result.config["observed_missing_boundary_cost"]
        self.assertGreaterEqual(2 * boundary, abs(math.log2(5449 / 51)))

    def test_sustained_abrupt_change_uses_available_candidates(self):
        frequency = np.tile([550.0, 1650.0, 2750.0], (8, 1))
        frequency[4:, 1] = 2300
        result = select_tracks(np.arange(8) * 0.01, frequency, np.full((8, 3), 70))
        np.testing.assert_array_equal(result.frequencies_hz, frequency)

    def test_stable_wrong_candidate_is_not_identifiable_from_continuity(self):
        # The selector cannot recover an absent resonance. This fixture has no
        # truth input: it checks that the model does not fabricate frequencies.
        frequency = np.tile([550, 1750, 2750], (5, 1))
        result = select_tracks(np.arange(5) * 0.01, frequency, np.full((5, 3), 50))
        np.testing.assert_array_equal(result.frequencies_hz, frequency)
        self.assertIn("stable wrong candidate", result.config["limitation"])

    def test_unsorted_candidates_cannot_reuse_or_cross_and_ties_are_deterministic(self):
        frequency = [[2750, 550, 550, 1650]]
        bandwidth = [[50, 50, 50, 50]]
        first = select_tracks([0.0], frequency, bandwidth)
        second = select_tracks([0.0], frequency, bandwidth)
        np.testing.assert_array_equal(first.candidate_indices, [[1, 3, 0]])
        np.testing.assert_array_equal(first.candidate_indices, second.candidate_indices)
        self.assertTrue(np.all(np.diff(first.frequencies_hz, axis=1) > 0))
        self.assertEqual(len(set(first.candidate_indices[0])), 3)

    def test_invalid_candidates_and_all_empty_inputs_remain_missing(self):
        result = select_tracks([0.0], [[np.nan, 0, 50, 5450, 800, 1600]],
                               [[50, 0, 30, 30, np.nan, -1]])
        self.assertTrue(np.all(np.isnan(result.frequencies_hz)))
        self.assertEqual(result.diagnostics["invalid_frequency_entries"], 4)
        self.assertEqual(result.diagnostics["invalid_bandwidth_entries_with_valid_frequency"], 2)
        empty = select_tracks([], np.empty((0, 0)), np.empty((0, 0)))
        self.assertEqual(empty.frequencies_hz.shape, (0, 3))
        self.assertEqual(empty.diagnostics["total_cost"], 0)
        zero_columns = select_tracks([0.0, 0.01], np.empty((2, 0)), np.empty((2, 0)))
        self.assertEqual(zero_columns.diagnostics["total_cost"], 12)

    def test_state_count_is_bounded_without_silent_candidate_pruning(self):
        frequency = [np.linspace(100, 5000, 8)]
        result = select_tracks([0.0], frequency, np.full((1, 8), 100))
        self.assertEqual(result.diagnostics["max_states"], math.comb(11, 3))
        with self.assertRaisesRegex(ValueError, "Frame 0: 9 valid candidates exceed limit 8"):
            select_tracks([0.0], [np.linspace(100, 5000, 9)], np.full((1, 9), 100))

    def test_invalid_grid_shapes_or_undeclared_parameters_fail(self):
        for times in ([0.0, 0.0], [0.01, 0.0], [0.0, np.nan]):
            with self.assertRaises(ValueError):
                select_tracks(times, [[550], [550]], [[50], [50]])
        with self.assertRaises(ValueError):
            select_tracks([0.0], [[550]], [[50, 60]])
        with self.assertRaises(ValueError):
            select_tracks([0.0, 0.01], [[550]], [[50]])
        with self.assertRaises(ValueError):
            TemporalConfig(transition_weight=0.5)
        with self.assertRaises(ValueError):
            TemporalConfig(ceiling_hz=100)

    def test_cli_writes_missing_cells_and_reproducible_diagnostics(self):
        with tempfile.TemporaryDirectory(prefix="openphon-temporal-test-") as temporary:
            source = Path(temporary) / "candidates.csv"
            destination = Path(temporary) / "selected.csv"
            source.write_text("time_s,f1_hz,b1_hz,f2_hz,b2_hz\n0.0,550,50,2750,80\n")
            subprocess.run([sys.executable, str(Path(__file__).with_name("temporal_formants.py")),
                            str(source), "--out", str(destination), "--no-continuity"],
                           check=True, capture_output=True, text=True)
            rows = destination.read_text().splitlines()
            self.assertEqual(rows[1], "0.0,550.0,50.0,0,,,-1,2750.0,80.0,1")
            metadata = json.loads(Path(str(destination) + ".json").read_text())
            self.assertEqual(metadata["config"]["transition_weight_per_octave"], 0)
            self.assertEqual(metadata["config"]["reference_hz"], [550, 1650, 2750])
            self.assertEqual(metadata["diagnostics"]["missing_per_track"], [0, 1, 0])
            self.assertEqual(len(metadata["input_sha256"]), 64)
            self.assertEqual(len(metadata["selector_sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
