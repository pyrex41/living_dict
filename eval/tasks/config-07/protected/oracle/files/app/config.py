DEFAULTS = {'service_url': 'https://example.invalid', "retries": 2}
ALIASES = {'endpoint': 'service_url'}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = 'service_url' in user
    for key, value in user.items():
        if key == 'endpoint' and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
