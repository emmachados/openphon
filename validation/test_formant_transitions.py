"""Analytic trajectory, eligibility and missing-value checks before scoring."""

import hashlib
import json
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

import formant_transitions as transitions


def fixture(condition="linear", direction="ab", f0=100):
    return next(row for row in transitions.fixture_specs()
                if (row["condition"], row["direction"], row["f0_hz"])
                == (condition, direction, f0))


class TransitionTruthTests(unittest.TestCase):
    def test_declared_design_is_balanced_and_primary_is_continuous(self):
        rows = transitions.fixture_specs()
        self.assertEqual(len(rows), 32)
        self.assertEqual(len({row["stem"] for row in rows}), 32)
        self.assertEqual(sum(row["acceptance_group"] == "primary_continuous"
                             for row in rows), 8)
        for f0 in (100, 200, 300, 400):
            chosen = [row for row in rows if row["f0_hz"] == f0]
            self.assertEqual(len(chosen), 8)
            for condition in ("linear", "step", "dropout", "steady"):
                pair = [row for row in chosen if row["condition"] == condition]
                self.assertEqual(len(pair), 2)
                self.assertTrue(all(row["sample_rate_hz"] == 44100 for row in pair))
                self.assertTrue(all(row["duration_s"] == 1.6 for row in pair))
        self.assertTrue(all(row["condition"] == "linear" for row in rows
                            if row["acceptance_group"] == "primary_continuous"))

    def test_linear_truth_is_analytic_in_seconds_in_both_directions(self):
        times = [0.0, 0.3, 0.55, 0.8, 1.05, 1.3, 1.6]
        expected = np.array([
            [350, 2100, 2900, 3600, 4500],
            [350, 2100, 2900, 3600, 4500],
            [450, 1900, 2800, 3600, 4500],
            [550, 1700, 2700, 3600, 4500],
            [650, 1500, 2600, 3600, 4500],
            [750, 1300, 2500, 3600, 4500],
            [750, 1300, 2500, 3600, 4500],
        ])
        np.testing.assert_allclose(transitions.truth_at(fixture(), times), expected,
                                   rtol=0, atol=1e-12)
        np.testing.assert_allclose(transitions.truth_at(fixture(direction="ba"), times),
                                   expected[::-1], rtol=0, atol=1e-12)
        np.testing.assert_allclose(transitions.truth_at(fixture(), 0.8), expected[3])
        self.assertEqual(transitions.truth_at(fixture(), []).shape, (0, 5))

    def test_step_is_right_continuous_and_steady_controls_are_constant(self):
        times = [0.0, np.nextafter(0.8, 0), 0.8, 1.6]
        a, b = transitions.ENDPOINT_A_HZ, transitions.ENDPOINT_B_HZ
        np.testing.assert_array_equal(transitions.truth_at(fixture("step"), times),
                                      [a, a, b, b])
        np.testing.assert_array_equal(transitions.truth_at(fixture("step", "ba"), times),
                                      [b, b, a, a])
        for direction, expected in (("a", a), ("b", b)):
            np.testing.assert_array_equal(
                transitions.truth_at(fixture("steady", direction), times), [expected] * 4)

    def test_invalid_truth_times_fail_without_extrapolation(self):
        for times in ([-0.001], [1.60001], [np.nan], [np.inf], [[0.4]]):
            with self.assertRaises(ValueError):
                transitions.truth_at(fixture(), times)


