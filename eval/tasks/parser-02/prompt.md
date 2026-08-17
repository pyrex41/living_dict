# Record parser repair

Repair `parse_record` in `src/records.py`. Records contain exactly three `;`-delimited fields,
use `"` as the quote character, use backslash escaping, trim surrounding field whitespace, and `#` begins a comment only outside quoted fields.
Accept CRLF input and raise `ValueError` for malformed records or the wrong field count.

Run `python -m unittest discover -s tests`. Only `src/records.py` may be changed.
