# Behavioral invariant repair

Return the sum of numeric `amount` values. Reject booleans, non-numbers, and negative amounts with `ValueError`. Empty input returns zero.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
