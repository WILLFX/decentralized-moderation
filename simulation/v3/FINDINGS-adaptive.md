# Sequential stopping vs the fixed quorum — E9–E17

Produced by `run_adaptive.py` against `adaptive_stopping.py`. The v3 baseline is
`protocol_v3.run_case` called directly and unmodified, so the thing being
compared against cannot be mis-stated in the direction that flatters the
challenger.

**The hypothesis under test**, written before the run: `FINDINGS-v3.md` §E's
92.2% `UNRESOLVED(NO_TURNOUT)` at registry 250 is a property of the *gate*, not
of the *population*, and replacing the fixed quorum with Wald-style sequential
stopping converts a liveness **failure** into a latency **cost**.

**Result: confirmed, then substantially defeated by its own control, and one
failure mode appeared that the hypothesis did not anticipate and that is worse
than the problem it set out to solve.**

Read §3 before quoting §1.

---

## 1. The liveness claim is true (E9)

| registry | E[cohort] | v3 unresolved | adaptive | adaptive+widen |
|---:|---:|---:|---:|---:|
| 250 | 10 | **0.923** | 0.003 | 0.000 |
| 500 | 20 | 0.084 | 0.000 | 0.000 |
| 1,000 | 40 | 0.000 | 0.000 | 0.000 |
| 2,000 | 80 | 0.000 | 0.000 | 0.000 |

`MIN_COMMITS` is 16 against an expected cohort of 10. A gate set above the mean
of the thing it gates fails most of the time by construction, and nothing about
the population is responsible for it.

## 2. …and it is almost entirely NOT sequential stopping's doing (E14)

The control the claim in §1 requires: leave v3 exactly as it is and lower the
gate.

| `MIN_COMMITS` | unresolved | false approval (given resolved) | reveals |
|---:|---:|---:|---:|
| 16 | 0.923 | 0.667 | 22.8 |
| 12 | 0.611 | 0.662 | 19.1 |
| 8 | 0.143 | 0.629 | 15.3 |
| 6 | 0.040 | 0.604 | 14.5 |
| **4** | **0.005** | 0.608 | 13.8 |
| adaptive | 0.003 | 0.549 | 9.8 |

`MIN_COMMITS = 4` reaches 0.005 unresolved. Sequential stopping reaches 0.003.
**The liveness result belongs to deleting a badly-set constant, and a one-line
parameter change collects ~99% of it.** Any argument for a rewrite has to be
made on the other columns, and §4 is where those are.

## 3. Naive sequential stopping is unsafe, and `min_votes` does not defend it (E11, E17)

The attacker is `attacker_always_on = 1.0` — a bot — and honest turnout arrives
at `honest_availability = 0.80` spread across the window. So **arrival order is
hostile at the front**, and a rule that stops early stops on that prefix.

Registry 2,000, hostile share of the registry **0.30**:

| `min_votes` | false approval | hostile share of the tally at the stop |
|---:|---:|---:|
| 2 | 0.869 | **0.711** |
| 4 | 0.869 | 0.711 |
| 8 | 0.880 | 0.713 |
| 16 | 0.881 | 0.720 |
| 24 | 0.884 | 0.715 |

v3 on the same population: false approval 0.598, hostile share of reveals 0.349.

**A floor on votes is not a defence, because the attacker supplies the votes it
counts.** Raising `min_votes` to 24 just stops the rule right after the 24
attackers have finished arriving.

Sensitivity to `bot_prefix` — the fraction of a window inside which an always-on
identity votes, which is a number this engine invents and the project has never
measured:

| `bot_prefix` | naive false approval | hostile@stop | with time floor | hostile@stop |
|---:|---:|---:|---:|---:|
| 0.05 | 0.910 | 0.912 | 0.563 | 0.313 |
| 0.20 | 0.869 | 0.711 | 0.563 | 0.313 |
| 0.40 | 0.813 | 0.512 | 0.563 | 0.313 |
| 1.00 | 0.640 | 0.315 | 0.563 | 0.313 |

At `bot_prefix = 1.00` bots are indistinguishable from people in arrival time and
there is no front-running at all — and naive stopping *still* costs 4 points
against v3 (0.640 vs 0.598). That residue is optional-stopping bias: a rule free
to stop whenever the tally looks decisive stops on noise that happens to look
decisive.

**This failure is a property of stopping early, not of the parameter.** It was
not anticipated and it is worse than the liveness problem the hypothesis set out
to fix.

## 4. A floor on TIME repairs it completely (E16)

An attacker can manufacture votes. He cannot manufacture the clock.
`min_windows = 1` forbids any stop until one full window has completed, so
honest turnout gets its `honest_availability` chance to arrive before anything
can be decided on.

Registry 2,000, prior 0.665:

| `min_windows` | unresolved | false approval | hostile@stop | votes | windows |
|---:|---:|---:|---:|---:|---:|
| 0 | 0.000 | 0.869 | 0.711 | 8.1 | 1.02 |
| **1** | 0.000 | **0.563** | **0.313** | 76.1 | 4.38 |
| 2 | 0.000 | 0.561 | 0.300 | 79.4 | 5.26 |
| 3 | 0.000 | 0.552 | 0.299 | 79.7 | 5.59 |

