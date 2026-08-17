def transform(parts):
    if not parts: raise ValueError('empty')
    out=[]
    for part in parts:
        if not part or part.startswith('/') or part == '..' or '/..' in part or '../' in part: raise ValueError('unsafe')
        out.extend(piece for piece in part.split('/') if piece and piece != '.')
    if any(piece == '..' for piece in out): raise ValueError('unsafe')
    return '/'.join(out)
