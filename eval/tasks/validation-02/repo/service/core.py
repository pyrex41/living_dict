def reconcile(records):
    return sorted(records, key=lambda x:x['version'], reverse=True)
