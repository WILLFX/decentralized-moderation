# The lottery floor — E33–E37

Produced by `run_floor.py`, engine `floor.py`. Exact throughout: closed forms
verified against direct enumeration, asymptotics proved rather than extrapolated.

The claim under examination, from the external review:

> "Suppose increasingly large challenge committees consistently contribute 30%
> false approvals and 70% correct rejections... the pooled approval fraction
> approaches 0.30. Consequently [`P(approve) → 21.6%`]."

**The arithmetic is right and the number is optimistic.** `f(0.30) = 21.6%` is
the floor when honest moderators never err. Under this design's own working
accuracy the floor is **55.2%**.

And the floor turns out to be the second most important thing here.

---

## §A The floor is real, and it is a limit not a measurement

Each revealed vote is Approve with probability

    p_unsafe  =  q + (1 − q)(1 − prior)

— the attacker's whole share, plus honest error. The verdict draws on
`â = (A+1)/(N+2)` and admits with probability `f(â) = 3â² − 2â³`.

**Theorem.** `lim_{N→∞} E[f(â)] = f(p)`, a positive constant independent of `N`.

**Proof.** `A/N → p` almost surely by the strong law, and `â = (A+1)/(N+2)` has
the same limit. `f` is a polynomial, hence continuous and bounded on `[0,1]`, so
bounded convergence gives `E[f(â)] → f(p)`. ∎

Exactly, at `q = 30%`:

| N | perfect moderators (`p = 0.300`) | `prior = 0.665` (`p = 0.5345`) |
|---:|---:|---:|
| 4 | 32.030% | 53.130% |
| 16 | 25.517% | 54.378% |
| 64 | 22.723% | 54.938% |
| 256 | 21.892% | 55.107% |
| 4096 | 21.618% | 55.163% |
| **∞** | **21.600%** | **55.167%** |

**Adding honest reviewers does not drive the error down.** It removes the
sampling noise around a constant. At the working `prior` the sequence *rises*
toward its limit, because `p > ½` there and the estimator converges upward.

E33 checks the closed form for `E[f(â)]` against direct enumeration over 20
cells; worst disagreement `3.25e-15`.

## §B A threshold rule has no floor — the difference is Θ(1) vs exp(−Θ(N))

Replace "admit with probability `f(â)`" by "admit iff approvals ≥ `θ` of the
preselected positions", with `θ > p_unsafe`. Hoeffding gives
`P(admit) ≤ exp(−2N(θ − p)²)`.

At perfect moderators, `p = 0.30`, `θ = 0.75`:

| N | lottery | threshold (exact tail) |
|---:|---:|---:|
| 16 | 25.52% | 2.66e-04 |
| 32 | 23.74% | 1.98e-07 |
| 64 | 22.72% | 1.50e-13 |
| 128 | 22.18% | 1.21e-25 |
| 256 | 21.89% | 1.10e-49 |

At `prior = 0.85`, `p = 0.405`, `θ = 0.75`: 36.5% against 2.2e-08 at N = 64.

**Reviewers needed for 1e-9 unsafe admission:** 51 under the threshold at perfect
accuracy, 87 at `prior = 0.85` — and **infinite** under the lottery at any
target below its floor.

This is the whole argument for separating admission from settlement. Under a
lottery, review effort buys variance reduction and nothing else. Under a
threshold, review effort buys error exponentially. They are not two tunings of
one mechanism.

## §C The bound that outranks both

A threshold needs a `θ` strictly between the two Approve rates:

    p_unsafe = q + (1−q)(1−prior)   <   θ   <   (1−q)·prior = p_safe

Such a `θ` exists iff `p_safe > p_unsafe`, which rearranges to

> **`prior  >  ( 1 + q/(1−q) ) / 2`**

| q | `prior` required | `p_unsafe` | `p_safe` | separable at 0.665? |
|---:|---:|---:|---:|:---:|
| 5% | 0.5263 | 0.3682 | 0.6318 | yes |
| 10% | 0.5556 | 0.4015 | 0.5985 | yes |
| 20% | 0.6250 | 0.4680 | 0.5320 | yes |
| **30%** | **0.7143** | **0.5345** | **0.4655** | **no** |
| 40% | 0.8333 | 0.6010 | 0.3990 | no |

**At the working point — `q = 30%`, `prior = 0.665` — `p_unsafe > p_safe`.** A
revealed vote is *more* likely to be Approve on unsafe content than on safe
content. The tally is anti-correlated with the truth.

No rule over that tally separates the two cases. Not the lottery, not a
threshold, not unanimity, not any cohort size. **There is no signal to decide
on.** This is not a statement about the decision rule; it is a statement about
the votes.

## §D What it would take

E37: reviewers needed for 1e-6 unsafe admission under a threshold at the midpoint
of the two rates. `—` means not separable at any size.

| q \ prior | 0.665 | 0.750 | 0.800 | 0.850 | 0.950 |
|---:|---:|---:|---:|---:|---:|
| 5% | 398 | 153 | 102 | 73 | 43 |
| 10% | 712 | 226 | 143 | 98 | 55 |
| 20% | 6,746 | 691 | 352 | 213 | 102 |
| 30% | — | 11,052 | 1,919 | 765 | 254 |
| 40% | — | — | — | 69,078 | 1,410 |

These are Hoeffding bounds, so conservative — the exact tail needs fewer. They
give the shape: once separable, effort converts to error exponentially, and the
required effort explodes as `prior` approaches the separability bound from above.

## §E What this means for the three open arguments

**The lottery-versus-certificate argument is settled on the merits and is
secondary.** A lottery cannot be a safety certificate — proven in §A, and no
parameter choice changes it. A threshold can — proven in §B. But both are
downstream of §C.

**The staged-committee argument is downstream too.** `FINDINGS-exact.md` shows
splitting a committee is strictly worse; that remains true and still matters for
how a cohort is drawn. It changes the constant, never the floor.

**`prior` decides whether any of this is deployable.** The project's own README
already said *"≈ 0.665 … is not a search index, and no state machine repairs
it."* §C is the exact form of that sentence: the condition is
`prior > (1 + q/(1−q))/2`, and at `q = 30%` it is `prior > 0.714`.

`measurement/prior/` is therefore not one open item among several. It is the
one that determines whether the others are worth arguing about.

## §F Assumptions

1. **Votes independent given the content.** For *this* result independence is
   conservative: it is the best case for averaging, and correlated error raises
   the floor rather than lowering it.
2. The attacker holds a fixed share `q` of revealed votes and always votes its
   direction.
3. **`prior` is one number, not a per-content-class distribution.** An adversary
   choosing content from a class reviewers handle badly faces a lower effective
   `prior` than the average — so the separability bound should be read against
   the *hard band*, not the mean.
4. The threshold comparison assumes a **fixed denominator** — approvals out of
   preselected positions, not out of whoever revealed. Without that, selective
   non-participation reshapes the denominator and the exponential decay does not
   hold. This is the one structural requirement a threshold certificate adds.
