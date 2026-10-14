"""Native invariant scoring must reject roundoff excitation and vacuous passes."""

import unittest

import numpy as np

from resampling_check import (constant_metrics, gap_metrics,
                              quiet_track_metrics, scaled_signal_metrics)


def track(times, frequencies, bandwidths=None):
    frequencies = np.asarray(frequencies, dtype=float)
    if bandwidths is None:
        bandwidths = np.where(frequencies > 0, 100.0, 0.0)
    return np.asarray(times, dtype=float), frequencies, np.asarray(bandwidths, dtype=float)


class ResamplingEvidenceTests(unittest.TestCase):
    def test_constant_check_requires_exact_equality_even_for_one_ulp(self):
        self.assertTrue(constant_metrics([0.1, 0.1], 0.1)["passed"])
        result = constant_metrics([0.1, np.nextafter(0.1, np.inf)], 0.1)
        self.assertFalse(result["passed"])
        self.assertEqual(result["n_samples_different"], 1)
        self.assertGreater(result["maximum_abs_difference"], 0)
        with self.assertRaises(ValueError):
            constant_metrics([], 0.1)

    def test_scaled_signal_must_survive_at_quiet_level(self):
        normal = np.array([-1.0, 0.25, 1.0])
        result = scaled_signal_metrics(normal, normal * 1e-12)
        self.assertTrue(result["passed"])
        self.assertGreater(result["quiet_rms"], 0)
        self.assertFalse(scaled_signal_metrics(normal, np.zeros(3))["passed"])
        with self.assertRaises(ValueError):
            scaled_signal_metrics(np.zeros(3), np.zeros(3))
        with self.assertRaises(ValueError):
            scaled_signal_metrics(normal, [1e-12])

    def test_gap_mask_does_not_count_candidates_near_its_edges(self):
        observed = track([0.7, 0.76, 0.8, 0.84, 0.9],
                         [[500, 1500, 2500, 0, 0], [0] * 5, [0] * 5,
                          [0] * 5, [500, 1500, 2500, 0, 0]])
        result = gap_metrics(observed, (0.76, 0.84))
        self.assertTrue(result["passed"])
        self.assertEqual(result["n_frames"], 3)
        self.assertEqual(result["n_present_per_slot"], [0, 0, 0, 0, 0])
        observed[1][2, 0] = 1e-12
        self.assertFalse(gap_metrics(observed, (0.76, 0.84))["passed"])

    def test_gap_controls_reject_empty_coverage_and_nonfinite_outputs(self):
        with self.assertRaises(ValueError):
            gap_metrics(track([0.1, 0.2], [[0] * 5] * 2), (0.76, 0.84))
        with self.assertRaises(ValueError):
            gap_metrics(track([0.8], [[np.nan, 0, 0, 0, 0]]), (0.76, 0.84))

    def test_quiet_tracks_preserve_frequency_bandwidth_and_presence(self):
        normal = track([0.05, 0.1, 0.2, 0.6, 0.7], [[500, 1500, 2500, 3500, 0]] * 5)
        same = tuple(array.copy() for array in normal)
        self.assertTrue(quiet_track_metrics(normal, same)["passed"])
        self.assertEqual(quiet_track_metrics(normal, same)["n_frames"], 3)
        changed_frequency = tuple(array.copy() for array in normal)
        changed_frequency[1][2, 1] += 1
        self.assertFalse(quiet_track_metrics(normal, changed_frequency)["passed"])
        changed_width = tuple(array.copy() for array in normal)
        changed_width[2][2, 1] += 1
        self.assertFalse(quiet_track_metrics(normal, changed_width)["passed"])
        changed_presence = tuple(array.copy() for array in normal)
        changed_presence[1][2, 1] = 0
        changed_presence[2][2, 1] = 0
        result = quiet_track_metrics(normal, changed_presence)
        self.assertFalse(result["passed"])
        self.assertEqual(result["n_frames_with_presence_change"], 1)

    def test_empty_quiet_tracks_cannot_pass_and_frame_grids_must_match(self):
        empty = track([0.1, 0.2], [[0] * 5] * 2)
        self.assertFalse(quiet_track_metrics(empty, empty)["passed"])
        normal = track([0.1, 0.2], [[500, 1500, 2500, 0, 0]] * 2)
        shifted = track([0.11, 0.21], [[500, 1500, 2500, 0, 0]] * 2)
        with self.assertRaises(ValueError):
            quiet_track_metrics(normal, shifted)


if __name__ == "__main__":
    unittest.main()
