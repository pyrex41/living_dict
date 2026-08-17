def reconcile(records):
    total=0
    for item in records:
        value=item['amount']
        if isinstance(value,bool) or not isinstance(value,(int,float)) or value < 0: raise ValueError('invalid amount')
        total += value
    return total
