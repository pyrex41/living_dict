from . import parse
from . import score
from . import rank

STEPS = [parse, rank]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
