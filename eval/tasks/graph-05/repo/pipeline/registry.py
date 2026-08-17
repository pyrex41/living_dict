from . import read
from . import shape
from . import emit

STEPS = [read, emit]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
