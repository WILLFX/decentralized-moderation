# Testnet MVP

Released 29 October 2026. The release includes Swarm Publish, Swarm Review and
Swarm Search, with moderation contracts on Chiado and websites on Swarm testnet.

Source revision: [`888e82a6d7e8478f2e8e0b61a483ae988559bdfc`](https://github.com/WILLFX/decentralized-moderation/tree/888e82a6d7e8478f2e8e0b61a483ae988559bdfc).
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
| Swarm Publish | [Open Publisher](http://127.0.0.1:1633/bzz/68f29f8180eb2d6aa796654d66c64c36297a27424ca601eb6dce4931b46c13b1/) | `68f29f8180eb2d6aa796654d66c64c36297a27424ca601eb6dce4931b46c13b1` |
| Swarm Review | [Open Moderator](http://127.0.0.1:1633/bzz/196ef15a1f7917870333ea558422135a3d6efd9e2c69766866a259cc8e831900/) | `196ef15a1f7917870333ea558422135a3d6efd9e2c69766866a259cc8e831900` |
| Swarm Search | [Open Reader](http://127.0.0.1:1633/bzz/092239e7d6f0f8ac713c6aa97ca22d0359272c4040f30970fd1c79192aa2f099/) | `092239e7d6f0f8ac713c6aa97ca22d0359272c4040f30970fd1c79192aa2f099` |

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
| Moderation | [`0x006392a3f365c3ed4b2ab39897c6de9e2346cdc8`](https://gnosis-chiado.blockscout.com/address/0x006392a3f365c3ed4b2ab39897c6de9e2346cdc8) |
| Stake registry | [`0x82b6eb1e424bd845af0118f574cf0fbe022a72ca`](https://gnosis-chiado.blockscout.com/address/0x82b6eb1e424bd845af0118f574cf0fbe022a72ca) |
| Topic index | [`0x6f047578ba94b6a523f1f6302de440ea740c2586`](https://gnosis-chiado.blockscout.com/address/0x6f047578ba94b6a523f1f6302de440ea740c2586) |
| TEST token | [`0xf6edbdb55c58f3fb2a4346bea561af3526119dca`](https://gnosis-chiado.blockscout.com/address/0xf6edbdb55c58f3fb2a4346bea561af3526119dca) |

The [deployment configuration](../../deployments/chiado/deployment.json) includes
all four code hashes and the guidelines identity used by the public profiles.

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
