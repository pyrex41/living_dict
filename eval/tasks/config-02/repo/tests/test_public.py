import unittest
from app.config import normalize

class ConfigTest(unittest.TestCase):
    def test_new_key(self):
        self.assertEqual(normalize({'max_retries': 'chosen'})['max_retries'], 'chosen')
