# Browser fixture tools

These helpers serve the built Rust/Wasm applications with an isolated synthetic
provider and prepared data. They are development tools, separate from public
website collections and installation profiles.

Build the relevant application first. From the repository root:

```sh
bash websites/scripts/build.sh moderator
python3 websites/test/browser/serve_moderator.py --output websites/receipts/moderator-fixture
```

The helper prints its current URL and saves a synthetic profile and session under
the output directory. Select that profile through the application's normal Source
controls. Use the URL from the current session, not a copied port from another run.

Use a fresh browser context without a real injected wallet. The provider bootstrap
refuses an existing wallet rather than forwarding a request to it. Helpers bind
loopback and use synthetic accounts, responses and recovery data. Keep real keys
and private recovery files out of this environment.

## Helpers

| Helper | Prepared work |
| --- | --- |
| `serve_moderator.py` | Listing/removal review, private votes and follow-up |
| `serve_moderator_timing.py` | Group deadlines, legacy draw windows and stake states |
| `serve_moderator_requests.py` | Interrupted public requests and receipt reconciliation |
| `serve_challenge_intent.py` | Reviewed challenge round/outcome and exact request binding |
| `serve_outcome_recovery.py` | Original-hash caching, extended recovery and expiry |
| `serve_publisher.py` | Authoring, fee approval, submission and public history |
| `serve_publisher_expiry.py` | Publication follow-up at recovery/expiry states |
| `serve_search.py` | Topic/category queries, metadata and membership |
| `serve_wallet_selection.py` | Announced wallet providers and provider changes |

Use each helper's argument parser for its available startup options. They select
prepared states; they do not run a continuous public blockchain. In particular,
the legacy timing fixture's 250-block outcome states are separate from the released
contract's original-hash recovery through 8,191 blocks and indefinite cached draw.

## Observer controls

Helpers expose `/fixture/status` for their local state and `/fixture/control` for
supported prepared-state commands. The [observer reference](OBSERVER.md) gives
payloads and workflows for interrupted requests, replacements, cancellations,
archives and source changes. Commands vary by helper; use its dispatcher for
additional modes. Normal participant actions use the application controls.
The observer must not replace those actions by writing hidden application state.

Use synthetic passwords, salts and recovery files. Observer output should retain
public request/receipt identity without leaking a private choice before reveal.
A held request or lost response must remain uncertain until the application
reconciles it; do not repair the state by deleting its journal.

## Layout work

The Moderator viewport frame follows its available window by default. Test-only
URL options such as `?width=320&height=640` select reproducible dimensions;
`&text=200` enlarges text. Product layouts follow the browser viewport rather than
a user-selected device type. Exercise focus, scrolling and return paths using
normal controls.

The fixture unit commands are included in `scripts/check.sh`. See the repository
[build guide](../../../docs/BUILD_AND_TEST.md) for running it. Stop a helper with
Ctrl+C when finished and keep generated sessions, screenshots and local reports
outside public release material.
