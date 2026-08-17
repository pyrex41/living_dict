import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual(reconcile([{'amount':2},{'amount':3}]), 5)
