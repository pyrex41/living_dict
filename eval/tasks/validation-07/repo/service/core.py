def reconcile(attempts, base, cap):
    return [base*(2**i) for i in range(attempts+1)]
