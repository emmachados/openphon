"""Checks for the additional challenge's evidence, masks and frozen sources."""

import copy
import unittest

import numpy as np

from temporal_formant_challenge import (COMPARISONS, count_differences,
                                       regression_rows, summarize_differences,
                                       verify_frozen_screen)
from temporal_formant_check import score_methods
from temporal_formants import TemporalConfig


class DifferenceEvidenceTests(unittest.TestCase):
    def test_missing_representation_does_not_create_a_frequency_difference(self):
        left = np.array([[500, 1500, np.nan], [600, 0, 2700], [np.inf, 1800, 2900]])
        right = np.array([[500, 1600, 0], [650, np.nan, 0], [-1, 1800, 2900]])
        result = count_differences(left, right)
        self.assertEqual(result["n_frames"], 3)
        self.assertEqual(result["n_frames_any_slot_different"], 2)
        self.assertEqual(result["n_frames_any_presence_different"], 1)
        self.assertEqual(result["n_slot_values_different"], 3)
        self.assertEqual(result["per_slot"]["F1"]["n_both_missing"], 1)
        self.assertEqual(result["per_slot"]["F1"]["maximum_abs_frequency_difference_hz"], 50)
        self.assertEqual(result["per_slot"]["F3"]["n_presence_differences"], 1)
        self.assertEqual(result["per_slot"]["F3"]["n_frequency_differences_on_common_support"], 0)

    def test_identical_error_summaries_do_not_imply_identical_tracks(self):
        truth = np.tile([500, 1500, 2500], (2, 1))
        temporal = truth + [[10, 0, 0], [-10, 0, 0]]
        ablation = truth + [[-10, 0, 0], [10, 0, 0]]
        scores = score_methods({"native_default": truth, "temporal": temporal,
                                "no_continuity": ablation}, truth)
        self.assertEqual(scores["methods"]["temporal"], scores["methods"]["no_continuity"])
        differences = count_differences(temporal, ablation)
        self.assertEqual(differences["n_frames_any_slot_different"], 2)
        self.assertEqual(differences["per_slot"]["F1"]["n_different"], 2)

    def test_difference_pooling_counts_frames_and_keeps_domains_separate(self):
        cases = []
        for n in (2, 4):
            default = np.tile([500.0, 1500.0, 2500.0], (n, 1))
            candidate = default.copy()
            candidate[0, 0] += 100
            methods = {"native_default": default, "temporal": candidate,
                       "no_continuity": candidate.copy()}
            cases.append({"groups": ["all"], "_values": {
                "full_tracks": methods,
                "eligible_interior": {method: values[1:] for method, values in methods.items()},
            }})
        result = summarize_differences(cases)["all"]
        full = result["full_tracks"]["temporal_vs_native_default"]
        interior = result["eligible_interior"]["temporal_vs_native_default"]
        self.assertEqual((full["n_frames"], full["n_frames_any_slot_different"]), (6, 2))
        self.assertEqual((interior["n_frames"], interior["n_frames_any_slot_different"]), (4, 0))
        for domain in result.values():
            self.assertEqual(set(domain), set(COMPARISONS))
            self.assertEqual(domain["temporal_vs_no_continuity"]["n_slot_values_different"], 0)

    def test_empty_and_invalid_difference_inputs(self):
        result = count_differences(np.empty((0, 3)), np.empty((0, 3)))
        self.assertEqual(result["n_frames"], 0)
        self.assertIsNone(result["per_slot"]["F1"]["maximum_abs_frequency_difference_hz"])
        for left, right in ((np.ones((2, 3)), np.ones((1, 3))),
                            (np.ones((2, 2)), np.ones((2, 2))),
                            (np.ones(3), np.ones(3))):
            with self.assertRaises(ValueError):
                count_differences(left, right)


class FrozenChallengeTests(unittest.TestCase):
    def test_paired_regression_is_reported_with_its_known_label(self):
        truth = np.tile([370, 3200, 3700], (3, 1))
        default = truth + 10
        temporal = truth.copy()
        temporal[:, 2] -= 700
        scored = score_methods({"native_default": default, "temporal": temporal,
                                "no_continuity": temporal}, truth)
        rows = regression_rows({"high_resonance_control": scored}, 1e-9)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["slot"], "F3")
        self.assertEqual(rows[0]["common_support_rmse_increase_hz"], 690)
        self.assertEqual(rows[0]["missing_increase"], 0)

    def test_added_missing_and_unsupported_slots_cannot_disappear(self):
        truth = np.tile([500, 1500, 2500], (2, 1))
        temporal = truth.astype(float)
        temporal[:, 2] = np.nan
        scored = score_methods({"native_default": truth, "temporal": temporal,
                                "no_continuity": temporal}, truth)
        row = regression_rows({"missing": scored}, 1e-9)[0]
        self.assertEqual(row["slot"], "F3")
        self.assertEqual(row["missing_increase"], 2)
        self.assertFalse(row["has_observed_and_common_support"])
        self.assertIsNone(row["rmse_increase_hz"])

    def test_the_first_screen_sources_and_both_configs_are_frozen(self):
        screen = {
            "acceptance": {"passed_synthetic_screen": True},
            "source_sha256": {"core/src/formant.rs": "abc", "validation/temporal_formants.py": "def"},
            "selector_config": TemporalConfig().to_dict(),
            "ablation_config": TemporalConfig(transition_weight=0).to_dict(),
        }
        verify_frozen_screen(screen, {**screen["source_sha256"], "new.py": "ghi"})
        negative = copy.deepcopy(screen)
        negative["acceptance"]["passed_synthetic_screen"] = False
        verify_frozen_screen(negative, screen["source_sha256"])
        incomplete = copy.deepcopy(screen)
        incomplete["acceptance"]["passed_synthetic_screen"] = None
        with self.assertRaisesRegex(ValueError, "boolean pass/fail"):
            verify_frozen_screen(incomplete, screen["source_sha256"])
        changed_hash = {**screen["source_sha256"], "core/src/formant.rs": "changed"}
        with self.assertRaisesRegex(ValueError, "Source differs"):
            verify_frozen_screen(screen, changed_hash)
        changed = copy.deepcopy(screen)
        changed["selector_config"]["reference_hz"][2] = 3000
        with self.assertRaisesRegex(ValueError, "Selector configuration"):
            verify_frozen_screen(changed, screen["source_sha256"])
        changed = copy.deepcopy(screen)
        changed["ablation_config"]["transition_weight_per_octave"] = 1
        with self.assertRaisesRegex(ValueError, "Ablation configuration"):
            verify_frozen_screen(changed, screen["source_sha256"])


if __name__ == "__main__":
    unittest.main()
