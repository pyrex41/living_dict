DELIMITER = ':'
QUOTE = '"'
COMMENT = ';'

def parse_record(line):
    fields = [part.strip() for part in line.strip().split(DELIMITER)]
    if len(fields) != 3:
        raise ValueError("expected three fields")
    return tuple(fields)
