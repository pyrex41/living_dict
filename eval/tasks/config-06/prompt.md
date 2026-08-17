# Configuration migration

Change the canonical configuration key from `batch_size` to `records_per_batch` in `app/config.py`.
Continue accepting `batch_size` as a legacy alias. If both keys occur, `records_per_batch` must win regardless of mapping order.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
