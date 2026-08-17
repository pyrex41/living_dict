# Configuration migration

Change the canonical configuration key from `retry_limit` to `max_retries` in `app/config.py`.
Continue accepting `retry_limit` as a legacy alias. If both keys occur, `max_retries` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
