from . import parse
from . import score
from . import rank

STEPS = [parse, score, rank]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
