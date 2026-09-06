# M2.7 Remediation — four rulings on the questions §4 could not answer

**Base:** `main` @ `6489bfd`.
**Branch:** **`claude/determined-curie-nkf71s`** — same branch, continue on it.
**Predecessor:** `5280196` (`Moderation.sol`, 17,721 B, 118 tests, 41/45 mutations
killed with four equivalent mutants).

Your delivery was verified independently before these rulings were written: 118
tests re-run green, `forge build --sizes` confirms 17,721 B, `StakeRegistry`
untouched at 9,058 B, and the I26 fix checked for over-reach — it does not
over-reserve `APPROVED`, because the `tallied` guard sits inside `_toUnresolved`
while line 702 assigns `APPROVED → LISTED` per §8.4.

**Three of the four rulings confirm what you built. One reverses it.** Only §1
below is a code change.

---

## 1. `DRAW_BOUNTY` — reversed. Refund it on the two pre-`TALLY` terminals

**Your objection was right and your implementation was wrong**, which is the
outcome your report asked for.

§4.8's value-flow block now states the rule that decides it:

> A bounty is refunded where the transition it pays for cannot occur, and paid
> where that transition was performed.

| terminal | `DRAW_BOUNTY` |
|---|---|
| `NO_TURNOUT` | **refund** — `DRAW` unreachable |
| `NO_REVEALS` | **refund** — `DRAW` unreachable |
| `NO_RANDOMNESS` | **paid**, to whoever poked the expiry (§4.3 already says so) |
| `APPROVED` / `REJECTED` | paid |

Retaining it charges the submitter for a transition that cannot happen, on a row
§4.8 calls unsteerable and refunds in full — the same shape §4.8 rejects for the
non-reveal debit.

**Do not touch `CLAIM_BOUNTY`.** You will notice the same argument applies to it —
those transitions are permissionless too and somebody poked them. That is now §10's
open question, deliberately not decided here: the two above were contradictions,
`CLAIM_BOUNTY` is a fee-schedule change, and they should not ride together. Leave
it retained.

Value conservation is the test to extend, not a new one — `test_valueConservation_*`
already exists and should now assert the bounty's destination per terminal.

## 2. `NO_REVEALS` pot — confirmed. §8.4 wins, and §4.8 has been corrected

You implemented §8.4 and that was right. §4.8's block said *"refund pot +
challengeReserve IN FULL"* on every reason; §8.4 retries `NO_REVEALS` with the pot
carried forward and no fresh fee. A refunded pot cannot be carried.

They are **not** equivalent, which is why it was a contradiction and not a wording
choice: §4.8 also retains `finalizationBounty` and maintenance, so
refund-and-resubmit costs the submitter those two every cycle while carrying costs
nothing — and under §4.8c that hands a censor a way to levy his victim on each
attempt. `6489bfd` corrects §4.8. **No code change.**

## 3. `reopen` requiring settled prior voters — confirmed

Your reading is adopted. §8.5 asserted a fact that §5.5 makes untrue, and turning
the assertion into a precondition is the right resolution. There is no griefing
vector because `claim` is permissionless: anyone can clear a straggler.

§8.5 will be amended to state the precondition rather than assume it. **No code
change** — your implementation already does the right thing.

## 4. Two maintenance pools — confirmed as a real gap, and not yours to close

Checked: the registry's `maintenanceReserve` grows only through `debit`, has **no
deposit path** for a logic contract, and **has no exit in either contract**. Two
sinks, no withdrawal, no stated purpose.

The target is one pool with a timelocked governance exit. That requires changing
`StakeRegistry`, which is frozen, so it goes in a separate order against both
contracts. **Do not attempt it here, and do not add a forwarding path.** You were
right to flag rather than invent.

---

## Also adopted from your report

- **§3.3's widening boundary is an I31 unit-span** — a wall-clock `LATE_WIDEN_AT`
  compared against a block height. Your fix (scale from `commitBlocks` rather than
  add a fourth converted field or a second conversion) is adopted and §3.3 will say
  so. No code change.
- **A re-opened case has no `DRAW` waiting window**, which §3.5b's uniform-latency
  argument does not cover. Recorded. No code change pending the amendment.

## On the mutation campaign

Killing the first run rather than banking M5 — which only the gas suite killed —
was the correct call and the opposite of tuning the set. Analysing eight survivors
into four gaps and four equivalent mutants is what makes `41/45` mean something;
a bare count would not have.

**M7 is worth stating as a result rather than a survivor.** Adding the `N > 0`
guard to `draw` is unkillable *because §4.5 is right* — `DRAW` is unreachable with
an empty tally, so the guard can never fire. That is independent confirmation of the
`bac361c` correction, and
`test_s4_5_drawIsUnreachableWithAnEmptyTally` is the right way to pin a claim no
mutation can reach.

---

## Deliverable

One commit on `claude/determined-curie-nkf71s`:

- `DRAW_BOUNTY` refunded on `NO_TURNOUT` and `NO_REVEALS`
- `test_valueConservation_*` extended to assert the bounty's destination per terminal
- `DEVIATIONS.md` — D3 entries for questions 1–4 updated to record the ruling and
  which way it went; the entry for `DRAW_BOUNTY` should say it was reversed
- re-run the mutation campaign **only if** the change touches a mutated line; say
  so either way rather than silently reusing `41/45`

Report size and test count after the change. If the refund path pushes anything
unexpected, say so — 6,855 B of margin should absorb it.
