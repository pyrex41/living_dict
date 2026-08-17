from . import ingest
from . import scale
from . import offset

STEPS = [ingest, scale, offset]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
