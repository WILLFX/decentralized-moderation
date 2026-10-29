# Rust search website

A separate read-only website. Search uses the profile's runtime pins, contract
links and guideline identity. It does not request a wallet, sign transactions or
store private recovery data.

## Source and query

A reader can choose a local search profile, or read a public profile URL with an
expected Keccak-256 fingerprint. A supplied link can prefill these fields using
`#profile=<encoded URL>&fingerprint=<0x hash>`. It cannot fetch or activate the
profile automatically. The reader reviews the chain, contracts, pins, gateways
and fingerprint before choosing **Use this source**. Public URLs reject query
credentials. Local endpoint query values are withheld from the displayed summary.
A fingerprint authenticates supplied bytes, not the operator's identity.

The profile and category graph stay in the current tab. Reload requires setup
again. Content opens in a separate tab, leaving the query and position available.
No deployment or operator is hardcoded into the application.

Enter and **Search topic** apply the same normalized complete-topic query. Pending
edits stay separate from the applied query shown above results. Changing a source
clears earlier evidence. A fresh-block retry repeats the applied query, including
its category plan, rather than applying unsent edits.

## Results and opening

The source block remains canonical while the interface scans finalized LIST cases
in bounded batches. Current registry pages at that source are authoritative.
Continue collecting and display pagination are separate actions. Exact Previous
and Next reread pages at the original block; category pages use the completed,
bounded collection. Counts state whether they describe registry listings or
collected category items. A replaced source blocks navigation/opening and offers
a fresh search. Failed reads and cancellation preserve completed progress.

A complete, unique LIST binding permits metadata authentication. Raw bytes must
match their Swarm BMT reference before UTF-8, schema and ordered-topic checks.
Only authenticated title, description, type, language, topics and publisher-supplied
source appear as descriptive result data. Full provenance remains inspectable.
Incomplete, ambiguous and capped results do not expose a content action.

**Check current listing** checks deployment identity, compatible LIST binding,
current membership and metadata again at a fresh canonical block. It updates only
the affected card, retains keyboard focus and labels the resulting link with its
check time. Content then opens through a different origin with no opener or
referrer. Metadata failure removes the affected link. Membership is a timestamped
observation, not a continuing lease or a safety certificate. The supplied RPC
remains trusted; these checks do not independently prove blockchain consensus.

## Categories and limits

Local category JSON uses the existing v1 schema:

```json
{"schemaVersion":1,"categories":[{"id":"biology","label":"Biology","topicKey":"0x...32-byte topic key...","parents":[]}]}
```

Choose up to five labeled groups. Parent relationships and an expansion preview
appear before applying the query. A group matches any of its explicit topic keys;
**every group** requires one match within each selected group, while **any group**
requires one match across the selected groups. A graph creates no moderation
approval. Limits remain 256 nodes, 1024 edges, 5 terms, 16 queried topics, 500
collected category rows and 10,000 provenance bindings. Bounds remain explicit
and incomplete results remain non-actionable.

The layout reflows without fixed-height work areas for narrow and wide screens.
Fields, metadata, evidence, actions and focus indicators must also be checked at
portrait/landscape sizes and with enlarged text/zoom. Prepared browser tests are
described in `../../test/browser/README.md`; they do not establish physical-device,
assistive-technology or first-time-human acceptance.

Build/package tooling is shared by the three separate Rust websites. Private
profiles, local receipts, fixtures and test exports are excluded from collections.
