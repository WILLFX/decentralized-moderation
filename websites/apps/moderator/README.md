# Swarm Review

The moderator website provides My work, Browse cases, Selected case, Recovery,
Stake, Source & wallet, and Transactions workspaces.

Use the [participant guide](../../../docs/PARTICIPANTS.md#moderate-content) for
staking, private choices, reveals and follow-up. The [release entry](../../../docs/releases/TESTNET_MVP.md)
contains the published build and public profiles. The [protocol](../../../specs/protocol.md)
defines selection, deadlines, challenges and settlement.

## Implementation

`swarm-browser` separates case/work presentation, private-vote workflow and public
request reconciliation. `swarm-core` supplies profile, schedule, ABI and review
calculations. Navigation cannot authorize a transaction or change its reviewed
account/deployment/case context.

Private votes use an encrypted vault with user-held verified backups. The current
payload retains earlier secrets when a provably unsent choice is changed. The
active record controls commitment; revelation matches the actual mined commitment
across retained secrets. Payload version 2 adds retained records to the version-1
encrypted envelope. Older version-1 payloads remain importable; older application
builds cannot read version-2 payloads. The 512-record bound includes retained records.

The public journal stores intent digests, nonce boundaries and receipt follow-up,
not choices or salts. It uses Web Locks for cross-tab writes and keeps uncertain
requests across reloads. Reveals reserve their journal entry before the second
unchanged disclosure guard; the successful path from that guard to the wallet
performs no added journal I/O.

Challenge requests bind the reviewed round/outcome. Recovery and expiry calls bind
the reviewed target and use runtime-authenticated capabilities. Public advancement
is available separately from private-vote work.

Build with `bash websites/scripts/build.sh moderator` from the repository root.
[Browser fixture tooling](../../test/browser/README.md) is for development.
