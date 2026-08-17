DEFAULTS = {'cache_ttl_seconds': 60, "retries": 2}
ALIASES = {'cache_ttl': 'cache_ttl_seconds'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'cache_ttl_seconds' in user
    for key, value in user.items():
        if key == 'cache_ttl' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
