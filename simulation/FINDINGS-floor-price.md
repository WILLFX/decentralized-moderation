# Group reveal minimum and participation

Each voting group must supply at least three reveals in the released deployment.
Commitments alone do not satisfy this minimum. A participant who commits and never
reveals receives the same freeze duration as a contrary vote when settled.

`floor_price.py` explores the trade-off between a group minimum, turnout and the
number of identities an attacker would need. Run `python3 run_floor_price.py` to
inspect its configured examples.

## Probability model

For `n` possible participants, independent probability `p` of participating, and
minimum `k`, the model uses the binomial tail:

```text
P(enough participants) = P(X >= k), where X ~ Binomial(n, p)
```

Pair completion depends on both groups, their available populations and reveal
behavior. The contract excludes an address already used in the case, so treating
successive groups as independent equally sized populations is a modeling choice,
not a contract property.

The module's `elig_bits()` uses `max(floor(log2(S)) - 5, 0)` for its larger-group
scenario. The released selection uses subtraction by 4 instead, as defined in
[the protocol](../specs/protocol.md#3-selecting-voting-groups) and `eligibility.py`.
Use the appropriate selection probability when applying the model to a deployment;
do not substitute this module's default population for the released one.

## Cost and interpretation

A unanimous pooled tally remains decisive. Requiring reveals from both groups
means an attacker who is alone in supplying the review must field at least `k`
revealing identities in each group. At selection probability `p`, the rough
expected inventory is `2*k/p`, before address exclusions, entry timing, randomness
and fresh-identity admission are considered. It is not a guaranteed security budget.

A higher minimum can also make ordinary low-turnout cases fail to produce an
outcome. Initial failure refunds the submitter; challenge failure preserves the
standing outcome. These settlement rules are specified in the protocol, rather
than selected by the mathematical runner.
