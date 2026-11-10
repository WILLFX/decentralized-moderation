# Testnet MVP

Released 4 November 2026. The release includes Swarm Publish, Swarm Review and
Swarm Search, with moderation contracts on Chiado and websites on Swarm testnet.
The website bundles were updated on 10 November 2026.

Source revision: [`7f2438fb09017744af724b54996e4552414076a6`](https://github.com/WILLFX/decentralized-moderation/tree/7f2438fb09017744af724b54996e4552414076a6).
The [release manifest](../../deployments/chiado/manifest.json) contains the website
references and public asset checksums. Documentation and connection profiles can
be updated independently of these published application bytes.

## Open a website

A Bee or gateway connects your browser to Swarm. Choose one connected to **Swarm
testnet, network ID 10**. The links below use a Bee running on your own device at
its standard local address. If you use an operator's gateway, open
`<gateway>/bzz/<website-reference>/` with the same reference.

| Website | Open through a local Bee | Swarm reference |
| --- | --- | --- |
| Swarm Publish | [Open Publisher](http://127.0.0.1:1633/bzz/7a655e42c811ef90248cf9505bf4bec7362499266df8be68f6f34c97aca509a3/) | `7a655e42c811ef90248cf9505bf4bec7362499266df8be68f6f34c97aca509a3` |
| Swarm Review | [Open Moderator](http://127.0.0.1:1633/bzz/6b4978dcef078eab26a00c42926e22dee398ccd08783bc61a8db044c6e9d951d/) | `6b4978dcef078eab26a00c42926e22dee398ccd08783bc61a8db044c6e9d951d` |
| Swarm Search | [Open Reader](http://127.0.0.1:1633/bzz/3c2d994f2d76913fa3d4cb448b65ff8ff7834bbbc0be36f14246b05919ff53ec/) | `3c2d994f2d76913fa3d4cb448b65ff8ff7834bbbc0be36f14246b05919ff53ec` |

The same released references can also be opened through weeb-3's browser client:

| Access route | Publisher | Moderator | Reader |
| --- | --- | --- | --- |
| weeb-3 · Swarm testnet | [Open Publisher](https://lat-murmeldjur.github.io/weeb-3/testnet/bzz/7a655e42c811ef90248cf9505bf4bec7362499266df8be68f6f34c97aca509a3/) | [Open Moderator](https://lat-murmeldjur.github.io/weeb-3/testnet/bzz/6b4978dcef078eab26a00c42926e22dee398ccd08783bc61a8db044c6e9d951d/) | [Open Reader](https://lat-murmeldjur.github.io/weeb-3/testnet/bzz/3c2d994f2d76913fa3d4cb448b65ff8ff7834bbbc0be36f14246b05919ff53ec/) |

The `/testnet/` path selects Swarm network 10. Publishing and moderation wallet
transactions still use Chiado, as described below.

The contracts and Swarm content references are public. The local links are not a
shared hosting service. You may use your own Bee, an operator's service or a
compatible gateway. [Participant guidance](../PARTICIPANTS.md) explains the three
journeys; [operator guidance](../OPERATORS.md) explains service configuration.

## Public connection profiles

Download the JSON file for the website and accept it through its existing Source
controls. These are **local-Bee presets**, not personal node records. They contain
the released contract identities and standard loopback read addresses. A publisher
supplies their own upload connection and usable batch, or uses an operator's
profile with those settings. No private access credentials or project-owned stamp
is distributed in these files.

| Content access | Publisher | Moderator | Reader |
| --- | --- | --- | --- |
| Raw files, including the in-page file uploader | [Publisher profile](../../deployments/chiado/profiles/raw/publisher.json) | [Moderator profile](../../deployments/chiado/profiles/raw/moderator.json) | [Reader profile](../../deployments/chiado/profiles/raw/reader.json) |
| Bee files and collections opened through `/bzz` | [Publisher profile](../../deployments/chiado/profiles/collections/publisher.json) | [Moderator profile](../../deployments/chiado/profiles/collections/moderator.json) | [Reader profile](../../deployments/chiado/profiles/collections/reader.json) |

Keep the content access mode consistent across a submission's publisher, moderator
and reader connections. Operators using hosted or different Bee services can adapt
these public profiles without changing the deployment pins. See
[matching content access](../OPERATORS.md#match-content-access).

## Chiado deployment

Select **Chiado, chain ID 10200**, in the publishing or moderation wallet. The
native transaction-fee token is Chiado test xDAI. TEST is the separate moderation
and staking token, with 16 decimal places.

| Contract | Address |
| --- | --- |
| Moderation | [`0x1fc3c373bb6575e92118095746ee4dde9f653d40`](https://gnosis-chiado.blockscout.com/address/0x1fc3c373bb6575e92118095746ee4dde9f653d40) |
| Stake registry | [`0xddf50f669327b3e4e3981cf12ee77778f00ad1d3`](https://gnosis-chiado.blockscout.com/address/0xddf50f669327b3e4e3981cf12ee77778f00ad1d3) |
| Topic index | [`0x09418cd42e11b45ce349d3ae7417cbd1d09fa0d3`](https://gnosis-chiado.blockscout.com/address/0x09418cd42e11b45ce349d3ae7417cbd1d09fa0d3) |
| TEST token | [`0xf6edbdb55c58f3fb2a4346bea561af3526119dca`](https://gnosis-chiado.blockscout.com/address/0xf6edbdb55c58f3fb2a4346bea561af3526119dca) |
| Replacement authority | [`0x98d7272dcd2523b0c51af5022a7766f655802669`](https://gnosis-chiado.blockscout.com/address/0x98d7272dcd2523b0c51af5022a7766f655802669) |

The [deployment configuration](../../deployments/chiado/deployment.json) includes
the contract code hashes, guidelines identity and known moderation versions used
by the public profiles.

| Setting | Released value |
| --- | --- |
| Fixed moderator stake | 10 TEST |
| Minimum review fee | 0.01 TEST |
| Commit window after a group's third commitment | 15 minutes |
| Initial maximum wait for a group's third commitment | 1 hour |
| Shared reveal period | 30 minutes |
| Challenge period | 1 hour |
| Maximum challenges per case | 2 |
| Required reveals | At least 3 from each group in the round |
| Freeze added per contrary vote or missing reveal | 8 days |
| Guidelines | Version 1, hash `0x780247619462ac3dcc846780bffd6e527329ff20673bafe0e33ffc6ecd23b00f` |

The stake registry and topic index persist when an authorized moderation version
is replaced. The [authorization Safe](https://gnosis-chiado.blockscout.com/address/0x32d21b0ccc5e7d64ab47cc17359cfb05fe977c30)
currently has three founder-controlled owner accounts and requires two signatures.
It authorizes exact moderation code and settings with a fixed **10-minute notice**.
Earlier registered versions retain the ability to finish their existing cases.
See the [persistent-registry interface](../../specs/persistent-registries.md).

For a stake, case or listing at an earlier standalone deployment, select its
[existing-work profile](../../deployments/chiado/existing-work/README.md).
Those profiles preserve the original source for completion, refunds, eligible
withdrawals and discovery while blocking new payments and fresh staking in the
matching clients. Earlier approvals are not copied into the new index.

Use the case's actual deadlines. Scheduling, block availability and the calls that
advance a phase affect when actions become available. Full rules are in the
[protocol reference](../../specs/protocol.md).

The TEST contract has a public `faucet()` that mints 1,000 TEST to its caller.
Operators can use it to fund test accounts or distribute TEST to participants.
[Chiado's network guide](https://docs.gnosischain.com/about/networks/chiado) lists
network settings and a faucet for native test xDAI. Neither TEST nor Chiado gas
pays for Swarm storage: a testnet Bee's storage funding is on Sepolia.

## Feedback and continued access

Report issues through the [repository issue tracker](https://github.com/WILLFX/decentralized-moderation/issues).
Name the website and deployment, describe the action and result, and include a
public case or transaction hash where useful. Do not attach private recovery or
service credentials.

The website collections and submitted content need paid storage to remain
available. Bee operators monitor postage and renew it before expiry. A contract
record or content reference does not renew storage by itself.
