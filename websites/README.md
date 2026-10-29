# Rust/Wasm websites

The moderator, publisher and search applications are Rust/Wasm and are packaged
as three separate static Swarm collections. Shared protocol and metadata code is
in crates/swarm-core; browser, wallet, encrypted-vault and site workflows are in
crates/swarm-browser.

```bash
(cd websites && bash scripts/bootstrap.sh)  # only when the tools are absent
(cd websites && bash scripts/build.sh)
bash websites/scripts/build-checkpoint.sh
```

See ../docs/BUILD_AND_TEST.md for the complete checks. Rust 1.96.0, wasm-bindgen
0.2.118 and Cargo.lock are retained. WASM_BINDGEN can select an existing pinned CLI.
The recovery tests use synthetic format-v1 data and Rust encryption/decryption.
No test exports, configuration, keys or recovery files enter a public package.

For trusted profile links, per-user Bee settings and the content-to-metadata
workflow, see [publisher setup](../docs/PUBLISHER_SETUP.md). The setup-link helper
prints a URL for a reviewed public profile; it does not publish the file or choose
an operator on the user's behalf.

Local upload is an explicit separate operation:

```bash
node websites/scripts/publish-local.mjs moderator
node websites/scripts/publish-local.mjs publisher
node websites/scripts/publish-local.mjs search
```

The uploader requires the current configuration of an already running owned Bee
environment and verifies Docker ownership, bytes, references and browser media
types. LOCAL_BEE_SESSION_ROOT can select its local record directory; the default
is tools/local-session. No operator configuration is included in Git.

apps/checkpoint is a native file-processing executable, not browser code. It is
built separately and never uploaded with a website. See ../docs/STATUS.md for
remaining validation and deployment work.


### Browser wallet connection

Publisher and moderator use EIP-6963 discovery to offer the browser's announced
wallets. Choose a wallet, then connect the intended account on the profile's
chain. Discovery requests no account access or signatures. When no wallets announce, a single injected window.ethereum provider remains
available as a legacy browser-wallet fallback.

Each page binds requests and event monitoring to the selected provider object.
New announcements or a changed browser default do not switch an active session.
An explicit switch clears old readiness and must clean up the previous event
subscriptions before connecting again. Wallet choice is not persisted across
reloads. Names and identifiers are supplied by wallets, not authenticated by the
application. WalletConnect/QR pairing is not implemented.
