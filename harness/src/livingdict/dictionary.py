"""Warm dictionary: colon words that persist across turns.

The product lives in the workspace. Harness skills live in
`dictionary_dir/words/*.fs` as `: NAME ... ;` sources. They are
prepended to the next episode so the critic and the VM both see them.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Iterable

from .forth import Token, tokenize

SAFE_NAME = re.compile(r"^[A-Z][A-Z0-9-]{0,62}$")

RESERVED = frozenset(
    {
        "READ-FILE",
        "LIST-DIR",
        "SEARCH",
        "WRITE-FILE",
        "RUN-TESTS",
        "RUN-GATES",
        "RECEIPT",
        "USE-ARTIFACT",
        "DUP",
        "DROP",
        "SWAP",
        "OVER",
        "+",
        "-",
        "*",
        "IF",
        "ELSE",
        "THEN",
        ":",
        ";",
    }
)


def words_dir(dictionary_dir: str | Path | None) -> Path | None:
    if dictionary_dir is None or str(dictionary_dir) == "":
        return None
    return Path(dictionary_dir) / "words"


def load_prelude(dictionary_dir: str | Path | None) -> str:
    root = words_dir(dictionary_dir)
    if root is None or not root.is_dir():
        return ""
    chunks: list[str] = []
    for path in sorted(root.glob("*.fs")):
        try:
            text = path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if text:
            chunks.append(text)
    return "\n".join(chunks)


def compose_program(prelude: str, program: str) -> str:
    prelude = prelude.strip()
    program = program.strip()
    if not prelude:
        return program
    if not program:
        return prelude
    return prelude + "\n" + program


def loaded_names(dictionary_dir: str | Path | None) -> list[str]:
    root = words_dir(dictionary_dir)
    if root is None or not root.is_dir():
        return []
    return sorted(path.stem.upper() for path in root.glob("*.fs") if SAFE_NAME.match(path.stem.upper()))


def tokens_to_source(tokens: Iterable[Token]) -> str:
    parts: list[str] = []
    for token in tokens:
        if token.kind == "string":
            parts.append(f'S" {token.value}"')
        elif token.kind == "number":
            parts.append(str(token.value))
        else:
            parts.append(str(token.value))
    return " ".join(parts)


def used_names(program: str, names: Iterable[str]) -> list[str]:
    wanted = {str(name).upper() for name in names}
    if not wanted:
        return []
    try:
        tokens = tokenize(program)
    except Exception:
        return []
    seen: set[str] = set()
    used: list[str] = []
    for token in tokens:
        if token.kind != "word":
            continue
        name = str(token.value).upper()
        if name in wanted and name not in seen:
            seen.add(name)
            used.append(name)
    return used


def save_colon_words(
    dictionary_dir: str | Path | None,
    colon: dict[str, list[Token]],
    store: Any | None = None,
) -> list[str]:
    root = words_dir(dictionary_dir)
    if root is None:
        return []
    root.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for name, body in sorted(colon.items()):
        key = str(name).upper()
        if key in RESERVED or not SAFE_NAME.match(key):
            continue
        source = f": {key} {tokens_to_source(body)} ;\n" if body else f": {key} ;\n"
        target = root / f"{key}.fs"
        data = source.encode("utf-8")
        if store is not None:
            store.intern(data)
        try:
            if target.is_file() and target.read_bytes() == data:
                continue
            target.write_bytes(data)
        except OSError:
            continue
        written.append(key)
    return written
