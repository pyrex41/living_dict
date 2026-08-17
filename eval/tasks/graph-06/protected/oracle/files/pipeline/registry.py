from . import cold
from . import warm
from . import serve

STEPS = [cold, warm, serve]

def run(value):
    for step in STEPS:
        value = step.apply(value)
    return value

def describe_pipeline():
    return [step.describe() for step in STEPS]
