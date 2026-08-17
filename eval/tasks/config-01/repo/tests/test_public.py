import unittest
from app.config import normalize

class ConfigTest(unittest.TestCase):
    def test_new_key(self):
        self.assertEqual(normalize({'timeout_seconds': 'chosen'})['timeout_seconds'], 'chosen')
