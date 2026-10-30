# Protocol models

These Python tools explore how selection, turnout, judgment and pooled outcome
draws interact. The [protocol reference](../specs/protocol.md) describes the deployed
rules. Model inputs describe populations and behavior; they are not configuration
read automatically from a live deployment.

Python 3.9 or later is sufficient; the tools use the standard library.

| Topic | Runner | Model | Notes |
| --- | --- | --- | --- |
| Approval probabilities and separability | `run_floor.py` | `floor.py` | [Outcome probabilities](FINDINGS-floor.md) |
| Sequential groups and tally visibility | `run_staged.py`, `run_exact.py` | `staged.py`, `exact.py` | [Paired groups](FINDINGS-staged.md) |
| Participation and group minimum | `run_floor_price.py` | `floor_price.py` | [Reveal minimum](FINDINGS-floor-price.md) |
| Contract draw calculations | `check_draw_vectors.py` | `draw.py`, `keccak.py` | Consumes contract-emitted vectors |
| Address selection | `check_eligibility_vectors.py` | `eligibility.py`, `keccak.py` | Consumes contract-emitted vectors |

Run a runner from this directory, for example `python3 run_floor.py`. Read its
configured assumptions before interpreting its output. `floor_price.py` includes
its own larger-group probability model; it is not the released eligibility rule.
The current selector is in `eligibility.py` and the protocol reference.

The staged/enumerated group models use the raw Approve share from `estimator.py`.
The finite-sample lottery helpers in `floor.py` use the smoothed share
`(Approve+1)/(votes+2)` for comparison; the release uses the raw share instead.
Both shares have the same large-sample limit under that model. `draw.py` implements the contract's integer and domain-separated hash
calculations. Vector checks use files produced by the relevant Solidity tests;
see the repository [build guide](../docs/BUILD_AND_TEST.md).

To study actual judgments, the optional [measurement tools](../measurement/prior/README.md)
consume per-moderator votes and independently supplied reference labels. Pooled
counts alone do not identify which participants made correlated errors.
