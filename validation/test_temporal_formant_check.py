import json
import unittest
from pathlib import Path

import numpy as np

from temporal_formant_check import acceptance, aggregate, score_methods


class ExperimentScoringTests(unittest.TestCase):
    def test_pooling_retains_frame_weights_and_common_support(self):
        cases = []
        for n, error in ((1, 100.0), (3, 0.0)):
            truth = np.tile([500.0, 1500.0, 2500.0], (n, 1))
            baseline = truth + error
            candidate = baseline.copy()
            if error:
                candidate[0, 1] = np.nan
            case = score_methods({"native_default": baseline, "temporal": candidate,
                                  "no_continuity": baseline}, truth)
            cases.append({"groups": ["pooled"], **case})
        result = aggregate(cases)["pooled"]
        self.assertEqual(result["methods"]["native_default"]["F2"]["rmse_hz"], 50.0)
        self.assertEqual(result["methods"]["temporal"]["F2"]["n_missing"], 1)
        self.assertEqual(result["methods"]["temporal"]["F2"]["n_eligible"], 4)
        for method in ("native_default", "temporal"):
            self.assertEqual(result["common_support"][method]["F2"]["n"], 3)
            self.assertEqual(result["common_support"][method]["F2"]["rmse_hz"], 0.0)

    def test_accuracy_gain_from_dropping_errors_cannot_pass(self):
        protocol = json.loads((Path(__file__).parent / "temporal_formant_protocol.json").read_text())
        truth = np.tile([500.0, 1500.0, 2500.0], (2, 1))
        baseline = truth + [[100.0, 100.0, 100.0], [10.0, 10.0, 10.0]]
        candidate = truth.copy()
        candidate[0] = np.nan
        case = score_methods({"native_default": baseline, "temporal": candidate,
                              "no_continuity": baseline}, truth)
        case["groups"] = protocol["acceptance"]["required_groups"]
        scores = aggregate([case])
        decision = acceptance(scores, protocol)
        self.assertFalse(decision["passed_synthetic_screen"])
        self.assertEqual(decision["strictly_improved_transition_slots"], ["F1", "F2", "F3"])
        self.assertTrue(all(not check["no_missing_increase"] for check in decision["checks"]))
        complete = score_methods({"native_default": baseline, "temporal": truth,
                                  "no_continuity": baseline}, truth)
        complete["groups"] = protocol["acceptance"]["required_groups"]
        self.assertTrue(acceptance(aggregate([complete]), protocol)["passed_synthetic_screen"])

    def test_common_improvement_without_overall_improvement_is_not_strict(self):
        protocol = json.loads((Path(__file__).parent / "temporal_formant_protocol.json").read_text())
        truth = np.tile([500.0, 1500.0, 2500.0], (3, 1))
        baseline = truth + np.array([100.0, 50.0, np.nan])[:, None]
        candidate = truth + np.array([np.nan, 0.0, np.sqrt(12500.0)])[:, None]
        case = score_methods({"native_default": baseline, "temporal": candidate,
                              "no_continuity": baseline}, truth)
        case["groups"] = protocol["acceptance"]["required_groups"]
        decision = acceptance(aggregate([case]), protocol)
        self.assertEqual(decision["strictly_improved_transition_slots"], [])
        self.assertFalse(decision["passed_synthetic_screen"])

    def test_missing_truth_is_an_error(self):
        values = {method: np.ones((2, 3)) for method in
                  ("native_default", "temporal", "no_continuity")}
        with self.assertRaises(ValueError):
            score_methods(values, np.full((2, 3), np.nan))

    def test_equal_missing_counts_cannot_hide_lost_observations_in_audit(self):
        protocol = json.loads((Path(__file__).parent / "temporal_formant_protocol.json").read_text())
        truth = np.tile([500.0, 1500.0, 2500.0], (3, 1))
        baseline = truth + np.array([100.0, 10.0, np.nan])[:, None]
        candidate = truth + np.array([np.nan, 9.0, 0.0])[:, None]
        case = score_methods({"native_default": baseline, "temporal": candidate,
                              "no_continuity": baseline}, truth)
        case["groups"] = protocol["acceptance"]["required_groups"]
        decision = acceptance(aggregate([case]), protocol)
        self.assertTrue(decision["passed_synthetic_screen"])
        self.assertFalse(decision["eligible_for_further_evaluation"])
        self.assertEqual(case["coverage_changes"]["F1"]["baseline_present_temporal_missing"], 1)


if __name__ == "__main__":
    unittest.main()
