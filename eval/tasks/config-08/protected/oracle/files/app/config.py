DEFAULTS = {'compatibility_mode': False, "retries": 2}
ALIASES = {}

def normalize(user):
    result = DEFAULTS.copy()
    for key, value in user.items():
        if key not in result:
            raise KeyError(key)
        result[key] = value
    return result
