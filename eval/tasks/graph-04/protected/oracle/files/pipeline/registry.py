from . import north
from . import east
from . import south

STEPS = [north, east, south]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
