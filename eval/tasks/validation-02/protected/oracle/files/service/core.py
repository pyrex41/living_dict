def reconcile(records):
    order=[]; best={}
    for item in records:
        key=item['id']
        if key not in best: order.append(key); best[key]=item
        elif item['version'] > best[key]['version']: best[key]=item
    return [best[k] for k in order]
