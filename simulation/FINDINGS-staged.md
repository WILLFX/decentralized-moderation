# Sequential groups and pooled voting

`staged.py` and `exact.py` compare one-group and paired-group arrangements under
configured populations and behavior. Their outcome draws use the combined revealed
tally. Run `run_staged.py` for sampling and `run_exact.py` for the enumerated model.

## What sequential commitment changes

In the released protocol the second group's seed is scheduled before its hash
exists. The groups commit in sequence, then reveal together. The second group
therefore has no first-group revealed tally to follow while committing.

This can reduce behavior driven by a visible lead. The effect depends on how much
participants would otherwise follow that lead. It does not make identities unique,
prevent off-chain coordination or make judgments independent.

## Why one favorable group is not the whole outcome

Let `P_n` be the probability that a group with expected size `n` exceeds a chosen
adversarial-share threshold. With independent selections, the probability that at
least one of two such groups exceeds it is `1 - (1-P_n)^2`.

That quantity is not the capture probability of the implemented outcome rule.
Both groups' revealed votes enter the same pool. A favorable first group is diluted
or reinforced by the second group's actual votes; it does not select the outcome
by itself. Compare pooled shares and outcome draws rather than treating either
group's local majority as a decisive result.

The runners include assumptions about information available to the attacker,
participation, conformity and external incentives. State those inputs with any
reported model output. Use the [protocol reference](../specs/protocol.md) for actual
seed windows, group admission and case-wide address exclusions.
