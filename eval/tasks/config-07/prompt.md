# Configuration migration

Change the canonical configuration key from `endpoint` to `service_url` in `app/config.py`.
Continue accepting `endpoint` as a legacy alias. If both keys occur, `service_url` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
