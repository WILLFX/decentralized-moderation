# Outcome probabilities

The model in `floor.py` separates the outcome rule from assumptions about the
people or identities supplying votes. Run `python3 run_floor.py` from this directory
to inspect its configured examples.

## Fixed pooled share

Let `a` be the proportion of pooled revealed votes that approve. The probability
that a majority of three independent tickets approves is:

```text
f(a) = 3*a^2 - 2*a^3
```

Each ticket is an Approve/Reject sample from the same proportions, not the
selection of a new moderator. At a fixed `a`, this expression describes the ticket
rule. It does not depend on whether moderators reached their judgments independently.
Dependence matters when estimating how the tally itself is distributed.

For example, `a = 0.30` gives a 0.216 approval probability. Larger groups do not
force that probability to zero if the pooled approval share stays at 0.30.
Unanimity is decisive: `f(0) = 0` and `f(1) = 1`.

## Finite groups and the limit

`floor.py`'s finite-sample helpers use a binomial Approve count `A` and the smoothed
share `(A+1)/(n+2)`. The released contract uses `A/n` instead. Do not read the
helper's finite-size output as the deployed integer draw calculation.

Under independent identically distributed votes with approval probability `p`,
`A/n` converges to `p`, and the smoothed share does too. Because `f` is continuous
and bounded on `[0,1]`, their expected approval probabilities converge to `f(p)`.
Thus increasing the group size does not remove a positive ticket-rule floor.

The module also compares a different rule: admit only if `A/n >= theta`. For
`theta > p`, the binomial tail is bounded by `exp(-2*n*(theta-p)^2)`. That threshold
rule is a model comparison, not the release's admission or settlement rule.

## Relating a tally to content labels

In the model, let `q` be the fraction of adversarial participants and `prior` the
probability that an honest participant agrees with a reference label. If adversarial
participants approve unsafe content and reject safe content, the expected shares are:

```text
p_unsafe = q + (1-q)*(1-prior)
p_safe   = (1-q)*prior
```

The safe-content share exceeds the unsafe-content share only when:

```text
prior > (1 + q/(1-q)) / 2
```

At `q = 0.30`, that requires `prior > 0.714285...`. These equations depend on the
stated attacker and judgment assumptions. They are not estimates of a live cohort.
If those assumptions put unsafe content above safe content in the tally, changing
only a decision threshold cannot recover the missing distinction.

## Applying the model

Keep judgment quality, correlation, selection and willingness to reveal as separate
inputs. A tallied vote is public protocol data; the chain does not provide a
reference label for whether that judgment was correct. Use the
[measurement interface](../measurement/prior/README.md) when supplying labeled data,
and the [protocol](../specs/protocol.md) for the actual selection and settlement rules.
