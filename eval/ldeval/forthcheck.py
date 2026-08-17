from __future__ import annotations

import shlex
from dataclasses import dataclass


@dataclass(frozen=True)
class Contract:
    inputs: int
    outputs: int
    effects: frozenset[str]


DEFAULT_DICTIONARY = {
    "TASK": Contract(0, 1, frozenset({"read"})),
    "OBSERVE": Contract(1, 1, frozenset({"read"})),
    "PROPOSE-PATCH": Contract(1, 1, frozenset({"model"})),
    "CHECK-PATCH": Contract(1, 1, frozenset({"read"})),
    "APPLY-PATCH": Contract(1, 1, frozenset({"write"})),
    "RUN-TESTS": Contract(1, 1, frozenset({"exec"})),
    "REQUIRE-PASS": Contract(1, 1, frozenset()),
    "RECEIPT": Contract(1, 1, frozenset()),
    "DUP": Contract(1, 2, frozenset()),
    "DROP": Contract(1, 0, frozenset()),
    "SWAP": Contract(2, 2, frozenset()),
}


def validate_straight_line(
    program: str,
    allowed_effects: set[str],
    dictionary: dict[str, Contract] | None = None,
) -> dict:
    words = dictionary or DEFAULT_DICTIONARY
    depth = 0
    effects: set[str] = set()
    errors: list[str] = []
    for index, token in enumerate(shlex.split(program)):
        contract = words.get(token)
        if contract is None:
            errors.append(f"token {index}: unknown word {token}")
            continue
        if depth < contract.inputs:
            errors.append(f"token {index}: stack underflow at {token}")
            depth = 0
        else:
            depth -= contract.inputs
        depth += contract.outputs
        effects.update(contract.effects)
    excess = effects - allowed_effects
    if excess:
        errors.append(f"effects not allowed: {', '.join(sorted(excess))}")
    return {"valid": not errors, "errors": errors, "final_depth": depth, "effects": sorted(effects)}

