"""Keccak-256 (the EVM's hash), in pure Python, and refusing to run unvalidated.

Why this file exists
--------------------
`DrawProperties.t.sol` checks §4.5's draw against the closed form `f(â)`. That is
a real check and shares no code with the contract, but it does not cross-check the
**ticket derivation** — the keccak-domain-separated `u[i]` — which is the
highest-consequence expression in the system. A second implementation needs
keccak, and this environment has no `pycryptodome`, `pysha3` or `eth_hash`.

Hand-rolling a hash is exactly the kind of thing that produces a differential
which *looks* like two-implementation agreement and is not: a wrong keccak here
and a wrong keccak in a test fixture agree with each other perfectly. Known-answer
tests are what retire that risk, so this module validates itself at import and
raises rather than returning numbers if it cannot.

How it is validated, twice and independently
--------------------------------------------
1. **The permutation and the sponge, against a trusted reference.** NIST SHA3-256
   and Keccak-256 differ in exactly one byte: the domain-separation pad (`0x06`
   vs `0x01`). Everything else — the 24-round Keccak-f[1600] permutation, the
   rate/capacity split, absorbing, squeezing — is shared. `hashlib.sha3_256` is
   in the standard library and is a trusted implementation, so running THIS
   sponge in SHA-3 mode against it over many inputs of many lengths validates
   every part except the pad byte, including multi-block absorption.

2. **The pad byte and the whole of Keccak-256, against published KATs.** Three
   published Keccak-256 vectors, including the empty string — whose digest
   `c5d2...a470` is the most widely replicated constant in Ethereum.

Together these pin the entire function. Neither alone would: (1) never exercises
the Keccak pad, and (2) is three short inputs.
"""

from __future__ import annotations

import hashlib

__all__ = ["keccak256", "KeccakValidationError"]


class KeccakValidationError(Exception):
    """Raised at import if self-validation fails. The module then refuses to run."""


# --- Keccak-f[1600] ---------------------------------------------------------

_ROUND_CONSTANTS = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

_ROTATION_OFFSETS = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]

_MASK64 = (1 << 64) - 1


def _rotl64(value: int, shift: int) -> int:
    shift %= 64
    return ((value << shift) | (value >> (64 - shift))) & _MASK64


def _keccak_f1600(state: list[list[int]]) -> None:
    """The permutation, in place. `state[x][y]`, lanes of 64 bits."""
    for round_constant in _ROUND_CONSTANTS:
        # theta
        c = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rotl64(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x][y] ^= d[x]

        # rho and pi
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rotl64(state[x][y], _ROTATION_OFFSETS[x][y])

        # chi
        for x in range(5):
            for y in range(5):
                state[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y] & _MASK64) & b[(x + 2) % 5][y])

        # iota
        state[0][0] ^= round_constant


def _sponge(data: bytes, rate_bytes: int, pad_byte: int, output_bytes: int) -> bytes:
    """Absorb `data`, squeeze `output_bytes`. `pad_byte` selects Keccak vs SHA-3."""
    state = [[0] * 5 for _ in range(5)]

    # Pad10*1 with the domain-separation byte folded into the first pad byte.
    padded = bytearray(data)
    padded.append(pad_byte)
    while len(padded) % rate_bytes != 0:
        padded.append(0x00)
    padded[-1] ^= 0x80

    for offset in range(0, len(padded), rate_bytes):
        block = padded[offset : offset + rate_bytes]
        for i in range(rate_bytes // 8):
            lane = int.from_bytes(block[i * 8 : i * 8 + 8], "little")
            state[i % 5][i // 5] ^= lane
        _keccak_f1600(state)

    out = bytearray()
    while len(out) < output_bytes:
        for i in range(rate_bytes // 8):
            if len(out) >= output_bytes:
                break
            out += state[i % 5][i // 5].to_bytes(8, "little")
        if len(out) < output_bytes:
            _keccak_f1600(state)
    return bytes(out[:output_bytes])


def keccak256(data: bytes) -> bytes:
    """Keccak-256 as the EVM computes it. 32 bytes."""
    return _sponge(data, rate_bytes=136, pad_byte=0x01, output_bytes=32)


def _sha3_256_via_this_sponge(data: bytes) -> bytes:
    """NIST SHA3-256 through the SAME code, differing only in the pad byte."""
    return _sponge(data, rate_bytes=136, pad_byte=0x06, output_bytes=32)


# --- self-validation, at import ---------------------------------------------

# Published Keccak-256 known-answer tests.
_KECCAK256_KATS = [
    (b"", "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"),
    (b"abc", "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"),
    (
        b"The quick brown fox jumps over the lazy dog",
        "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15",
    ),
]


def _validate() -> None:
    for message, expected in _KECCAK256_KATS:
        got = keccak256(message).hex()
        if got != expected:
            raise KeccakValidationError(
                f"Keccak-256 KAT failed for {message!r}: expected {expected}, got {got}. "
                "This module will not produce numbers from an unvalidated hash."
            )

    # The permutation and sponge, against the standard library, across lengths
    # that span the 136-byte rate boundary in both directions.
    lengths = [0, 1, 55, 135, 136, 137, 200, 271, 272, 273, 1000]
    for length in lengths:
        # A deterministic, non-degenerate message.
        message = bytes((i * 37 + length) % 256 for i in range(length))
        mine = _sha3_256_via_this_sponge(message).hex()
        reference = hashlib.sha3_256(message).hexdigest()
        if mine != reference:
            raise KeccakValidationError(
                f"sponge disagrees with hashlib.sha3_256 at length {length}: "
                f"{mine} != {reference}. The permutation is wrong, so Keccak-256 "
                "from the same code cannot be trusted either."
            )


_validate()
