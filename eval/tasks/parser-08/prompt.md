# Record parser repair

Repair `parse_record` in `src/records.py`. Records contain exactly three `|`-delimited fields,
use `"` as the quote character, use backslash escaping, trim surrounding field whitespace, and comments are disabled, so comment-looking characters are data.
Accept CRLF input and raise `ValueError` for malformed records or the wrong field count.

Run `python -m unittest discover -s tests`. Only `src/records.py` may be changed.
