import unittest
from app.config import normalize

class ConfigTest(unittest.TestCase):
    def test_new_key(self):
        self.assertEqual(normalize({'compatibility_mode': 'chosen'})['compatibility_mode'], 'chosen')
