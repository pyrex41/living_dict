from . import cold
from . import warm
from . import serve

STEPS = [cold, serve]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
