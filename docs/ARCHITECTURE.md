# Architecture

The system separates content storage, moderation decisions and discovery.
Swarm stores content and metadata. Contracts track review cases and approved topic
listings. Three Rust/Wasm websites make those operations available in a browser.
A profile connects a website to a chosen deployment and its services.

## Data flow

1. Publisher inspects content, builds metadata in the [shared format](METADATA.md),
   and uploads metadata as raw Swarm bytes. The content and metadata have separate
   references. A reference identifies bytes; it is not a server location.
2. Submission pays a review fee and records both references and topic keys in
   `Moderation`. The contract does not fetch content or parse JSON.
3. Staked moderators retrieve the submitted documents and the pinned guidelines.
   They commit private choices, reveal them, and progress the case to an outcome.
4. A finalized listing approval writes topic membership into `IndexRegistry`.
   An approved removal removes membership without deleting Swarm data.
5. Reader queries the index, associates entries with their original listing cases,
   authenticates metadata and refreshes membership before opening content separately.

## Components

| Location | Responsibility |
| --- | --- |
| `contracts/src/Moderation.sol` | Cases, voting, draws, challenges, fees and settlement |
| `contracts/src/StakeRegistry.sol` | Fixed stakes, outstanding votes and frozen time |
| `contracts/src/IndexRegistry.sol` | Approved entries and paged topic membership |
| `contracts/src/testnet/ChiadoTestToken.sol` | The release's public TEST faucet |
| `websites/apps/{publisher,moderator,search}` | Three separate website entry points |
| `websites/crates/swarm-core` | Profiles, metadata, ABI encoding and protocol calculations |
| `websites/crates/swarm-browser` | Browser views, requests, wallet connection and storage |
| `websites/apps/checkpoint` | Native local-chain checkpoint processor |
| `tools` | Packaging, upload and local infrastructure support |
| `simulation`, `measurement/prior` | Mathematical models and optional analysis tools |

Rust compiles to WebAssembly (Wasm), executable browser code. Generated JavaScript
loads its bindings. Node scripts support development and packaging; they do not
implement the participant workflows.

## Public data and private work

Contracts record addresses, commitments, revealed votes, outcomes and payments.
Metadata describes content using a common schema. An index entry is identified by
the content/metadata pair and a topic. Clients can choose ranking and category
relationships without changing the moderation contract.

Moderator choices and their random secrets live in encrypted browser storage and
user-held recovery files until revelation. Public request history stores request
identifiers and receipt follow-up, not those secrets. Publisher draft files preserve
authoring text independently of transaction readiness.

A wallet signs transactions. A chain RPC supplies reads. Bee/gateway connections
supply content and upload access. These roles can use separate providers. Public
profiles identify contracts by address and code hash; personal service credentials
belong in private settings, not in the static website package.

## Boundaries between components

Hash checks authenticate exact metadata/guideline bytes. They do not decide whether
a description is truthful; moderators make that judgment against the guidelines.
Reader membership is a chain observation at a stated block, not a perpetual promise
that the entry is listed or that its content remains stored.

Submitted content opens on a separate origin from the application. Each signing
request retains the account, deployment and exact intended operation. Reveals use
both finalized/latest chain state and a second time/inclusion check immediately
before disclosure. An unavailable prerequisite blocks the action rather than
silently changing its meaning.

Contract identities and guidelines are fixed per deployment. A new website can
connect to an existing deployment; it cannot change that contract's rules. See the
[protocol](../specs/protocol.md), [connection guide](OPERATORS.md) and
[transaction/trust model](SECURITY_AND_OPERATING_BASIS.md).
