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

```sh
(cd websites && bash scripts/bootstrap.sh)
bash websites/scripts/build.sh
```

Bootstrap requires rustup and installs Rust 1.96.0 and wasm-bindgen 0.2.118. It is
unnecessary when the pinned tools are already present. Use `build.sh publisher`,
`moderator` or `search` for one role. See [build and test](../docs/BUILD_AND_TEST.md).

The three `dist/` collections have seven public assets each. Packaging refuses
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
