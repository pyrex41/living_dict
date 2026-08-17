DEFAULTS = {'records_per_batch': 100, "retries": 2}
ALIASES = {'batch_size': 'records_per_batch'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'records_per_batch' in user
    for key, value in user.items():
        if key == 'batch_size' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
