def transform(text, token):
    if token == '': raise ValueError('empty token')
    return text.replace(token,'[REDACTED]')
