# Operator guide

An operator supplies a usable deployment and its service connections. Participants
use those connections through the existing websites; they do not have to deploy
contracts or maintain a Bee. Operators may run infrastructure themselves or choose
providers. The same applications also support independently operated deployments.

## Choose the deployment and services

| Component | Purpose | Who supplies it |
| --- | --- | --- |
| Moderation contracts and TEST token | Cases, stakes, outcomes and topic listings | A deployment operator; the released Chiado deployment is already available |
| Chain RPC endpoint | Reads contract state and canonical/finalized blocks | An operator or the participant's chosen chain provider |
| Swarm read gateway | Reads website collections, metadata and content | An operator, a gateway provider or the participant's Bee |
| Swarm upload service | Stores content/metadata using a usable postage batch | An operator's service or a participant's upload-capable Bee |
| Wallet | Signs publishing, staking and moderation transactions | Each signing participant |
| Private recovery and drafts | Preserve the participant's work | The participant |

An **RPC endpoint** is the network address used to ask a blockchain node for data.
The websites use it for contract identity, case state and receipt checks. Wallets
have their own chain connection and must select the same intended network.

For the released installation, moderation uses **Chiado (10200)**. Swarm storage
uses **Swarm testnet (network 10)**, whose Bee storage contracts are on **Sepolia
(11155111)**. These are separate networks. TEST pays moderation fees/stakes on
Chiado; a Bee uses sBZZ and native test ETH for its Sepolia storage operations.
Ordinary participants do not switch their signing wallet to Sepolia merely to
publish a moderation case.

## Use or deploy contracts

To use the release, start from its [deployment configuration](../deployments/chiado/deployment.json)
and [release entry](releases/TESTNET_MVP.md). Do not create a new stack just to
provide another gateway or upload service.

The current websites support moderation deployments on Gnosis (100) and Chiado
(10200). Configure timing and chain access for the selected network.

For your own deployment, install the [build tools](BUILD_AND_TEST.md), provision
funds for the deploying account and choose the token, stake, fees, deadlines,
reveal minimum, freeze duration and guidelines. `contracts/script/Deploy.s.sol`
creates the stake registry, index and moderation contract and links them.
`DeployChiado.s.sol` additionally creates the public TEST faucet token and requires
Chiado. Its deployment is six transactions: four contract creations and two links.

A Chiado simulation, run from `contracts/`, uses public configuration only:

```sh
forge script script/DeployChiado.s.sol:DeployChiado \
  --sig 'runChiado(address)' "$DEPLOYER_ADDRESS" \
  --sender "$DEPLOYER_ADDRESS" --rpc-url "$CHIADO_RPC"
```

Without a broadcast flag this prepares a simulation, not a live deployment. Review
the chosen parameters and transactions, then use your normal wallet or Foundry
signer workflow to deploy. Keep keys and signer configuration out of the repository
and public profiles. The deployer must complete both registry links; a created but
unlinked stack cannot perform its intended work.

Record the actual addresses and the Keccak-256 hash of each deployed runtime. This
**code hash** identifies the code at the address. Build profiles from those values,
the chain ID and the immutable guidelines version/hash. Do not use a bytecode
template or predicted address as the identity of an already deployed contract.

## Fund test accounts

The released TEST token has 16 decimal places. Its public `faucet()` mints 1,000
TEST to the caller. It is available to any account and has no role in Swarm postage.
An operator can claim TEST and transfer it to participants using an ERC-20-capable
wallet, or let test accounts call the faucet themselves. There is no faucet button
in the three moderation websites.

