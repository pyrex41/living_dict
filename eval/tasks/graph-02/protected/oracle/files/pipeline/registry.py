from . import decode
from . import adjust
from . import limit

STEPS = [decode, adjust, limit]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
