from . import north
from . import east
from . import south

STEPS = [north, south]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
