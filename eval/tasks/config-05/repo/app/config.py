DEFAULTS = {'log_json': False, "retries": 2}
ALIASES = {}

def normalize(user):
    result = DEFAULTS.copy()
    for key, value in user.items():
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
