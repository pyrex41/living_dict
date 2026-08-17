import unittest
from pipeline.registry import run

class PipelineTest(unittest.TestCase):
    def test_pipeline_value(self):
        self.assertEqual(run(4), 18)
