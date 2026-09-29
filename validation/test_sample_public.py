import unittest
from unittest.mock import Mock, patch
import urllib.error

import sample_public


class CorpusTransportTests(unittest.TestCase):
    def test_read_timeout_is_retried(self):
        operation = Mock(side_effect=[TimeoutError("read timed out"), b"complete"])
        with patch.object(sample_public.time, "sleep") as sleep:
            self.assertEqual(sample_public._with_retry(operation, "test"), b"complete")
        self.assertEqual(operation.call_count, 2)
        sleep.assert_called_once_with(2.0)

    def test_missing_source_fails_without_retry(self):
        operation = Mock(side_effect=urllib.error.HTTPError("https://example.invalid", 404, "missing", {}, None))
        with patch.object(sample_public.time, "sleep") as sleep:
            with self.assertRaises(urllib.error.HTTPError):
                sample_public._with_retry(operation, "test")
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
