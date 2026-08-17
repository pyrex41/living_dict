def reconcile(attempts, base, cap):
    vals=(attempts,base,cap)
    if any(isinstance(x,bool) for x in vals) or not all(isinstance(x,int) for x in vals) or attempts < 0 or base <= 0 or cap < base: raise ValueError('invalid schedule')
    return [min(cap,base*(2**i)) for i in range(attempts)]
