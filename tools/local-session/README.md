# Owned local-environment tooling

This directory is the default location for ignored inputs and generated files used
by the repository's local Bee-factory tools. It contains no shared operator state.
Use a current record from an environment you own, not another installation's save.

`node tools/local-session/preflight.mjs` checks Docker and obtains the pinned
Bee-factory artifact. It checks its expected version and bytes before use. This
command does not start containers, deploy contracts or upload websites.

`bash websites/scripts/build-checkpoint.sh` builds the native checkpoint processor
under `.tools/`. It does not need a saved checkpoint. The
[local uploader](../../websites/README.md#owned-local-environment-upload-tool) expects
an already running owned environment and its current records. Environment startup
and service configuration are separate operator responsibilities.

Keep generated executables, runtime records, credentials, node data and saves local.
Use the [operator guide](../../docs/OPERATORS.md) for an independently operated
public-testnet Bee or shared service.
