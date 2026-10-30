# Moderation contracts

These Solidity contracts implement the [protocol reference](../specs/protocol.md).
The [testnet release entry](../docs/releases/TESTNET_MVP.md) identifies the deployed
stack; [operator guidance](../docs/OPERATORS.md) explains another deployment.

| Contract | Responsibility |
| --- | --- |
| `src/Moderation.sol` | Submission, paired-group voting, outcome draws, challenges, fee custody and settlement |
| `src/StakeRegistry.sol` | Fixed stakes, outstanding votes and additive frozen time |
| `src/IndexRegistry.sol` | Entry facts and paged topic membership |
| `src/testnet/ChiadoTestToken.sol` | Chiado-only TEST token with a public faucet |

## Build and commands

The Foundry configuration selects Solidity 0.8.28, Cancun, optimizer runs 200 and
via-IR compilation. Provision the compiler locally before using offline mode.
Compiler settings affect deployed runtime hashes; keep them aligned with the
artifacts used for deployment and profiles.

From this directory:

```sh
forge build --use 0.8.28
forge test --use 0.8.28
```

The repository-wide command is `bash scripts/check.sh` from its root. The
`test/` and `audit/` directories contain Solidity test sources. `test/vectors/`
holds the data consumed by Python/Rust comparison tools. `tools/mutate.py` is an
optional mutation tool and uses a separate legacy compiler configuration.

## Deploy and link

`script/Deploy.s.sol` takes a `Params` structure, creates both registries and
`Moderation`, then sets their one-time links. Its `verify` method checks links in
both directions and agreement on the token. `script/DeployChiado.s.sol` adds the
TEST faucet token, enforces chain ID 10200 and takes a public deploying address.
A dry script run simulates; broadcasting/signing is a separate operator action.

The root `MODERATION_GUIDELINES.md` supplies the immutable guideline hash. Do not
rewrite its bytes while reusing a deployment identity. New guidelines or contract
logic require new contract addresses and profiles; a website update cannot upgrade
an existing immutable stack.

## Interfaces to retain when changing code

- `challenge(caseId, expectedRound, expectedPreliminary)` binds the reviewed
  decision at execution. The one-argument overload always refuses.
- `outcomeRecoveryOf`, `cacheOutcome` and `expireOutcome` describe the original
  target and precise recovery boundary. A cached original remains drawable.
- `pairScheduleOf` supplies effective deadlines even when stored phase lags the
  first admissible second-group commitment.
- `claim(caseId, moderator)` settles once and pays that moderator. Refunds pay the
  original submitter. Phase advancement and per-vote settlement are permissionless.
- The index records listing origins and current membership separately. A removal
  targets the listing's case and cannot choose a different set of topics.

Read the protocol before changing settlement, seed recovery or phase events.
Arithmetic, exact-call binding and client ABI behavior must agree across components.