The hostile share of the deciding tally returns to 0.313 against a population
share of 0.30, and the fix is **completely insensitive to `bot_prefix`** (§3's
last column: 0.563 at every value from 0.05 to 1.00). That insensitivity is what
makes it a defence rather than a tuning: it does not depend on a number nobody
has measured.

## 5. With the fix, the safety gain over v3 is real but small (E10)

All rates conditional on the case resolving. The 250 row is **not** a
like-for-like comparison — v3 resolves 8% of cases there, so its column
describes the self-selected subset that happened to draw a cohort of 16+ from an
expected 10, which flatters it.

**prior 0.665**

| registry | v3 false approval | adaptive | +widen | v3 false rejection | adaptive | +widen |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 0.604 | 0.559 | 0.659 | 0.612 | 0.566 | 0.658 |
| 2,000 | 0.598 | 0.563 | 0.632 | 0.601 | 0.561 | 0.643 |

**prior 0.95**

| registry | v3 false approval | adaptive | +widen | v3 false rejection | adaptive | +widen |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 0.329 | 0.303 | 0.296 | 0.345 | 0.317 | 0.304 |
| 2,000 | 0.338 | 0.313 | 0.316 | 0.326 | 0.300 | 0.330 |

Two to four points, in adaptive's favour, at both priors. Real, and nowhere near
large enough to carry a rewrite on its own.

**Widening makes safety worse, not better** (0.632 vs 0.563 at registry 2,000).
That is `FINDINGS-v3.md` §C's F12 result appearing again through a different
door: the marginal pool a widening step admits is always-on, and always-on is
the attacker's composition, not the population's. Widening should be triggered
by nothing.

## 6. Cost moves the right way only where `prior` is high (E12)

| prior | registry | v3 reveals | adaptive votes | windows | stopped decisive |
|---:|---:|---:|---:|---:|---:|
| 0.665 | 1,000 | 53.5 | 88.0 | 3.22 | 0.904 |
| 0.665 | 2,000 | 106.6 | 117.9 | 2.40 | 0.986 |
| 0.950 | 1,000 | 66.2 | 54.4 | 2.04 | 1.000 |
| 0.950 | 2,000 | 134.5 | **82.7** | **1.44** | 1.000 |

At prior 0.95 and registry 2,000 the case settles in 1.44 windows on 83 votes
against v3's fixed window and 135 reveals — cheaper *and* faster, which is the
whole promise. At prior 0.665 it is **more** expensive than v3 and slower.

## 7. Cost peaks where the answer is least available (E15)

Wald's test has unbounded expected sample size at the indifference point. Here
that point is where E1's quantity `q + (1−q)(1−prior)` reaches 1/2.

| prior | effective hostile share | votes | windows | false approval |
|---:|---:|---:|---:|---:|
| 0.600 | 0.580 | 80.9 | 1.60 | 0.676 |
| 0.665 | 0.534 | 117.9 | 2.40 | 0.632 |
| **0.750** | **0.475** | **216.4** | **3.64** | 0.535 |
| 0.800 | 0.440 | 211.2 | 3.52 | 0.443 |
| 0.900 | 0.370 | 101.1 | 1.87 | 0.361 |
| 0.990 | 0.307 | 75.3 | 1.23 | 0.288 |

216 human votes on one case at prior 0.75. This is correct behaviour for a
sequential test and it is a **real budget risk with an adversarial reading**: an
attacker who holds the tally near 1/2 makes every case maximally expensive
without having to win any of them. v3's fixed cohort cannot be attacked this
way, because its cost does not depend on the tally.

Any adopted version needs a hard cap on votes, and the cap is then the real
parameter — at which point it is a fixed cohort with extra steps on exactly the
cases that reach it.

## 8. What `prior` does to all of this — unchanged

At prior 0.665 both designs sit at 0.56–0.63 false approval. `q + (1−q)(1−prior)`
= 0.534 is past E1's crossover, the amplifier is working for the attacker, and
no stopping rule addresses that: the votes genuinely are majority-wrong.
Sequential stopping decides *when to stop counting*; it cannot decide what the
votes say.

**Nothing here moves the conclusion `measurement/prior/README.md` records.**

---

## Verdict

The rewrite is not supported. Three things are:

1. **`MIN_COMMITS` is set above the mean of the cohort it gates.** §2 shows the
   entire launch-size liveness failure is this and nothing else. It is a
   constant, and it should be a function of `TARGET_COHORT` — never above it.
   This is the finding worth acting on today.
2. **If any sequential element is ever adopted, floor it on TIME, not on votes**
   (§3, §4). This is the one genuinely new result: a vote floor is not a defence
   against a party who supplies votes, and the distinction is invisible in a
   window-granular model. It applies unchanged to the staged-committee proposal,
   whose commit phase closes on a **count** — 15 minutes after the third
   commitment — and is therefore exposed to §3's failure in the same way.
3. **Widening should be triggered by nothing** (§5). Second independent
   confirmation of F12.

Against that: safety improves by 2–4 points (§5), cost improves only at high
`prior` (§6), and a new attack appears where the attacker buys expense rather
than outcomes (§7). That is not a case for replacing a state machine that has
been through four audit rounds.
