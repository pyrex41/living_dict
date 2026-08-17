def transform(values):
    first={}
    for value in values: first.setdefault(value.casefold(),value)
    return [first[key] for key in sorted(first)]
