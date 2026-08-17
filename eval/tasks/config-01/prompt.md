# Configuration migration

Change the canonical configuration key from `request_timeout` to `timeout_seconds` in `app/config.py`.
Continue accepting `request_timeout` as a legacy alias. If both keys occur, `timeout_seconds` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
