"""§4.5's draw, derived independently of the contract.

`DrawProperties.t.sol` checks the draw against the closed form `f(â) = 3â² − 2â³`.
That shares no code with `Moderation` and is a real check, but it only constrains
the RATE. It says nothing about the ticket derivation itself — the
domain-separated `u[i]` — which decides individual cases and is where a domain
-separation mistake would hide: a wrong domain still produces uniform `u`, still
produces `f(â)` in aggregate, and still passes every statistical test, while
making two different cases share a draw.

This module derives `u[0..2]` from the same inputs the contract uses, in Python,
so the two can be compared vector by vector.

The expression, from `Moderation._decide`:

    u_i = uint128(uint256(keccak256(abi.encode(
        OUTCOME_DOMAIN, block.chainid, address(this), caseId, i, entropy
    ))))

    ticket_i  <=>  u_i * (A + R + 2)  <  (A + 1) << 128
    verdict   =    APPROVE if tickets >= 2 else REJECT

`abi.encode` of six static 32-byte types is their concatenation, with the address
left-padded — there is no head/tail split because none of them is dynamic.
"""

from __future__ import annotations

from .keccak import keccak256

__all__ = ["OUTCOME_DOMAIN", "ticket_u", "decide", "APPROVE", "REJECT"]

APPROVE = 1
REJECT = 2

#: `keccak256("v3.outcome")`, the constant `Moderation` uses.
OUTCOME_DOMAIN = keccak256(b"v3.outcome")


def _word(value: int) -> bytes:
    """One 32-byte ABI word. Rejects out-of-range rather than truncating."""
    if not 0 <= value < (1 << 256):
        raise ValueError(f"not a uint256: {value}")
    return value.to_bytes(32, "big")


def _address_word(address: str | int) -> bytes:
    """An address, left-padded to 32 bytes as `abi.encode` pads it."""
    if isinstance(address, str):
        address = int(address, 16)
    if not 0 <= address < (1 << 160):
        raise ValueError(f"not an address: {address:#x}")
    return _word(address)


def ticket_u(chain_id: int, contract: str | int, case_id: int, index: int, entropy: bytes) -> int:
    """`u_i` — the low 128 bits of the domain-separated hash."""
    if len(entropy) != 32:
        raise ValueError("entropy must be 32 bytes")
    preimage = (
        OUTCOME_DOMAIN
        + _word(chain_id)
        + _address_word(contract)
        + _word(case_id)
        + _word(index)
        + entropy
    )
    digest = int.from_bytes(keccak256(preimage), "big")
    return digest & ((1 << 128) - 1)  # the uint128 cast


def decide(
    chain_id: int,
    contract: str | int,
    case_id: int,
    entropy: bytes,
    pooled_approve: int,
    pooled_reject: int,
) -> tuple[list[int], int, int]:
    """Returns `(u[0..2], tickets, verdict)`.

    The comparison is CROSS-MULTIPLIED, not `u mod (N+2)`. Both are uniform and
    both give `f(â)`; only this form is monotone in `â`, and monotonicity is the
    entire reason a challenge cannot buy a re-roll (I22). Reproducing the wrong
    form here would produce a differential that agrees on rates and disagrees on
    exactly the cases the property is about.
    """
    den = pooled_approve + pooled_reject + 2  # N + 2, >= 2 always
    num = pooled_approve + 1  # A + 1

    us = [ticket_u(chain_id, contract, case_id, i, entropy) for i in range(3)]
    tickets = sum(1 for u in us if u * den < num << 128)
    verdict = APPROVE if tickets >= 2 else REJECT
    return us, tickets, verdict
