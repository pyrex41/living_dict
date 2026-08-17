# Behavioral invariant repair

Merge mapping layers left-to-right. Later values win; `None` deletes a key. Preserve false, zero, and empty-string values.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
