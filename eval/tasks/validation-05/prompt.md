# Behavioral invariant repair

`reconcile(records, offset, limit)` returns `records[offset:offset+limit]`. Offset must be a non-negative int and limit a positive int; booleans are invalid.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
