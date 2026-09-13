"""§3's eligibility, derived independently of the contract.

`Integration.t.sol` checks that eligibility *narrows* — that at 64 staked
moderators fewer than 64 are eligible, and roughly half. That is a real check and
it is not enough, for the same reason the rate check on the draw was not enough:
it constrains the COUNT and says nothing about WHICH identities.

A mutation campaign made the gap concrete. Inverting the predicate —
`h >> (256 - eligBits) == 0` to `!= 0` — survived the entire suite. It has to: the
complement of a half-sized set is also half-sized, and every test commits
*whoever is eligible* rather than a set it decided in advance. The same is true of
changing the committee number mixed into the hash, and of the `_eligBits` loop
bounds, which move the threshold by a whole bit.

So this module derives the predicate from the same inputs the contract uses, in
Python, so the two can be compared identity by identity.

The expression, from `Moderation._eligible`:

    h = uint256(keccak256(abi.encode(
        ELIGIBILITY_DOMAIN, block.chainid, address(this), caseId, committee, seed, m
    )))

    eligible  <=>  h >> (256 - eligBits) == 0        for eligBits > 0
    eligible  <=>  true                              for eligBits == 0

`abi.encode` of these seven static types is their concatenation: `committee` is a
`uint8` and occupies a full left-padded word, and both addresses are left-padded
to 32 bytes. Nothing here is dynamic, so there is no head/tail split.

**Why the committee number matters enough to derive separately.** It is the only
thing separating committee A's eligible set from committee B's on a round where
both seeds happen to coincide, and it is what makes the staging meaningful: B is
a genuinely different draw rather than the same one under a new name. A wrong
committee number produces a set of the right size, uniformly distributed, passing
every count check — and quietly makes the two committees correlated.

And `_eligBits` is derived here too, not read from the contract, because the
threshold is the other half of the predicate: at one bit too few the committee
doubles, at one too many it halves, and §3's "32 to 64 by construction" is exactly
the claim those loop bounds make.
"""

from __future__ import annotations

from keccak import keccak256

__all__ = ["ELIGIBILITY_DOMAIN", "elig_bits", "elig_hash", "eligible", "committee_of_phase"]

#: `keccak256("eligibility")`, the constant `Moderation` uses.
ELIGIBILITY_DOMAIN = keccak256(b"eligibility")

#: `Phase` as `Moderation` declares it. Only the two commit phases have a
#: committee; everything else answers 0, and `isEligible` returns false there.
PHASE_COMMIT_A = 1
PHASE_COMMIT_B = 2


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


def elig_bits(staked_count: int) -> int:
    """`N − 5` from the staked count, as §3 defines it.

    Derived from the definition rather than transcribed from the loop in
    `Moderation._eligBits`: `N` is the position of the highest set bit, i.e. the
    unique `N` with `2^N <= staked < 2^(N+1)`, and the threshold is `max(N-5, 0)`.

    `staked <= 1` gives `N = 0`. A registry of 32 or fewer needs no narrowing at
    all, and the contract's shift is only defined for 1..255, which is why zero is
    a real case and not an edge to be tidied away.
    """
    if staked_count < 0:
        raise ValueError(f"negative registry: {staked_count}")
    n = max(staked_count, 1).bit_length() - 1
    return max(n - 5, 0)


def committee_of_phase(phase: int) -> int:
    """`Moderation._committeeOf` — 1 in COMMIT_A, 2 in COMMIT_B, 0 elsewhere."""
    if phase == PHASE_COMMIT_A:
        return 1
    if phase == PHASE_COMMIT_B:
        return 2
    return 0


def elig_hash(
    chain_id: int,
    contract: str | int,
    case_id: int,
    committee: int,
    seed: bytes,
    moderator: str | int,
) -> int:
    """The full 256-bit narrowing hash, before the shift."""
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    if not 0 <= committee < 256:
        raise ValueError(f"not a uint8: {committee}")
    preimage = (
        ELIGIBILITY_DOMAIN
        + _word(chain_id)
        + _address_word(contract)
        + _word(case_id)
        + _word(committee)
        + seed
        + _address_word(moderator)
    )
    return int.from_bytes(keccak256(preimage), "big")


def eligible(
    chain_id: int,
    contract: str | int,
    case_id: int,
    committee: int,
    seed: bytes,
    moderator: str | int,
    bits: int,
) -> bool:
    """§3's predicate: at least `bits` leading zeros in the narrowing hash."""
    if bits == 0:
        return True
    if not 1 <= bits <= 255:
        raise ValueError(f"shift undefined for bits={bits}")
    h = elig_hash(chain_id, contract, case_id, committee, seed, moderator)
    return (h >> (256 - bits)) == 0
