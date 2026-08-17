"""BIP340 x-only Schnorr verify (secp256k1). No third-party crypto."""

from __future__ import annotations

import base64
import hashlib

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
G = (GX, GY)


def tagged_hash(tag: str, data: bytes) -> bytes:
    digest = hashlib.sha256(tag.encode("utf-8")).digest()
    return hashlib.sha256(digest + digest + data).digest()


def _modinv(value: int, mod: int) -> int:
    return pow(value, -1, mod)


def _lift_x(x: int) -> tuple[int, int] | None:
    if x >= P:
        return None
    y2 = (pow(x, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if (y * y) % P != y2:
        return None
    if y & 1:
        y = P - y
    return (x, y)


def _point_add(
    left: tuple[int, int] | None, right: tuple[int, int] | None
) -> tuple[int, int] | None:
    if left is None:
        return right
    if right is None:
        return left
    x1, y1 = left
    x2, y2 = right
    if x1 == x2:
        if (y1 + y2) % P == 0:
            return None
        slope = (3 * x1 * x1 * _modinv(2 * y1 % P, P)) % P
    else:
        slope = ((y2 - y1) * _modinv((x2 - x1) % P, P)) % P
    x3 = (slope * slope - x1 - x2) % P
    y3 = (slope * (x1 - x3) - y1) % P
    return (x3, y3)


def _point_mul(scalar: int, point: tuple[int, int] | None) -> tuple[int, int] | None:
    if point is None or scalar % N == 0:
        return None
    scalar = scalar % N
    acc: tuple[int, int] | None = None
    cur = point
    while scalar:
        if scalar & 1:
            acc = _point_add(acc, cur)
        cur = _point_add(cur, cur)
        scalar >>= 1
    return acc


def _decode_bytes(value: str | bytes) -> bytes:
    if isinstance(value, bytes):
        return value
    text = value.strip()
    if text.startswith("0x") or text.startswith("0X"):
        text = text[2:]
    try:
        return bytes.fromhex(text)
    except ValueError:
        pass
    pad = (-len(text)) % 4
    return base64.b64decode(text + ("=" * pad))


def verify(pubkey: str | bytes, message: bytes, signature: str | bytes) -> bool:
    try:
        pk = _decode_bytes(pubkey)
        sig = _decode_bytes(signature)
    except (ValueError, TypeError):
        return False
    if len(pk) == 33 and pk[0] in (2, 3):
        pk = pk[1:]
    if len(pk) != 32 or len(sig) != 64 or len(message) != 32:
        return False
    p_point = _lift_x(int.from_bytes(pk, "big"))
    if p_point is None:
        return False
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(tagged_hash("BIP0340/challenge", sig[:32] + pk + message), "big") % N
    r_point = _point_add(_point_mul(s, G), _point_mul((N - e) % N, p_point))
    if r_point is None or (r_point[1] % 2) != 0 or r_point[0] != r:
        return False
    return True
