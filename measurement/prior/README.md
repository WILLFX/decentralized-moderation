# Judgment analysis tools

These optional Python tools analyze labeled votes. They do not drive the released
websites, select moderators or change contract outcomes.

Two quantities are useful:

- `prior`: how often a participant's vote agrees with a supplied reference label.
- `rho`: an estimate of correlation between participants' errors on the same items.

The chain records votes and outcomes, not ground truth. Supply reference labels
separately. Commit/reveal hides choices before disclosure; it does not make people
independent judges or prevent shared mistakes.

## Supply case records

From this directory, use the data interface in `measure.py`:

```python
from measure import CaseRecord, from_testnet, report

cases = [
    CaseRecord(id="example-1", votes={"rater-a": True, "rater-b": False},
               truth=True, guidelines_version=1)
]
report(*from_testnet(cases))
```

This is a small format example, not a statistical sample. `from_testnet` consumes
the supplied records; it is not a live-chain indexer. Retain the deployment and
exact guideline identity alongside any exported dataset. Different deployments
can use the same version number with different documents; do not merge them by
version number alone.

Keep individual `(rater, item)` votes. Pooled Approve/Reject counts cannot recover
per-rater reliability or distinguish shared errors. The helper's bands are based
on observed disagreement, not an objective measure of an item's difficulty.

## Interpret the output

`prior_by_band` groups agreement with labels by band. `reliability_by_rater` and
`reliability_spread` describe the distribution across supplied raters. `rho`
estimates shared error, and `rho_is_usable` applies the helper's minimum sample
conditions (eight configurations and one hundred items by default). Sparse samples,
shared reference-label errors and repeated raters affect interpretation.

The [probability model](../../simulation/FINDINGS-floor.md) explains how assumed
judgment accuracy enters an outcome calculation. A computed statistic describes
the supplied sample; it does not establish future participants' accuracy or define
a reward rule.

## Optional classifier adapter

`run()` accepts caller-supplied `Config` objects with a
`classify(system, user) -> bool` function and corpus items. Model/provider access
belongs to the caller. Repeats can separate nondeterminism from disagreements
between configurations. Identical configurations run by different accounts must
not be counted as independent judges merely because their account names differ.

This adapter is analysis tooling, not an automated-moderator feature of the MVP.
