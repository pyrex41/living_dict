import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual(reconcile([{'kind':'b'},{'kind':'a'}], ['b','a']), [('b',1),('a',1)])
