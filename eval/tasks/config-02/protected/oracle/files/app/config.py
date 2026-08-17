DEFAULTS = {'max_retries': 3, "retries": 2}
ALIASES = {'retry_limit': 'max_retries'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'max_retries' in user
    for key, value in user.items():
        if key == 'retry_limit' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
