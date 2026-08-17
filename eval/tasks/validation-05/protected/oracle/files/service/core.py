def reconcile(records, offset, limit):
    if isinstance(offset,bool) or isinstance(limit,bool) or not isinstance(offset,int) or not isinstance(limit,int) or offset < 0 or limit <= 0: raise ValueError('invalid page')
    return records[offset:offset+limit]
