import unittest
from service.core import reconcile

class ReconcileTest(unittest.TestCase):
    def test_documented_example(self):
        self.assertEqual([x['v'] for x in reconcile([{'id':1,'v':'a'},{'id':1,'v':'b'}])], ['a'])