class TransitionScoringTests(unittest.TestCase):
    def test_edges_and_gap_overlap_have_fixed_common_masks(self):
        row = fixture("dropout")
        times = np.array([0.0, 0.059, 0.06, 0.3, 0.5, 0.64, 0.7, 0.76,
                          0.8, 0.84, 0.9, 0.96, 1.0, 1.54, 1.541])
        masks = transitions.region_masks(row, times)
        np.testing.assert_array_equal(masks["accuracy"],
                                      [False, False, True, True, True, False, False,
                                       False, False, False, False, False, True, True, False])
        np.testing.assert_array_equal(times[masks["gap_core"]], [0.76, 0.8, 0.84])
        self.assertFalse(np.any(masks["accuracy"] & masks["gap_guard"]))
        self.assertFalse(np.any(masks["hold"] & masks["transition"]))

    def test_abrupt_boundary_is_diagnostic_not_main_accuracy(self):
        times = np.array([0.1, 0.7, 0.75, 0.8, 0.85, 0.9, 1.5])
        masks = transitions.region_masks(fixture("step"), times)
        np.testing.assert_array_equal(times[masks["boundary"]], [0.75, 0.8, 0.85])
        self.assertFalse(np.any(masks["accuracy"] & masks["boundary"]))
        self.assertFalse(np.any(masks["transition"]))
        linear = transitions.region_masks(fixture(), [0.3, 0.8, 1.3])
        np.testing.assert_array_equal(linear["accuracy"], [True, True, True])
        np.testing.assert_array_equal(linear["boundary"], [True, False, True])
        np.testing.assert_array_equal(linear["transition"], [False, True, False])

    def test_missing_values_reduce_coverage_and_never_become_zero_errors(self):
        row = fixture()
        times = [0.1, 0.2, 0.4, 0.8, 1.2, 1.5]
        values = transitions.truth_at(row, times)
        values[:, 0] += [10, -20, 0, 30, -40, 50]
        values[2, 0] = 0
        values[3, 1], values[4, 1], values[5, 1] = np.nan, np.inf, -10
        slots = transitions.labelled_errors(row, times, values)
        np.testing.assert_array_equal(slots["F1"]["signed_errors_hz"], [10, -20, 30, -40, 50])
        result = transitions.score_fixture(row, times, values)["scores"]
        f1 = result["F1"]
        self.assertEqual((f1["n_eligible"], f1["n_present"], f1["n_missing"]), (6, 5, 1))
        self.assertAlmostEqual(f1["rmse_hz"], np.sqrt(1100))
        self.assertEqual(f1["median_abs_err_hz"], 30)
        self.assertAlmostEqual(f1["p95_abs_err_hz"], 48)
        self.assertAlmostEqual(f1["p99_abs_err_hz"], 49.6)
        self.assertEqual(result["F2"]["n_missing"], 3)
        self.assertEqual(result["F3"]["rmse_hz"], 0)

    def test_shifted_labels_are_scored_in_their_labelled_slots(self):
        row = fixture("steady", "a")
        times = [0.1, 0.2]
        values = np.array([[2100, 2900, 0], [350, 2100, 2900]])
        result = transitions.labelled_errors(row, times, values)
        np.testing.assert_array_equal(result["F1"]["signed_errors_hz"], [1750, 0])
        np.testing.assert_array_equal(result["F2"]["signed_errors_hz"], [800, 0])
        np.testing.assert_array_equal(result["F3"]["signed_errors_hz"], [0])
        self.assertEqual(int(result["F3"]["present_mask"].sum()), 1)

    def test_common_support_and_pooling_retain_individual_errors(self):
        row = fixture("steady", "a")
        times = [0.1, 0.2, 0.3, 0.4]
        a = transitions.truth_at(row, times)
        b = a.copy()
        a[:, 0] += [1, 2, 30, 40]
        b[:, 0] += [5, 6, 7, 8]
        a[0, 0], b[3, 0] = 0, 0
        sa, sb = (transitions.labelled_errors(row, times, values)["F1"] for values in (a, b))
        common = sa["present_mask"] & sb["present_mask"]
        np.testing.assert_array_equal(common, [False, True, True, False])
        paired = transitions.labelled_errors(row, times, a, common)["F1"]
        np.testing.assert_array_equal(paired["signed_errors_hz"], [2, 30])
        pooled = transitions.summarize_errors(np.concatenate(([1], paired["signed_errors_hz"])), 4)
        self.assertEqual(pooled["median_abs_err_hz"], 2)
        self.assertEqual(pooled["n_missing"], 1)

    def test_gap_has_presence_only_and_empty_regions_have_no_error_statistic(self):
        row = fixture("dropout")
        times = [0.5, 0.76, 0.8, 0.84, 1.1]
        values = transitions.truth_at(row, times)
        values[1:4, :3] = 0
        result = transitions.score_fixture(row, times, values)
        self.assertEqual(result["scores"]["F1"]["n_eligible"], 2)
        gap = result["gap_presence"]["gap_core"]["F1"]
        self.assertEqual(gap, {"n_eligible": 3, "n_present": 0,
                               "n_missing": 3, "missing_pct": 100.0})
        empty = transitions.summarize_errors([], 0)
        self.assertIsNone(empty["missing_pct"])
        self.assertIsNone(empty["rmse_hz"])
        self.assertIsNone(empty["p99_abs_err_hz"])
        missing = transitions.summarize_errors([], 4)
        self.assertEqual(missing["missing_pct"], 100)
        self.assertIsNone(missing["rmse_hz"])

    def test_scoring_rejects_ambiguous_shapes_times_and_masks(self):
        row = fixture()
        for times, values in (([0.1, 0.1], np.ones((2, 3))),
                              ([0.2, 0.1], np.ones((2, 3))),
                              ([0.1], np.ones((2, 3))),
                              ([0.1], np.ones((1, 2)))):
            with self.assertRaises(ValueError):
                transitions.labelled_errors(row, times, values)
        with self.assertRaises(ValueError):
            transitions.labelled_errors(row, [0.1], np.ones((1, 3)), [1])
        with self.assertRaises(ValueError):
            transitions.summarize_errors([np.nan], 1)
        with self.assertRaises(ValueError):
            transitions.summarize_errors([1, 2], 1)


