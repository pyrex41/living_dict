def reconcile(records):
    out={}
    for layer in records: out.update({k:v for k,v in layer.items() if v})
    return out
