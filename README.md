# Decentralized Moderation

Decentralized Moderation helps people publish Swarm content for review and discover
approved listings by topic. It combines three websites with a shared moderation
protocol and an on-chain index.

[Swarm](https://www.ethswarm.org/) stores the content. A content reference identifies
its bytes. The publisher adds metadata: a title, description, type and topics in a
common format. Moderators review the content and its description against shared
guidelines. Approved listings enter the index, which discovery clients can read
and present in their own way.

## Use the testnet MVP

The [testnet release entry](docs/releases/TESTNET_MVP.md) contains the three published
websites, source revision, Chiado contracts and downloadable connection profiles.
It explains how to open the websites through a Swarm testnet Bee or gateway.

| What you want to do | Website | Guide |
| --- | --- | --- |
| Find approved content and open it | Swarm Search | [Discover content](docs/PARTICIPANTS.md#discover-content) |
| Describe content and submit it for review | Swarm Publish | [Publish content](docs/PARTICIPANTS.md#publish-content) |
| Stake, review cases, vote and collect rewards | Swarm Review | [Moderate content](docs/PARTICIPANTS.md#moderate-content) |

Reading needs no wallet. Publishing and moderation use a compatible browser wallet
on Chiado, the Gnosis testnet. Moderation fees and stakes use the release's **TEST**
token; transaction fees use Chiado test xDAI. Swarm upload services handle their own
storage funding.

You can use your own wallet and Bee connection, or services supplied by an operator.
You do not need to deploy contracts or operate a Bee node to participate when those
services are supplied. Other operators can deploy the same software and distribute
their own profiles. The websites select a deployment through configuration.

## How review works

A paid review request is a **case**. Two groups of eligible staked moderators commit
their choices privately, then reveal them in a shared period. The contract draws
an outcome from the combined votes. A challenge can start another round. Once the
outcome is final, matching votes share the review fee; contrary votes and missing
reveals can freeze a moderator's stake for a period. The stake itself is not taken.

The index records approval, topics and review facts. Search clients can choose their
own ranking and presentation. Approval is a judgment under the deployment's
guidelines, not a guarantee about every use of the content. Removing a listing
changes the index; it does not delete content from Swarm.

## Operate or contribute

- [Operator guide](docs/OPERATORS.md): deployments, services, profiles, Bee access,
  website hosting and storage renewal.
- [Contributor guide](CONTRIBUTING.md): repository layout and development workflow.
- [Architecture](docs/ARCHITECTURE.md): how the applications, contracts and metadata fit.
- [Protocol reference](specs/protocol.md): exact voting, timing and settlement rules.
- [Metadata format](docs/METADATA.md): the format shared by publishing and discovery.

## Feedback

Use [GitHub Issues](https://github.com/WILLFX/decentralized-moderation/issues) for
questions, bugs and proposals. Include the website, release or contract address,
what you tried, and what happened. Public transaction hashes can help diagnose a
transaction problem. Keep passwords, keys, private recovery files and service
credentials out of reports.
