from collections import Counter
def reconcile(records, declared_order):
    return sorted(Counter(x['kind'] for x in records).items())
