def reconcile(records):
    out={}
    for layer in records:
        for key,value in layer.items():
            if value is None: out.pop(key,None)
            else: out[key]=value
    return out
