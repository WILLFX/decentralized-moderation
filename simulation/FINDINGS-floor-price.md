# Pricing the per-committee minimum — E38–E41

**The floor is cheap wherever the system is healthy and expensive exactly where
it is needed. That is the finding, and it is not a comfortable one.**

Produced by `run_floor_price.py`, engine `floor_price.py`. Exact — binomial
tails, no sampling.

---

## §A What is being priced, and why it is not optional

`specs/protocol.md` §11 carries an open item, in its own words: *"Set a minimum
commitment requirement for each committee. A combined threshold is not enough."*

It reads like tidy-up. It is not. Three specified choices meet:

- §5's raw share `A/N` makes a unanimous tally **certain**;
- §4.1 starts the commit clock at the third commitment and says plainly that
  three commits are a trigger, **not a quorum**;
- nothing requires committee B to contain anybody.

Each is defensible alone. Together, **three identities that are the only
committers take a case with probability 1** — pinned at 40 of 40 in
`contracts/test/ThreeVote.t.sol`.

## §B The committee size is not a free parameter

§3 makes an identity eligible on `N − 5` leading zero bits, with the registry in
`[2^N, 2^(N+1))`. So eligibility is `2^-(N-5)` and the expected committee falls
out of the rule rather than being chosen:

| registry | bits | P(eligible) | expected committee |
|---:|---:|---:|---:|
| 100 | 1 | 0.5000 | 50.0 |
| 250 | 2 | 0.2500 | 62.5 |
| 1000 | 4 | 0.0625 | 62.5 |
| 5000 | 7 | 0.0078 | 39.1 |

Between 32 and 64 by construction. Every floor below is read against a committee
of that order.

## §C What a floor costs

The cost is cases that cannot resolve. It turns entirely on **turnout** — the
fraction of eligible moderators who actually commit — which is unmeasured, and
which is the only quantity that matters here: the capture a floor exists to stop
requires almost nobody to show up, so **the floor is only ever tested in a quiet
registry.**

`P(a case cannot resolve)`, registry 1000, ~62 eligible per committee:

| turnout | committers | k=2 | k=3 | k=4 | k=6 | k=8 | k=12 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2% | 1.2 | 87.4% | 98.3% | 99.9% | 100% | 100% | 100% |
| 5% | 3.1 | 32.9% | 63.4% | 85.5% | 99.1% | 100% | 100% |
| 10% | 6.2 | 2.7% | 10.0% | 24.2% | 64.7% | 91.5% | 99.9% |
| 20% | 12.5 | 0.0% | 0.1% | 0.3% | 2.9% | 13.3% | 64.6% |
| 40% | 25.0 | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 0.3% |
| 80% | 50.0 | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |

Both committees must clear the floor and they are drawn independently, so the
survival probability is **squared**. That squaring is what makes the middle rows
steep.

## §D What a floor buys

No subtlety here. A floor of `k` forces any clique deciding a case alone to field
`k` identities in **each** committee:

| floor k | identities that must commit | roughly held, at p(elig) = 0.0625 |
|---:|---:|---:|
| 1 | 2 | 32 |
| 2 | 4 | 64 |
| 3 | 6 | 96 |
| 4 | 8 | 128 |
| 6 | 12 | 192 |
| 8 | 16 | 256 |

Today's effective floor in committee B is **zero**, which is the whole of why
three identities suffice.

## §E Per-committee, not combined

At registry 1000 and 5% turnout, a combined floor of `2k` against `k` in each:

| k | per-committee | combined (2k) | combined permits an empty B |
|---:|---:|---:|:---:|
| 2 | 32.9% | 13.0% | yes |
| 3 | 63.4% | 40.6% | yes |
| 4 | 85.5% | 70.9% | yes |
| 6 | 99.1% | 97.4% | yes |

The combined floor is always cheaper and buys nothing: `2k` commits in A and none
in B clears it, which is precisely the arrangement the staging exists to prevent.
The specification was right to insist on per-committee, and the cost of being
right is the gap between those two columns.

## §F The conclusion, including the part that is uncomfortable

**A floor works, and the price is paid in exactly the conditions that make the
attack possible.** At 40% turnout a floor of 8 is free and forces a 256-identity
clique. At 5% turnout a floor of 3 already leaves 63% of cases unresolvable, and
a floor of 2 — which still only forces four committed identities — costs a third
of them.

So the honest statement is not "pick `k = 4`". It is:

1. **The floor is the right mechanism.** It is on the specification's own list,
   it closes a demonstrated certainty attack, and per-committee is the correct
   shape for the reason the specification already gave.
2. **Its price is a function of turnout, which nobody has measured.** Every cell
   above is conditional on a number the testnet exists to produce.
3. **A low-turnout registry cannot have both.** Below roughly 10% turnout there
   is no `k` that both stops a small clique and leaves ordinary cases resolvable.
   That is not an argument against the floor; it is the same finding as
   `FINDINGS-floor.md` arriving from a different direction — **a design cannot
   buy safety it has no participation to pay for.**

What follows for the parameter is a range, not a value: **`k` between 2 and 4 is
defensible at 20% turnout or better, and nothing is defensible below 10%.**
Choosing inside that range is a judgment about expected participation, and it is
not mine to make.

## §G Assumptions

1. Turnout is independent across identities and across the two committees. Real
   moderators are correlated — the same people are busy at the same times — and
   correlation makes the squaring worse, not better.
2. Committers are treated as revealers. A commit that never reveals still counts
   toward a commit floor, which is what the specification asks for, but it means
   the floor guarantees participation and not evidence.
3. An attacker is always-on and honest moderators are not, which is the design's
   own stated asymmetry.
4. The eligibility rate is exact from §3; the registry sizes are chosen, the
   committee sizes are not.
