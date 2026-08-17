import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual(reconcile([{'id':'a','version':1},{'id':'a','version':2}])[0]['version'], 2)
