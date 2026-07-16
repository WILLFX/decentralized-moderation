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

## Budgets

| Path | Budget | Kind | Actual (M2-9) |
|---|---|---|---|
| `claim()` worst case — MAX_DEPTH (86 seats), all reveal, 5 topics | **8,000,000** | **hard ceiling** | — |
| `submit` (5 topics) | 400,000 | soft | — |
| seat-draw poke (1000 moderators, 47 seats) | 2,000,000 | soft | — |
| `commitVote` | 150,000 | soft | — |
| `reveal` | 120,000 | soft | — |
| `contributeAppealBond` | 150,000 | soft | — |

**Hard ceiling rationale.** Worst-case `claim()` must settle in a *single*
transaction (Invariant 8: no stranded pots). 8M is ~47% of the ~17M block limit —
comfortable headroom even if the limit is lower than assumed or a future opcode
reprice raises costs. If the measured worst case breaches 8M, that is a **design
change** (move rewards to a pull-based claim), not a budget bump — stop and report
(work order D9).

Soft budgets are adjusted to measured reality at M2-9 and are documented, not
load-bearing.
