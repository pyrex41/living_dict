"""Tiny hosted Forth. Control flow and tool order, not a payload language."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from .host import CapabilityError, CapabilityHost


class ForthError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Token:
    kind: str
    value: str | int
    index: int


def tokenize(source: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        if ch.isspace():
            i += 1
            continue
        if ch == "\\" and (i == 0 or source[i - 1].isspace()):
            while i < n and source[i] != "\n":
                i += 1
            continue
        if ch == "(" and (i + 1 == n or source[i + 1].isspace()):
            i += 1
            while i < n and source[i] != ")":
                i += 1
            if i < n:
                i += 1
            continue
        if source.startswith('S"', i) or source.startswith('s"', i):
            i += 2
            if i < n and source[i] == " ":
                i += 1
            start = i
            while i < n and source[i] != '"':
                i += 1
            if i >= n:
                raise ForthError("syntax", "unterminated S\" string")
            tokens.append(Token("string", source[start:i], len(tokens)))
            i += 1
            continue
        start = i
        while i < n and not source[i].isspace():
            i += 1
        raw = source[start:i]
        if _is_number(raw):
            tokens.append(Token("number", int(raw, 10), len(tokens)))
        else:
            tokens.append(Token("word", raw, len(tokens)))
    return tokens


def _is_number(raw: str) -> bool:
    if raw in {"+", "-"}:
        return False
    if raw.startswith("-"):
        return raw[1:].isdigit()
    return raw.isdigit()


@dataclass
class ForthVM:
    host: CapabilityHost
    artifacts: dict[str, str] = field(default_factory=dict)
    stack: list[Any] = field(default_factory=list)
    words: dict[str, Callable[[], None]] = field(default_factory=dict)
    colon: dict[str, list[Token]] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.words = {
            "DUP": self._dup,
            "DROP": self._drop,
            "SWAP": self._swap,
            "OVER": self._over,
            "+": self._add,
            "-": self._sub,
            "*": self._mul,
            "READ-FILE": self._read_file,
            "LIST-DIR": self._list_dir,
            "SEARCH": self._search,
            "WRITE-FILE": self._write_file,
            "RUN-TESTS": self._run_tests,
            "RUN-GATES": self._run_gates,
            "RECEIPT": self._receipt,
            "USE-ARTIFACT": self._use_artifact,
        }

    def defined_names(self) -> list[str]:
        return sorted(self.colon)

    def interpret(self, source: str) -> None:
        self.run_tokens(tokenize(source))

    def run_tokens(self, tokens: list[Token]) -> None:
        i = 0
        while i < len(tokens):
            token = tokens[i]
            if token.kind == "string":
                self.stack.append(str(token.value))
                i += 1
                continue
            if token.kind == "number":
                self.stack.append(int(token.value))
                i += 1
                continue
            name = str(token.value)
            key = name.upper()
            if key == ":":
                i = self._compile_colon(tokens, i)
                continue
            if key == "IF":
                i = self._run_if(tokens, i)
                continue
            if key in {"ELSE", "THEN", ";"}:
                raise ForthError("syntax", f"{key} without matching opener")
            self._exec_word(key, name)
            i += 1

    def _exec_word(self, key: str, original: str) -> None:
        if key in self.colon:
            self.run_tokens(self.colon[key])
            return
        action = self.words.get(key)
        if action is None:
            raise ForthError("unknown", f"unknown word {original}")
        try:
            action()
        except CapabilityError as exc:
            raise ForthError(exc.code, exc.message) from exc

    def _compile_colon(self, tokens: list[Token], i: int) -> int:
        if i + 1 >= len(tokens) or tokens[i + 1].kind != "word":
            raise ForthError("syntax", "expected name after :")
        name = str(tokens[i + 1].value).upper()
        body: list[Token] = []
        j = i + 2
        while j < len(tokens):
            token = tokens[j]
            if token.kind == "word" and str(token.value).upper() == ";":
                self.colon[name] = body
                return j + 1
            if token.kind == "word" and str(token.value).upper() == ":":
                raise ForthError("syntax", "nested colon definitions are not supported")
            body.append(token)
            j += 1
        raise ForthError("syntax", f"unterminated definition of {name}")

    def _run_if(self, tokens: list[Token], i: int) -> int:
        flag = self._truthy(self._pop("IF"))
        else_at, then_at = _match_if(tokens, i)
        if flag:
            end = else_at if else_at is not None else then_at
            self.run_tokens(tokens[i + 1 : end])
        elif else_at is not None:
            self.run_tokens(tokens[else_at + 1 : then_at])
        return then_at + 1

    def _dup(self) -> None:
        value = self._peek("DUP")
        self.stack.append(value)

    def _drop(self) -> None:
        self._pop("DROP")

    def _swap(self) -> None:
        b = self._pop("SWAP")
        a = self._pop("SWAP")
        self.stack.extend([b, a])

    def _over(self) -> None:
        if len(self.stack) < 2:
            raise ForthError("underflow", "stack underflow at OVER")
        self.stack.append(self.stack[-2])

    def _add(self) -> None:
        b = self._pop_int("+")
        a = self._pop_int("+")
        self.stack.append(a + b)

    def _sub(self) -> None:
        b = self._pop_int("-")
        a = self._pop_int("-")
        self.stack.append(a - b)

    def _mul(self) -> None:
        b = self._pop_int("*")
        a = self._pop_int("*")
        self.stack.append(a * b)

    def _read_file(self) -> None:
        path = self._pop_str("READ-FILE")
        self.stack.append(self.host.read_file(path))

    def _list_dir(self) -> None:
        path = self._pop_str("LIST-DIR")
        self.stack.append(self.host.list_dir(path))

    def _search(self) -> None:
        query = self._pop_str("SEARCH")
        self.stack.append(self.host.search(query))

    def _write_file(self) -> None:
        path = self._pop_str("WRITE-FILE")
        content = self._pop_str("WRITE-FILE")
        self.stack.append(self.host.write_file(content, path))

    def _run_tests(self) -> None:
        self.stack.append(self.host.run_tests())

    def _run_gates(self) -> None:
        self.stack.append(self.host.run_gates())

    def _receipt(self) -> None:
        self.stack.append(self.host.receipt())

    def _use_artifact(self) -> None:
        path = self._pop_str("USE-ARTIFACT")
        if path not in self.artifacts:
            raise ForthError("missing_artifact", f"no artifact: {path}")
        self.stack.append(self.artifacts[path])

    def _pop(self, word: str) -> Any:
        if not self.stack:
            raise ForthError("underflow", f"stack underflow at {word}")
        return self.stack.pop()

    def _peek(self, word: str) -> Any:
        if not self.stack:
            raise ForthError("underflow", f"stack underflow at {word}")
        return self.stack[-1]

    def _pop_str(self, word: str) -> str:
        value = self._pop(word)
        if not isinstance(value, str):
            raise ForthError("type", f"{word} expected string, got {type(value).__name__}")
        return value

    def _pop_int(self, word: str) -> int:
        value = self._pop(word)
        if isinstance(value, bool) or not isinstance(value, int):
            raise ForthError("type", f"{word} expected integer, got {type(value).__name__}")
        return value

    def _truthy(self, value: Any) -> bool:
        if value is None or value is False:
            return False
        if value == 0:
            return False
        return True


def _match_if(tokens: list[Token], start: int) -> tuple[int | None, int]:
    depth = 0
    else_at: int | None = None
    for i in range(start, len(tokens)):
        token = tokens[i]
        if token.kind != "word":
            continue
        word = str(token.value).upper()
        if word == "IF":
            depth += 1
        elif word == "ELSE" and depth == 1:
            else_at = i
        elif word == "THEN":
            if depth == 1:
                return else_at, i
            depth -= 1
    raise ForthError("syntax", "IF without THEN")