Signing accounts also need Chiado test xDAI. Use the network and faucet information
in [Gnosis's Chiado guide](https://docs.gnosischain.com/about/networks/chiado).
The current release uses a 10 TEST stake and a 0.01 TEST minimum review fee. Other
deployments choose their own values; obtain them from that deployment.

## Provide public profiles

A profile combines contract identity with connection settings. The public
[raw-content profiles](../deployments/chiado/profiles/raw/) and
[collection-content profiles](../deployments/chiado/profiles/collections/) are
complete local-Bee presets for the released deployment. Their loopback addresses
refer to the browser user's device. Adapt service URLs for your installation;
retain the contract/code/guidelines pins when using the same deployment.

| Configuration | Public use |
| --- | --- |
| `deployment` | Chain, four contract addresses/code hashes and guidelines identity |
| `rpcUrl` | A chain endpoint that accepts browser requests |
| `gatewayUrl` | Metadata/content reads for Moderator, metadata reads for Reader |
| `contentGatewayUrl` | Separate content viewing in Publisher and Reader |
| `metadataPath` | `bytes` for metadata uploaded by Publisher |
| `contentPath` | `bytes` for raw references or `bzz` for Bee file/collection references |
| `display` | Token symbol/decimal places supplied by the operator; match them to the token |
| Moderator `timing` | Local clock allowance, evidence/head freshness and inclusion budget |
| Optional Publisher `upload` | Upload endpoint and a batch usable by that endpoint |

Public profiles contain no RPC secret, authorization header, key or node password.
Keep credential-bearing configuration private. Publisher can apply an endpoint,
batch and optional authorization through its existing Bee settings without changing
deployment pins; those settings stay in memory. Moderator and Reader get their
read connections from their selected profile. Give users a new profile when those
connections change.

Host public profile files at HTTPS URLs or distribute them as downloadable JSON.
Provide the deployment identity through the channel participants trust. Publisher
and Reader can review a profile URL and its exact-byte fingerprint; a fingerprint
is a content identifier, not an endorsement of the operator. The existing
[publisher setup helper](PUBLISHER_SETUP.md) builds such links. Local-file selection
is also available. Do not publish personal drafts or private recovery as profiles.

### Match content access

Swarm's `/bytes` route retrieves raw stored bytes. `/bzz` opens a file or collection
manifest, including a website's default page. The published websites themselves
use `/bzz`; this does not mean every submitted content reference uses that route.

The in-page publisher uploader creates raw references, so use the raw profiles for
that workflow. An externally uploaded Bee file/collection uses the collection
profiles. Metadata remains raw `/bytes` in either case. The current content schema
does not carry a per-entry access-mode field: the selected profile supplies the
viewing route. Keep the mode consistent for a submission and provide the matching
profiles to its reviewers and readers, including when an index contains both types.

Content viewing must use a different **origin** from the application. An origin is
the scheme, hostname and port together; a different path on the same host is not
a different origin. The local presets serve applications at `127.0.0.1:1633` and
open submitted content at `localhost:1633`. For hosted services use a separate
content origin. Keep the pinned guidelines available at the profile's guidelines URL.

## Run Bee or use a service

A read gateway may be supplied independently of an upload service. A read-only user
needs neither a postage batch nor an upload-capable node. For owned infrastructure,
start with [Bee installation](https://docs.ethswarm.org/docs/bee/installation/quick-start/)
and its [configuration reference](https://docs.ethswarm.org/docs/bee/working-with-bee/configuration/).
Select Swarm testnet and a Sepolia chain endpoint for this release. Use an endpoint
that can supply the contract logs needed for Bee's synchronization.

Before uploads, let Bee synchronize and check that the selected batch is usable by
that node. A batch ID alone does not give another node the authority to issue its
stamps. Serve RPC and gateway requests from the application origins using CORS
(Cross-Origin Resource Sharing). For upload services, allow the required POST
requests and headers and apply appropriate authorization. CORS is not a substitute
for authorization on a shared service.

Serve public applications over HTTPS or a browser-supported loopback origin.
Ensure that the browser can reach the configured services; HTTPS-hosted pages may
need HTTPS service URLs or local-network permission for loopback access. Browser
wallet access, cryptography and local storage also depend on the browser context.

## Publish website collections and maintain storage

Build the three applications with `websites/scripts/build.sh`. Their outputs are
separate collections in `websites/dist/{publisher,moderator,search}`. Each contains
its public entry page, styles, loader, guidelines and Wasm bindings. Upload the
collection with `index.html` as its default document using your chosen Bee tooling.
Keep configuration, private keys, drafts and recovery files out of the collection.

The repository's `publish-local.mjs` is specifically for an already running owned
local Bee-factory environment. It is not a general public-node installer. See
[website tooling](../websites/README.md) for that route. For other Bee services,
use their existing upload tooling or the [Bee API](https://docs.ethswarm.org/api/).

Publish each collection's reference together with its source revision and public
profile links. Operators may also serve the same static assets through HTTPS.
Changing a deployment profile does not replace a website build, and changing a
website does not upgrade an immutable contract.

Postage pays for a finite storage period. Monitor remaining batch time and capacity
and fund/top up storage before it expires. Price changes affect duration. Cover
both website assets and submitted content/metadata; approval in the topic index
does not keep bytes stored. If a new upload produces a different reference, update
public access information rather than silently treating it as the old collection.
