# Swarm Search

The reader queries approved topic listings, authenticates metadata and opens
content separately. It does not connect a wallet or sign transactions.

Use the [participant guide](../../../docs/PARTICIPANTS.md#discover-content) for the
workflow and the [release entry](../../../docs/releases/TESTNET_MVP.md) for the
published build and public profiles.

## Source and results

Reader accepts a local profile or an explicitly fetched public profile URL plus
its expected Keccak-256 fingerprint. A link may prefill
`#profile=<encoded URL>&fingerprint=<0x hash>`; it does not fetch or accept the
profile automatically. Choose **Use this source** after reviewing it. Profile and
query state remain in the current tab, not a permanent deployment preference.

Search applies a normalized topic or category query and keeps the applied query
separate from later edits. Source-block paging and provenance collection are
bounded. Listing origins must bind uniquely to finalized LIST cases, and metadata
must match its Swarm reference, schema and ordered topic keys.

**Check current listing** rereads membership, deployment and metadata at a fresh
canonical block. Its content link records the check time. Content opens on another
origin without an opener/referrer, using the profile's `contentPath` route. It
cannot infer a raw-versus-collection access mode from a metadata MIME type.

## Optional category files

A local category file describes topic groupings; it does not create approvals or
change the contract's topics. Version 1 uses:

```json
{"schemaVersion":1,"categories":[{"id":"biology","label":"Biology","topicKey":"<32-byte 0x topic key>","parents":[]}]}
```

Replace the placeholder with the actual topic key. A group can expand through its
children. **Every group** means an intersection of selected groups; **any group**
means their union. The preview shows the expanded query before execution.

Limits are 256 category nodes, 1,024 edges, 5 selected terms, 16 queried topics,
500 collected category rows and 10,000 provenance bindings. Profile paging allows
1–20 display rows and a scan batch of 1–1,000 cases. Incomplete evidence does not
produce a content-opening action.

Build with `bash websites/scripts/build.sh search` from the repository root.
[Browser fixture tooling](../../test/browser/README.md) is for development.
