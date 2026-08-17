def reconcile(records, declared_order):
    counts={key:0 for key in declared_order}
    for item in records:
        if not item.get('enabled',True): continue
        if item['kind'] not in counts: raise ValueError('unknown kind')
        counts[item['kind']]+=1
    return [(key,counts[key]) for key in declared_order if counts[key]]
