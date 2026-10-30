# Swarm Publish

The publisher website prepares content and metadata, reviews fees, submits listing
cases and follows their progress. It has Editor, Review & submit, My publications,
Source & wallet, and Saved requests workspaces.

Use the [participant guide](../../../docs/PARTICIPANTS.md#publish-content) for the
workflow and the [release entry](../../../docs/releases/TESTNET_MVP.md) for the
published build and public profiles. [Publisher setup](../../../docs/PUBLISHER_SETUP.md)
explains profile distribution; [history](../../../docs/PUBLISHER_HISTORY.md) explains
saved requests and archives.

## Implementation

The entry crate loads `swarm-browser`'s publisher application. Its modules separate
authoring, content access, setup, metadata validation, review/payment progress,
publication follow-up and public transaction recovery. Shared metadata and calldata
rules live in `swarm-core`.

A local raw-file upload is limited to 256 KiB and is verified before the form adopts
its reference. Collection mode opens a Bee collection through a separate origin.
The selected content access mode must match the reviewer/reader profiles. Drafts
preserve text, not send permission or current evidence. Approval and submission
remain separate wallet actions.

Pending requests retain their original context. History reconciliation uses the
actual transaction and canonical receipt before resolving a request. Archives
retain uncertain records and exact backup requirements.

Build with `bash websites/scripts/build.sh publisher` from the repository root.
[Browser fixture tooling](../../test/browser/README.md) is for development.
