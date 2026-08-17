def reconcile(records):
    return sum(item['amount'] for item in records)
