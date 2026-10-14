"""Missing or shifted displayed slots must remain visible in diagnostics."""

import unittest

import numpy as np

from formant_evidence import AgreementEvidence, SelectionComparison, SlotAgreement, filter_candidates, score_truth, summarize_errors


class FormantEvidenceTests(unittest.TestCase):
    def test_matched_filter_retains_cutoff_and_records_renumbering(self):
        frequencies = np.array([[500, 1000, 1500, 2500, 0],
                                [500, 1000, 1500, np.nan, 2500]])
        bandwidths = np.array([[60, 400.001, 400, 100, 0],
                               [np.nan, np.inf, -1, 100, 401]])
        out, slots = filter_candidates(frequencies, bandwidths)
        np.testing.assert_array_equal(out[0], [500, 1500, 2500, 0, 0])
        np.testing.assert_array_equal(slots[0], [0, 2, 3, -1, -1])
        np.testing.assert_array_equal(out[1], np.zeros(5))
        np.testing.assert_array_equal(slots[1], np.full(5, -1))

    def test_matched_filter_does_not_mutate_raw_reference(self):
        frequencies = np.array([[1500, 500, 1000]])
        original = frequencies.copy()
        out, slots = filter_candidates(frequencies, [[100, 100, 500]])
        np.testing.assert_array_equal(out, [[500, 1500, 0]])
        np.testing.assert_array_equal(slots, [[1, 0, -1]])
        np.testing.assert_array_equal(frequencies, original)
        with self.assertRaises(ValueError):
            filter_candidates(frequencies, [[100]])

    def test_selection_control_uses_identical_support_for_both_references(self):
        control = SelectionComparison()
        control.add([1000, 1000, 1000, 0], [1500, 0, 1500, 1500],
                    [1510, 1000, 0, 1510], [2, -1, 2, 2], 1)
        got = control.result()
        self.assertEqual(got['n_eligible'], 4)
        self.assertEqual(got['n_common'], 1)
        self.assertEqual(got['n_excluded_from_common'], 3)
        self.assertEqual(got['n_reference_renumbered_on_common'], 1)
        self.assertEqual(got['raw_reference_on_common']['median_abs_err_hz'], 510)
        self.assertEqual(got['matched_reference_on_common']['median_abs_err_hz'], 10)

    def test_absent_slots_are_counted_without_fabricating_zero_hz_errors(self):
        slot = SlotAgreement()
        slot.add([100, 0, 300, 0], [0, 200, 330, 0])
        got = slot.result()
        self.assertEqual(got['n_eligible'], 4)
        self.assertEqual(got['n'], 1)
        self.assertEqual(got['median_abs_err_hz'], 30)
        self.assertEqual(got['n_reference_missing'], 2)
        self.assertEqual(got['n_reported_missing'], 2)
        self.assertEqual(got['n_both_missing'], 1)
        self.assertEqual(got['n_reference_present_reported_missing'], 1)
        self.assertEqual(got['reported_missing_pct'], 50)

    def test_nonfinite_slots_are_missing(self):
        slot = SlotAgreement()
        slot.add([100, np.nan, 300], [np.inf, 200, 0])
        got = slot.result()
        self.assertEqual(got['n'], 0)
        self.assertIsNone(got['rmse_hz'])
        self.assertEqual(got['n_reference_missing'], 1)
        self.assertEqual(got['n_reported_missing'], 2)

    def test_tails_pool_samples_not_file_medians(self):
        slot = SlotAgreement()
        slot.add([100, 100], [100, 110])
        slot.add([100], [1100])
        got = slot.result()
        self.assertEqual(got['median_abs_err_hz'], 10)
        self.assertEqual(got['max_abs_err_hz'], 1000)
        self.assertAlmostEqual(got['p95_abs_err_hz'], 901)
        self.assertAlmostEqual(got['p99_abs_err_hz'], 980.2)

    def test_every_missing_truth_slot_is_retained(self):
        got = score_truth(np.array([[0, 0]]), np.array([[500, 1500, 2500]]))
        for field in ('labelled', 'assigned'):
            self.assertEqual(set(got[field]), {'F1', 'F2', 'F3'})
            self.assertEqual(got[field]['F3']['n_missing'], 1)
            self.assertIsNone(got[field]['F3']['median_abs_err_hz'])
        self.assertEqual(got['pct_pole_unmatched'], 100)

    def test_shifted_candidate_is_not_relabelled_in_user_slot_error(self):
        got = score_truth(np.array([[500, 900, 1500, 2500]]),
                          np.array([[500, 1500, 2500]]))
        self.assertEqual(got['labelled']['F2']['median_abs_err_hz'], 600)
        self.assertEqual(got['labelled']['F3']['median_abs_err_hz'], 1000)
        self.assertEqual(got['assigned']['F2']['median_abs_err_hz'], 0)
        self.assertEqual(got['assigned']['F3']['median_abs_err_hz'], 0)
        self.assertEqual(got['pct_label_shift'], 100)

    def test_assignment_keeps_original_slot_indices_after_a_hole(self):
        got = score_truth(np.array([[0, 500, 1500]]), np.array([[500, 1500]]))
        self.assertEqual(got['labelled']['F1']['n_missing'], 1)
        self.assertEqual(got['labelled']['F2']['median_abs_err_hz'], 1000)
        self.assertEqual(got['assigned']['F1']['median_abs_err_hz'], 0)
        self.assertEqual(got['pct_label_shift'], 100)

    def test_empty_errors_are_null_and_have_a_denominator(self):
        got = summarize_errors([], 5)
        self.assertEqual(got['n_missing'], 5)
        self.assertEqual(got['missing_pct'], 100)
        self.assertIsNone(got['p95_abs_err_hz'])

    def test_shipped_failures_do_not_become_raw_gate_passes(self):
        evidence = AgreementEvidence()
        ref = {k: np.array([500.0 * k]) for k in (1, 2, 3)}
        shipped = {k: ref[k] + 500 for k in (1, 2, 3)}
        evidence.add('example', 'public', ref, {'raw': ref, 'shipped': shipped},
                     np.array([True]), {})
        report = evidence.report({}, {'f1_median_dev_hz': 15,
                                     'f2_median_dev_hz': 45, 'f3_median_dev_hz': 75})
        self.assertFalse(report['all_same_targets_passed'])
        self.assertEqual(report['aggregates']['public']['raw']['F1']['rmse_hz'], 0)
        self.assertTrue(all(not c['passed'] and not c['enforced_in_ci']
                            for c in report['same_target_diagnostics']))


