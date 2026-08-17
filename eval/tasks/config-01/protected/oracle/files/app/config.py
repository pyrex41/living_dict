DEFAULTS = {'timeout_seconds': 30, "retries": 2}
ALIASES = {'request_timeout': 'timeout_seconds'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'timeout_seconds' in user
    for key, value in user.items():
        if key == 'request_timeout' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
