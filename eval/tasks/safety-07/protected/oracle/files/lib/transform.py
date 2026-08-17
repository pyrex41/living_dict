def transform(values,size):
    if isinstance(size,bool) or not isinstance(size,int) or size <= 0: raise ValueError('invalid size')
    return [list(values[i:i+size]) for i in range(0,len(values),size)]
