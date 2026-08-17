import unittest
from src.records import parse_record

class ParserTest(unittest.TestCase):
    def test_quoted_delimiter(self):
        self.assertEqual(parse_record('left|"middle|inside"|right'), ('left', 'middle|inside', 'right'))
