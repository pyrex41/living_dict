import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual(reconcile(3,2,10), [2,4,8])
