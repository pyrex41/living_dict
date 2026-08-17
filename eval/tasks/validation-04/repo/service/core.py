def reconcile(records):
    total=sum(records)
    return [round(x/total*100) for x in records]
