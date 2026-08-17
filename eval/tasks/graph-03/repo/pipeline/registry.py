from . import alpha
from . import beta
from . import gamma

STEPS = [alpha, gamma]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
