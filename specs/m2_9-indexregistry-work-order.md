# M2.9 Work Order — `IndexRegistry.sol`

**Base:** `main` @ `6fe369c`.
**Branch:** **`claude/determined-curie-nkf71s`** — same branch, continue on it.
**Normative:** `specs/state-machine-v3.md` §8 @ `6fe369c`.

**Scope:** `contracts/src/v3/IndexRegistry.sol` and its tests, plus the minimum
change to `Moderation.sol` to drive it. Third of the four contracts.

---

## 0. Why this is not cosmetic

`Moderation` currently writes to `IIndexRegistry`, a four-argument stub you
declared inline and recorded as D3-1. Two consequences:

- **`GAS_BUDGETS.md` understates the system.** You flagged this yourself: the
  figures are floors, because a real index write is a cold `SSTORE` per topic on
  top of every `+index` row, and **every terminal transition carries one**. At
  `MAX_TOPICS = 5` that is roughly 100k more per terminal than the stub measures.
- **§8's semantics have never been implemented against.** §8.1's
  finality-independent write, §8.2's interim status, §8.2b's content-derived
  identifiers — all asserted, none exercised.

## 1. Read these first — §8 moved at `6fe369c`

The §8 re-read found three gaps and closed them. Each changes what you would
otherwise build.

**§8.2 — the status enum gained `REMOVED`.**

```
NONE = 0 | PLURALITY_APPROVE | PLURALITY_REJECT | APPROVED | REJECTED
         | UNRESOLVED | REMOVED
```

`RETAINED` is deliberately **not** a status — it is a removal case's terminal, and
a failed removal leaves the `LIST` entry untouched.

**§8.1 — there is a fifth write, and it is the only one that reaches outside its
own claim key.** A successful removal sets the *original* `LIST` entry to
`REMOVED` and drops it from the topic's enumerable listing. Both keys are
content-derived, so the second is computable from the removal case's own fields —
do not add a stored pointer.

**§8.3 — `SUPER_SAFE` is a query, not a status**, and it splits:

```
entry.strict         one immutable bit, all six tally conjuncts, fixed at the write
entry.openQuestions  live counter, ++ when a re-review or removal OPENS,
                     -- at its terminal

SUPER_SAFE(entry) = entry.strict AND entry.openQuestions == 0
```

**A counter, never a boolean** — two concurrent re-reviews closing one at a time
would clear a boolean while a question was still open (I29).

## 2. The identifier rules — §8.2b, and v1 paid a CRITICAL for them

```
entryKey  = H(claimKey, topicKey)
topicKey  = H(canonical topic string)
```

> **Every identifier this index exposes is a function of content. None is a
> function of insertion order, of a counter, or of any state a particular logic
> contract owns.**

A replacement contract must re-derive the same identifier from the same content.
P0-1a in v1 was a logic-local identifier colliding across a migration; §8.4 applied
the lesson to claims and not to entries, and entries are the thing a migration has
to keep addressing.

**Two zero-value traps, both I29, and the second is `M2.6-F1` verbatim — this
codebase has fixed it once already:**

- `topicKey == 0` is **illegal**. A claim carries up to `MAX_TOPICS = 5` topics in
  a fixed-width slot and unused slots read 0, so a legal zero topic would make "no
  topic here" and "the topic whose key is 0" the same read.
- **A position map must not store 0 for a present entry.** Returning 0 for
  "absent" cannot distinguish absent from *first in the list*. Store `index + 1`,
  or keep a separate presence bit — say which you chose and why.

## 3. Surface

Sized from §8, not invented. Names are yours; the semantics are not.

| purpose | shape |
|---|---|
| write/update an entry | `(claimKey, topicKey, status, plurality, strict)` |
| the fifth write (§8.1) | set an entry to `REMOVED` and delist it |
| open/close a question | `openQuestions` ++ / -- |
| read one entry | status, plurality, `SUPER_SAFE` |
| enumerate a topic's listed content | paged; see §4 |

**Only `Moderation` may write.** Follow `StakeRegistry`'s capability pattern —
governance grants a logic write access behind the existing timelock idiom
(`propose`/`cancel`/`execute`). Do not invent a third idiom, and do not use
`msg.sender == owner`.

## 4. Enumeration is the part most likely to go wrong

§8.1 requires the write to be **bounded** `O(MAX_TOPICS)`, and `MAX_TOPICS` is 5,
so the write side is fine. The **read** side is where an index dies: a topic can
accumulate unboundedly many entries, and any function that walks a whole topic is
a contract that stops working at a size you cannot predict.

- Enumeration **must be paged** — offset/limit or a cursor — and no function may
  iterate an unbounded list.
- Delisting is swap-and-pop against the position map, `O(1)`.
- **Test enumeration at a size that would break an unpaged design** — several
  thousand entries in one topic — and report the gas curve, not just that it
  passes.

## 5. `Moderation` — the minimum change

Replace the inline `IIndexRegistry` stub with the real interface, and add the
`openQuestions` increment/decrement at the two points §8.3 names. Nothing else.

**Do not re-open §4.** If a §8 rule appears to contradict §4, report it — that is
the seventh time this instruction has earned its place and it has produced a
finding every time.

## 6. Not in scope

- **§8.3's 3/3 conjunct.** §10 has it open: it is arbitrary rather than meaningful
  and §8.3 argues against it in its own headline, but dropping it changes what a
  published assurance label promises. Implement `strict` **with** the conjunct as
  §8.3 currently states it, and leave the decision to me.
- **`SUPER_QUORUM`**, and every other open parameter. Constructor or governance
  argument, no default. Test values are fixtures and must say so.
- `CLAIM_BOUNTY` on `UNRESOLVED`, and the `execute*()` argument idiom (§10). Both
  recorded, both deliberately not riding along.

## 7. Acceptance

The bar you set, unchanged:

1. `forge test` green across all four v3 suites; say the count.
2. **§8.2's `NONE = 0` tested directly** — an unwritten entry and a live
   `PLURALITY_APPROVE` must not read alike. This is the defect §8.2 exists to
   prevent and it is one assertion.
3. **Both zero-value traps of §2 tested**, including a first-in-list entry.
4. **The fifth write tested end to end**: list content, remove it, assert the
   original entry reads `REMOVED` and has left the topic's listing, and that a
   *failed* removal leaves it `APPROVED` and listed.
5. **`SUPER_SAFE` revocation tested**: an entry that is `strict` reads
   `SUPER_SAFE`, stops while a question is open, and resumes when it closes —
   with **two** concurrent questions, which is the case a boolean would fail.
6. Migration property: an entry written by one logic is addressable, at the same
   key, by a second logic given the same content.
7. Mutation campaign, survivors analysed as before.
8. EIP-170 for `IndexRegistry`, and **re-report `Moderation`** — the real
   interface will move it from 18,165 B.
9. **`GAS_BUDGETS.md` re-measured against the real index, and say plainly that the
   previous figures were floors.** This is the number the project has not had.

## 8. Deliverable

One commit on **`claude/determined-curie-nkf71s`**, and in the report: test count,
mutation results, both sizes, the enumeration gas curve, the corrected gas
budgets, and everything §8 could not answer.
