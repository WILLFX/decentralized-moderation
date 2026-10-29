# Publisher website

A separate Rust/Wasm publisher with five workspaces: Editor, Review & submit,
My publications, Source & wallet, and Saved requests. Navigation is presentation
state; it cannot authorize a send or restore invalidated readiness.

## Edit and review

Write and save authoring text before choosing a source or wallet. Choose a local
raw file or an existing reference. Selecting a file uploads nothing. The built-in
uploader publishes unencrypted raw bytes up to 256 KiB, uses Bee postage and
verifies readback. Larger files/collections use an external uploader and separate
inspection; this form selects no inner collection path or authenticates all those
bytes. Own-Bee access settings stay separate from deployment identity.

Review publication validates the fields and builds exact metadata. The review
shows that immutable document's descriptive fields, normalization changes, content
inspection, account, chain, token, spender and selected fee. Full metadata and exact
base-unit values remain inspectable. Editing keeps text but invalidates affected
content/metadata checks. Returning between views alone does not require retyping.

Pinned guidelines, content inspection and metadata upload are separate guarded
steps. A sufficient allowance skips approval only when no uncertain approval
blocks the context. Approval grants exact spending permission; submission pays
the moderation fee. Native value is zero and wallet gas is separate. Every send
still runs the original fresh deployment, wallet, journal and amount checks.

## Pending requests and return

While a wallet request is open, its original intent stays visible across views and
defining fields stay locked. Reading/navigation cannot replace it with a later
draft. A late response does not pull the user back from a workspace they selected.
A recorded hash is not a checked receipt. Known terminal records stay in Saved
requests rather than remaining as a global pending banner.

My publications reads account/deployment-scoped saved submissions. Receipt checks
bind the actual case identity; refreshing a saved publication repeats that binding
before current case, membership and refund reads. A verified submission is not
moderation approval, and a final approval is not permanent membership. A refund is
offered only from verified owed evidence and pays the original submitter.

Recovery starts from the affected record, including a request with no returned
hash. It preserves original/replacement evidence and unknown-send guards. No route
resends automatically or clears an uncertain request. Archive/capacity controls
remain under Saved requests and retain their saved-file verification requirements.

Authoring text survives reload in this tab; save a draft file before closing the
tab/browser. Restoring text does not restore profile, wallet, inspection, upload
or review readiness. Profiles and private Bee access stay in memory. Local history
and its storage limits are described in `../../../docs/PUBLISHER_HISTORY.md`.

## Browser checks and capabilities

The fixture in `../../test/browser/README.md` serves the production Wasm with an
isolated synthetic wallet. Prepared states test execution and recovery; they do
not prove actual extension-wallet behavior, human comprehension or chain history.
Responsive layouts support narrow/wide screens, portrait/landscape, scrolling,
keyboard focus and enlarged text. Physical-device, actual browser zoom and
assistive-technology acceptance remain separate checks. Devices without an
injected wallet can still write/save a draft and continue in a supported browser.
