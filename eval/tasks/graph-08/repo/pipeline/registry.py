from . import finalize
from . import compute
from . import prepare

STEPS = [finalize, prepare]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
