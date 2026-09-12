# Staged committees — E24–E32

**Conclusion: staging is neutral on capture, and it buys tally-hiding.**

The proposal is to select committee 2 only after committee 1 has committed, so
neither can see the other. The question was whether that defends against an
attacker who exploits a favourable first committee.

It does not, because there is nothing there to defend against. **It does buy
something else, and that something else is worth having.**

This file previously reported the opposite. §E records what was wrong and why,
because the error is more instructive than the result.

---

## §A Staging makes no difference to capture

Exact enumeration (`exact.py`), attacker committing every eligible identity,
tallies pooled, one draw. Equal review effort — one committee of `2n` against two
staged committees of `n`:

| q | one committee of 2n | two staged of n | difference |
|---:|---:|---:|---:|
| 10% | 0.394536 | 0.394542 | +0.000006 |
| 20% | 0.491564 | 0.491550 | −0.000014 |
| 30% | 0.585065 | 0.585028 | −0.000042 |
| 40% | 0.672572 | 0.672514 | −0.000065 |

Identical to five decimal places. The residual is consistent with the small
variance difference between one binomial draw at `2n/N` and two at `n/N`; it is
not a meaningful effect in either direction.

**Why, stated the way the reviewer stated it:** the tickets are drawn from the
*combined* tally of both committees. Capturing either one alone therefore buys
nothing — the other committee's honest votes are in the same pool regardless.

## §B What staging does buy

A committee that can see the running tally of an earlier committee has an
incentive to follow it, because payment is for coherence with the final verdict
rather than for being right. Staging removes the tally from view.

E26, re-run with the attacker committing everywhere:

| P(honest voter follows a visible lead) | tally visible | tally hidden | cost |
|---:|---:|---:|---:|
| 0% | 59.16% | 58.88% | +0.28pp |
| 15% | 61.44% | 58.88% | +2.56pp |
| 35% | 64.28% | 58.88% | +5.40pp |
| 50% | 65.55% | 58.88% | +6.67pp |
| 75% | 69.43% | 58.88% | +10.55pp |

**Between 0 and 10.6 points**, entirely driven by how much honest voters
actually conform. At zero conformity there is no effect — which corrects an
earlier claim here that a visible tally was worth 10 points even with nobody
swayed. That claim was an artefact of the error in §E.

So the value of staging is real but conditional: it is worth exactly as much as
conformity costs, and conformity has not been measured.

## §C The theorem that does not apply

It is true that splitting a committee raises the chance the attacker finds a
favourable one. Let `P_m` be the probability that a committee of expected size
`m` has attacker share at least `θ`. For `θ > q` the share concentrates on `q`,
so `P_m` decreases in `m`, and two independent draws give

    P_2n  <  P_n  <  2P_n − P_n²  =  1 − (1 − P_n)²

Exact values confirm it across sixteen cells — at `q = 30%`, `θ = 50%`, `n = 20`:
0.005343 for one committee of 40 against 0.082338 for either of two 20s.

**And it decides nothing.** "Finding a favourable committee" is not a step on the
path to an outcome when the tallies are pooled: the attacker's share of the
*combined* pool is what feeds the draw, and that share does not improve because
one half of it came out lopsided. The inequality is sound and it answers a
question the mechanism does not ask.

Recorded here because rigour aimed at the wrong quantity is harder to catch than
an arithmetic slip — it looks settled.

## §D What holds

1. **Staging costs nothing.** §A.
2. **Staging hides the tally, worth 0–10.6 points** depending on conformity. §B.
3. Therefore the staged design is **better than a single committee**, for the
   reason its author gave and not for the reason previously argued here.

## §E The error, and how it was made

Earlier revisions of this file reported staging as **11.6× worse**. That figure
came from a model in which the attacker *declines* to vote in a committee that
comes out unfavourable, and in which declining both was scored as "no attempt
made" and excluded from the denominator.

**Declining is a dominated strategy.** It removes the attacker's own votes and
leaves the honest ones in the pool:

- committee 1 has 10 attackers and 10 honest, committee 2 has 2 and 18
- vote everywhere: 12 of 40 = 30%
- vote only in committee 1: 10 of 38 = 26%

So the model handed the attacker a losing move, measured the damage it did to
them, and reported it as an advantage conferred by the architecture. The 11.6×
was a denominator artefact: there is no "abandon" — the fee is paid, the case
runs, and not voting is simply losing.

**The control in this file already said so.** E25 forced the attacker to commit
everywhere and returned 58.38% against 59.09% — no difference. That was written
up as "staging itself contributes nothing" and then the selective numbers were
used as the headline anyway.

**What would have caught it:** asking whether an attacker gains anything by not
voting. That is a question about the mechanism, answerable in one sentence, and
it was never asked. The engine was correct throughout; the model of the attacker
was invented rather than checked.

## §F Assumptions

1. Eligibility independent across identities.
2. Honest reading errors independent across moderators; correlated error raises
   every figure here.
3. Attacker holds a fixed share of the registry and votes its direction.
4. Conformity in §B is a free parameter. It has not been measured, and §B's
   range is only as meaningful as that number.
5. `staged.py` retains a `selective` flag that reproduces the dominated strategy
   of §E. It is kept so the error can be re-derived, and **should not be used
   for any reported figure.**
