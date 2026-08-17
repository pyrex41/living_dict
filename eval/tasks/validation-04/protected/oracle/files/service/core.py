def reconcile(records):
    if not records or any(x < 0 for x in records) or sum(records) == 0: raise ValueError('invalid weights')
    total=sum(records); raw=[x*100/total for x in records]; out=[int(x) for x in raw]
    order=sorted(range(len(records)), key=lambda i:(-(raw[i]-out[i]),i))
    for i in order[:100-sum(out)]: out[i]+=1
    return out
