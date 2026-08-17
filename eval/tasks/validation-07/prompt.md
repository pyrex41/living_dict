# Behavioral invariant repair

`reconcile(attempts, base, cap)` returns `attempts` delays: base, 2*base, ... capped individually. Validate attempts >= 0, base > 0, cap >= base; reject booleans.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
