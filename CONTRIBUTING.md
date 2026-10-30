# Contributing

Use [GitHub Issues](https://github.com/WILLFX/decentralized-moderation/issues) to
report a bug, ask a question or propose a change. Describe the user action or
protocol behavior involved before proposing an implementation.

## Read the project

- [Architecture](docs/ARCHITECTURE.md): contracts, websites and data flow.
- [Protocol](specs/protocol.md): the current rules and their on-chain interfaces.
- [Metadata](docs/METADATA.md): fields, references and topic normalization.
- [Operator guide](docs/OPERATORS.md): deployment and service configuration.
- [Build and test](docs/BUILD_AND_TEST.md): pinned tools and local commands.

The [testnet release](docs/releases/TESTNET_MVP.md) identifies the source used for
the published applications. Later documentation changes do not change those builds
or the deployed contracts.

## Work on a change

1. Use a branch and keep the change focused. Explain its effect on participants,
   operators or protocol state.
2. Put shared parsing and protocol calculations in `swarm-core`, browser work in
   `swarm-browser`, and custody/state transitions in the contracts. Keep secrets
   outside public request history.
3. Run the checks relevant to the change. Run the repository check before proposing
   a complete release change. Use synthetic data in fixtures and test files.
4. Open a pull request with a clear description, reproduction or example, and the
   commands you ran. Identify protocol or profile compatibility changes explicitly.

A protocol change must keep the specification and clients consistent. Review
settlement, refunds, phase events and index membership together. A reveal change
must preserve both checks before disclosure. Unknown transaction results must
remain guarded; missing evidence is not permission to resend or replace a vote.

The deployed guidelines are an exact-byte artifact. Do not edit the root
`MODERATION_GUIDELINES.md` or its packaged copies as a documentation cleanup.
Changing that text requires a new guidelines hash and deployment identity.

## Keep local material out of contributions

Do not commit wallet keys, credentials, node data, private RPC settings, postage
operator state, drafts, private recovery files or working reports. The public
profiles in `deployments/chiado/` contain only release configuration and optional
local-Bee connection presets. Preserve that boundary when adding examples.

For a security-sensitive report, do not include working secrets or an exploit
against another person's account. Start with a minimal description in the issue
tracker and arrange any sensitive exchange with the maintainer.