class TransitionAudioTests(unittest.TestCase):
    def test_actual_synthesis_is_repeatable_with_a_literal_audio_gap(self):
        row = fixture("dropout", "ba", 400)
        samples = transitions.synthesize_fixture(row)
        repeated = transitions.synthesize_fixture(row)
        np.testing.assert_array_equal(samples, repeated)
        self.assertEqual(len(samples), 70560)
        self.assertTrue(np.all(np.isfinite(samples)))
        self.assertLessEqual(float(np.max(np.abs(samples))), 0.3)
        self.assertGreater(float(np.max(np.abs(samples))), 0.0)
        np.testing.assert_array_equal(samples[30870:39690], np.zeros(8820))
        self.assertGreater(float(np.max(np.abs(samples[10000:20000]))), 0.0)

    def test_manifest_and_pcm_files_are_deterministic_and_reopen(self):
        # The synthesis test above exercises the real filter. This one checks
        # all fixture metadata and PCM serialization without repeating 32 filters.
        samples = np.array([0.0, 0.3, -0.3, 0.0])
        with tempfile.TemporaryDirectory(prefix="openphon_transition_test_") as temporary:
            output = Path(temporary)
            with patch.object(transitions, "synthesize_fixture", return_value=samples):
                manifest = transitions.generate_fixtures(output)
                first_bytes = (output / "manifest.json").read_bytes()
                repeated = transitions.generate_fixtures(output)
            self.assertEqual(first_bytes, (output / "manifest.json").read_bytes())
            self.assertEqual(manifest, repeated)
            self.assertEqual(json.loads(first_bytes)["n_primary_fixtures"], 8)
            self.assertEqual(len(list(output.glob("*.wav"))), 32)
            for row in manifest["fixtures"]:
                path = output / (row["stem"] + ".wav")
                self.assertEqual(row["wav_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
                with wave.open(str(path), "rb") as wav:
                    self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()),
                                     (1, 2, 44100))
                    np.testing.assert_array_equal(np.frombuffer(wav.readframes(4), dtype="<i2"),
                                                  [0, 9830, -9830, 0])


if __name__ == "__main__":
    unittest.main()
