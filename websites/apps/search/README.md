# Rust search website

This is a separate read-only static application. It uses the existing four runtime pins, six contract links and guideline identity. It does not request a wallet or submit transactions.

Load the current search profile. Exact topics follow the publisher Unicode normalization and Keccak identity. A search keeps a canonical source block while it scans historical LIST cases in bounded batches. Registry pages remain authoritative for current listing membership at that source. Only a complete scan with a unique finalized Approve metadata binding permits metadata authentication. Ambiguous and unresolved results remain visible without a content link.

Metadata is authenticated against the raw Swarm BMT reference before UTF-8/schema/ordered-topic checks. The content action checks deployment, compatible historical binding, current registry membership and metadata again at a fresh block. Content opens through a different origin, with no opener or referrer.

Optional local category JSON uses the existing v1 schema:

```json
{"schemaVersion":1,"categories":[{"id":"biology","label":"Biology","topicKey":"0x...32-byte topic key...","parents":[]}]}
```

Choose up to five labeled category checkboxes. Rust keeps their exact IDs internally; no JSON query syntax is required. Descendant expansion and AND/OR join current explicit topic listings. A graph does not create new moderation authority. Limits remain 256 nodes, 1024 edges, 5 terms, 16 queried topics, 500 collected registry rows and 10,000 provenance bindings. The interface requires explicit continuation between bounded reads. Rows whose metadata cannot be authenticated have no open action. Retry metadata is explicit; changing profile/query or cancelling discards earlier evidence.

The supplied RPC remains trusted. Canonical checks do not independently prove consensus. The content link is a checked observation, not a permanent lease on registry membership or an assertion of safety.

Build/package/publish tooling is shared by the three separate Rust applications. This source has no private profile, secret or recovery data.
