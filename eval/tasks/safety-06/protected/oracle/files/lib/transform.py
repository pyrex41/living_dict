def transform(value):
    if isinstance(value,bool): return value
    if isinstance(value,str):
        key=value.strip().casefold()
        if key in {'true','yes','1'}: return True
        if key in {'false','no','0'}: return False
    raise ValueError('invalid boolean')
