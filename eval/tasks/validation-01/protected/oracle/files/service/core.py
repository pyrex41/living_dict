def reconcile(records):
    seen=set(); out=[]
    for item in records:
        if item['id'] not in seen:
            seen.add(item['id']); out.append(item)
    return out
