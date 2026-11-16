# Rust/Wasm websites

Three separate static applications implement publishing, moderation and discovery:

| Application | Entry source | Participant guide |
| --- | --- | --- |
| Swarm Publish | `apps/publisher` | [Publish](../docs/PARTICIPANTS.md#publish-content) |
| Swarm Review | `apps/moderator` | [Moderate](../docs/PARTICIPANTS.md#moderate-content) |
| Swarm Search | `apps/search` | [Discover](../docs/PARTICIPANTS.md#discover-content) |

The [release entry](../docs/releases/TESTNET_MVP.md) has published references and
public profiles. An application reads its selected deployment/services from a
profile; no participant account, deployment or personal Bee is built into it.

## Development layout

`crates/swarm-core` contains profile/metadata parsing, ABI helpers and protocol
calculations. `crates/swarm-browser` contains browser I/O, views, wallet sessions,
request history and private-vote storage. Generated JavaScript loads the Rust Wasm
bindings. Node scripts package artifacts and support explicit development tools.

Within `swarm-browser/src`, `moderator/`, `publisher/` and `search/` own each
application's workflow and views. Moderator also owns private vote recovery.
Wallet discovery, transport, version verification and storage coordination remain
shared at the crate root. Public application entry points are re-exported there.

`assets/loader.js` supplies startup code for all three websites. Packaging fills
in each role's asset names and title. The repository-root `MODERATION_GUIDELINES.md`
is the single guideline source; packaging copies its exact bytes into each collection.
`assets/common.css` holds shared style sections. Each role's `style.css` selects
their positions with `/* @shared name */` markers, which packaging expands inline
without changing rule order or adding stylesheet requests.

```sh
(cd websites && bash scripts/bootstrap.sh)
bash websites/scripts/build.sh
```

Bootstrap requires rustup and installs Rust 1.96.0 and wasm-bindgen 0.2.118. It is
unnecessary when the pinned tools are already present. Use `build.sh publisher`,
`moderator` or `search` for one role. See [build and test](../docs/BUILD_AND_TEST.md).

Each interface builds into its own ignored `static/` directory:

```text
websites/apps/publisher/static/
websites/apps/moderator/static/
websites/apps/search/static/
```

Each directory contains `index.html`, `swarm_<role>.js`,
`swarm_<role>_bg.wasm.gz`, `MODERATION_GUIDELINES.md` and `asset-hashes.json`.
The page inlines its CSS and startup script under content-security-policy hashes.
It downloads the JavaScript wrapper and gzip Wasm in parallel, then decompresses
the Wasm as the browser compiles it. Edit the role's source files, rebuild, and
serve or upload the resulting `static/` directory.

The published [release manifest](../deployments/chiado/manifest.json) lists the
exact asset paths and hashes in the released collections. Packaging refuses
extra files; profiles, private state, test providers and recovery exports are not
website assets. `apps/checkpoint` is a separate native executable.

## Browser connections

Publisher and Moderator discover compatible browser wallets through EIP-6963,
the Ethereum convention for announcing installed providers. Requests use the
selected provider's EIP-1193 interface. When no wallet announces, a single injected
`window.ethereum` provider can serve as a fallback. The selected provider stays
bound to the page's current session; a later announcement cannot silently replace
it. Reload requires wallet selection/connection again. Reader has no signing path.

Profile and Bee configuration are described in the [operator guide](../docs/OPERATORS.md).
Existing public setup links and per-user publisher settings are described in
[publisher setup](../docs/PUBLISHER_SETUP.md).

## Owned local-environment upload tool

```sh
node websites/scripts/publish-local.mjs moderator
node websites/scripts/publish-local.mjs publisher
node websites/scripts/publish-local.mjs search
```

This tool expects current records for an already running owned local Bee-factory
environment. It checks environment ownership and the collection it uploads.
`LOCAL_BEE_SESSION_ROOT` selects its local record directory; the default is
`tools/local-session`. Do not copy another installation's state into it.

For a separately operated public-testnet Bee, use that node's normal collection
uploader or API. The local tool does not install a public Bee, deploy contracts or
create service configuration.
