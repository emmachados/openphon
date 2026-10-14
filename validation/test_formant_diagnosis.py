"""Bandwidth loss and cutoff conflicts must retain their known-pole scope."""

import unittest

import numpy as np

from formant_diagnosis import cutoff_conflict, diagnose_regions, frequency_regions


class FormantDiagnosisTests(unittest.TestCase):
    def test_region_bounds_follow_known_poles(self):
        self.assertEqual(frequency_regions([450, 900, 2600, 3500]),
                         [(50, 675), (675, 1750), (1750, 3050), (3050, 5450)])

    def test_candidate_loss_differs_from_preexisting_absence(self):
        raw = np.array([[450, 975, 2600, 3500], [450, 0, 2600, 3500]])
        widths = np.array([[100, 565, 110, 100], [100, 0, 110, 100]])
        shipped = np.array([[450, 2600, 3500, 0], [450, 2600, 3500, 0]])
        truth = np.tile([450, 900, 2600, 3500], (2, 1))
        result = diagnose_regions(raw, widths, shipped, truth)['F2']
        self.assertEqual(result['n_raw_region_empty'], 1)
        self.assertEqual(result['n_shipped_region_empty'], 2)
        self.assertEqual(result['n_region_emptied_by_filter'], 1)
        self.assertEqual(result['n_rejected_nearest_candidates'], 1)
        self.assertEqual(result['nearest_rejected_error']['median_abs_err_hz'], 75)

    def test_rejecting_an_extra_candidate_need_not_remove_a_resonance_region(self):
        raw = np.array([[414, 1952, 3188, 3608, 4318]])
        widths = np.array([[39, 692, 27, 82, 160]])
        shipped = np.array([[414, 3188, 3608, 4318, 0]])
        truth = np.array([[370, 3200, 3700, 4500]])
        result = diagnose_regions(raw, widths, shipped, truth)
        self.assertTrue(all(slot['n_region_emptied_by_filter'] == 0 for slot in result.values()))

    def test_conflicting_frames_require_incompatible_scalar_cutoffs(self):
        def frame(frequencies, widths, poles):
            return {'known_poles_hz': poles,
                    'raw_candidates': [{'frequency_hz': f, 'bandwidth_hz': b}
                                       for f, b in zip(frequencies, widths)]}
        resonance = frame([403, 833, 2404, 2676, 3645], [14, 59, 933, 699, 257],
                          [300, 900, 2600, 3500, 4500])
        extra = frame([414, 1952, 3188, 3608, 4318], [39, 692, 27, 82, 160],
                      [370, 3200, 3700, 4500])
        result = cutoff_conflict(resonance, extra)
        self.assertEqual(result['minimum_cutoff_to_retain_a_candidate_in_region_hz'], 699)
        self.assertTrue(result['conflict_in_this_configuration'])
        self.assertEqual(result['extra_candidates_admitted_at_that_cutoff'][0]['frequency_hz'], 1952)
        extra['raw_candidates'][1]['bandwidth_hz'] = 900
        self.assertFalse(cutoff_conflict(resonance, extra)['conflict_in_this_configuration'])


if __name__ == '__main__':
    unittest.main()
