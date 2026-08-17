from . import read
from . import shape
from . import emit

STEPS = [read, shape, emit]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
