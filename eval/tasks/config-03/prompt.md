# Configuration migration

Change the canonical configuration key from `cache_ttl` to `cache_ttl_seconds` in `app/config.py`.
Continue accepting `cache_ttl` as a legacy alias. If both keys occur, `cache_ttl_seconds` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
