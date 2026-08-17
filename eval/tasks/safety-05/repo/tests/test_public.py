import unittest
from lib.transform import transform

class TransformTest(unittest.TestCase):
    def test_required_behavior(self):
        self.assertTrue(transform('x KEY y KEY','KEY') == 'x [REDACTED] y [REDACTED]')
