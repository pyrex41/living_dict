from . import finalize
from . import compute
from . import prepare

STEPS = [finalize, compute, prepare]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
