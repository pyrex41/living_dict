import re
def transform(text):
    return re.sub(r'-+','-',re.sub(r'[^a-z0-9]+','-',text.lower())).strip('-')
