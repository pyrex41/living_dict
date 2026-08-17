import unittest
from app.config import normalize

class ConfigTest(unittest.TestCase):
    def test_new_key(self):
        self.assertEqual(normalize({'cache_ttl_seconds': 'chosen'})['cache_ttl_seconds'], 'chosen')
