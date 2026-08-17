import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual(reconcile([{'a':1},{'a':2}]), {'a':2})
