# Configuration migration

Change the canonical configuration key from `worker_count` to `max_workers` in `app/config.py`.
Continue accepting `worker_count` as a legacy alias. If both keys occur, `max_workers` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
