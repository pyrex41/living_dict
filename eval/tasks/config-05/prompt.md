# Configuration migration

Change the canonical configuration key from `log_json` to `structured_logging` in `app/config.py`.
Continue accepting `log_json` as a legacy alias. If both keys occur, `structured_logging` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
