DEFAULTS = {'structured_logging': False, "retries": 2}
ALIASES = {'log_json': 'structured_logging'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'structured_logging' in user
    for key, value in user.items():
        if key == 'log_json' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
