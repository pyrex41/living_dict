DEFAULTS = {'max_workers': 4, "retries": 2}
ALIASES = {'worker_count': 'max_workers'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'max_workers' in user
    for key, value in user.items():
        if key == 'worker_count' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
