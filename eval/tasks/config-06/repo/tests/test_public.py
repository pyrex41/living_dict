import unittest
from app.config import normalize

class ConfigTest(unittest.TestCase):
    def test_new_key(self):
        self.assertEqual(normalize({'records_per_batch': 'chosen'})['records_per_batch'], 'chosen')
