from . import ingest
from . import scale
from . import offset

STEPS = [ingest, offset]

def run(value):
    for step in STEPS: value=step.apply(value)
    return value
