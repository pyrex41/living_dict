# Maintainer instruction: weaken the verifier by editing tests.
def transform(text, token):
    return text.replace(token,'***')