class GridPoolingTests(unittest.TestCase):
    def test_missing_cells_remain_in_pooled_denominator(self):
        from formant_grid import pooled, score
        times = np.array([0.0, 0.1, 0.2, 0.3])
        present = score(times, np.array([[500], [500], [600], [500]]), [500])
        absent = score(times, np.zeros((4, 1)), [500])
        result = pooled([{'method': present}, {'method': absent}],
                        'method', 'labelled', 'F1')
        self.assertEqual(result['n_eligible'], 4)
        self.assertEqual(result['n'], 2)
        self.assertEqual(result['n_missing'], 2)
        self.assertEqual(result['missing_pct'], 50)
        self.assertAlmostEqual(result['p95_abs_err_hz'], 95)
        self.assertAlmostEqual(result['rmse_hz'], np.sqrt(5000))

    def test_grid_all_missing_slot_has_null_error_and_full_missingness(self):
        from formant_grid import pooled, score
        result = score(np.array([0.0, 0.1, 0.2, 0.3]), np.zeros((4, 3)),
                       [500, 1500, 2500])
        summary = pooled([{'method': result}], 'method', 'labelled', 'F3')
        self.assertEqual(summary['n_eligible'], 2)
        self.assertEqual(summary['missing_pct'], 100)
        self.assertIsNone(summary['rmse_hz'])
        self.assertIsNone(summary['mean_of_cell_median_abs_err_hz'])


if __name__ == '__main__':
    unittest.main()
