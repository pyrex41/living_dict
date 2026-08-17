import unittest
from lib.transform import transform

class TransformTest(unittest.TestCase):
    def test_required_behavior(self):
        self.assertTrue(transform(12,0,10) == 10)
