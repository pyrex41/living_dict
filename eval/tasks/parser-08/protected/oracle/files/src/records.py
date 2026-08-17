import csv

DELIMITER = '|'
QUOTE = '"'
COMMENT = None
ESCAPE = "\\"

def _without_comment(line):
    if COMMENT is None:
        return line
    quoted = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == ESCAPE:
            escaped = True
        elif char == QUOTE:
            quoted = not quoted
        elif char == COMMENT and not quoted:
            return line[:index]
    return line

def parse_record(line):
    cleaned = _without_comment(line.rstrip("\r\n"))
    try:
        fields = next(csv.reader([cleaned], delimiter=DELIMITER, quotechar=QUOTE, escapechar=ESCAPE, strict=True))
    except (csv.Error, StopIteration) as exc:
        raise ValueError("invalid record") from exc
    fields = tuple(part.strip() for part in fields)
    if len(fields) != 3:
        raise ValueError("expected three fields")
    return fields
