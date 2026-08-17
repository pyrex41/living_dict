def reconcile(records):
    return list({item['id']: item for item in records}.values())
