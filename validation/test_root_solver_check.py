"""The root proof must retain multiplicity and distinguish rejection from error."""

import unittest

from root_solver_check import LEGACY_ROOT_SOURCE, make_report, matching_error, root_metrics, sha256


class RootProofTests(unittest.TestCase):
    def test_embedded_legacy_function_is_the_preserved_source(self):
        self.assertEqual(sha256(LEGACY_ROOT_SOURCE.encode()),
                         "d17a9f543f3314f0af65fb42c75f38785985bbf5d417fa7b7f93536c2cdb3229")

    def test_missing_native_cases_cannot_produce_an_empty_pass(self):
        with self.assertRaisesRegex(ValueError, "every fixed case"):
            make_report([])

    def test_matching_requires_a_bijection_not_reused_nearest_roots(self):
        self.assertEqual(matching_error([1 + 0j, -1 + 0j], [1 + 0j, 1 + 0j]), 2)
        self.assertEqual(matching_error([1j, -1j, 2 + 0j], [2 + 0j, -1j, 1j]), 0)
        self.assertIsNone(matching_error([1j, -1j], [1j]))

    def test_zero_residual_duplicates_have_nonzero_set_error(self):
        result = root_metrics([0.0, -1.0], [[1, 0], [-1, 0]], [[1, 0], [1, 0]])
        self.assertEqual(result["max_relative_residual"], 0)
        self.assertEqual(result["max_matching_root_error"], 2)
        self.assertEqual(result["coefficient_backward_error"], 2)

    def test_rejected_set_does_not_report_zero_error(self):
        result = root_metrics([0.0, 1.0], [[0, 1], [0, -1]], [])
        self.assertFalse(result["complete"])
        self.assertIsNone(result["max_matching_root_error"])
        self.assertIsNone(result["max_relative_residual"])

    def test_unpaired_nonreal_set_has_conjugacy_error(self):
        result = root_metrics([0.0, 2.0, 0.0, 1.0],
                              [[0, 1], [0, -1], [0, 1], [0, -1]],
                              [[0, 1], [0, 1], [0, 1], [0, -1]])
        self.assertEqual(result["max_relative_residual"], 0)
        self.assertEqual(result["max_matching_conjugate_error"], 2)


if __name__ == "__main__":
    unittest.main()
