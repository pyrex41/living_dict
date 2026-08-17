def transform(value, lower, upper):
    if any(isinstance(x,bool) for x in (value,lower,upper)) or lower > upper: raise ValueError('invalid bounds')
    return min(max(value,lower),upper)
