from . import alpha
from . import beta
from . import gamma

STEPS = [alpha, beta, gamma]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
