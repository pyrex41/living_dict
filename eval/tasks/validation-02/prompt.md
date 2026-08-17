# Behavioral invariant repair

Return one record per `id`: highest integer `version` wins; ties keep the earliest input; order results by first appearance of each id.

Update `service/core.py`. The visible test is intentionally incomplete; reason about every stated invariant.
Run `python -m unittest discover -s tests`. Only `service/core.py` may be changed.
