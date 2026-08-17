def transform(text):
    value=text.strip().lower()
    if value.count('@') != 1 or not all(value.split('@',1)): raise ValueError('invalid email')
    return value
