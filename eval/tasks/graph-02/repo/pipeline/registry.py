from . import decode
from . import adjust
from . import limit

STEPS = [decode, limit]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
