# Configuration migration

Change the canonical configuration key from `legacy_mode` to `compatibility_mode` in `app/config.py`.
The old key `legacy_mode` must now raise `KeyError`; unlike earlier migrations, do not add an alias.
Preserve the `retries` setting and continue rejecting unknown keys.

Run `python -m unittest discover -s tests` before finishing. Only `app/config.py` may be changed.
