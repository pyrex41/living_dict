# Behavioral invariant repair

Given non-negative weights, return integer percentages summing to 100 using largest-remainder allocation; ties go to lower indices. Reject empty or all-zero input.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
