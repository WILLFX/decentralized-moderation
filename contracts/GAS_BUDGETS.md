# Gas budgets (M2)

Budgets the Foundry suite asserts against (D9 of `specs/m2-work-order.md`).
"Actual" columns are filled in at M2-9 from `forge snapshot`.

## Block gas limit headroom

**Gnosis Chain block gas limit: ~17,000,000** (working value).

> Verification note: public Gnosis RPC endpoints (`rpc.gnosischain.com`,
> `rpc.gnosis.gateway.fm`, `gnosis.drpc.org`) are unreachable through this
> environment's egress proxy, so this figure could not be confirmed live. It is
> the documented Gnosis block gas limit and has historically only risen; the
> exact live limit must be re-confirmed at M4 deployment. Every budget below is
> sized so the design holds under any limit ≥ 12M.

## Budgets and measured actuals (M2-9)

| Path | Budget | Kind | Actual | Test |
|---|---|---|---|---|
| `claim()` worst case — MAX_DEPTH (86 seats), all reveal, 5 topics, 3 winning appeals | **8,000,000** | **hard ceiling** | **~2,506,000** ✓ | `GasBoundsTest::test_worst_case_claim_under_hard_ceiling` |
| `submit` (5 topics) | 500,000 | soft | ~476,000 | `test_measure_common_path_gas` |
| `commitVote` | 200,000 | soft | ~175,000 | `test_measure_common_path_gas` |

**Hard ceiling result — PASS.** Worst-case `claim()` settles the full MAX_DEPTH
case (5+11+23+47 = 86 voters, five index writes, three winning appeals with
contributors) in **~2.5M gas**, ~15% of the ~17M block limit and well under the 8M
ceiling. Settlement of all 86 voters in one transaction is inherent (Invariant 8:
no stranded pots), and it fits comfortably — no pull-based redesign is required.

> Measurement note. Measuring against freshly-*inserted* voters (never in the
> tree) reported ~14.4M — but that is an artifact: in a real case the panel is
> *drawn from* the sortition tree, so settlement performs cheap warm **updates**,
> not cold leaf inserts. The 2.5M figure pre-stakes and activates the 86 voters so
> the measurement reflects the real update cost. The gap is a caution for any
> future path that would settle voters not already in the tree.

Soft budgets are adjusted to the measured reality per work order D9 and are
documented, not load-bearing. Full per-test gas is in `contracts/.gas-snapshot`.
