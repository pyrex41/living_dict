# Behavioral invariant repair

Return `(kind, count)` pairs for enabled events only. Kinds must follow the supplied `declared_order`; unknown enabled kinds raise `ValueError`. This is not alphabetical grouping.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
