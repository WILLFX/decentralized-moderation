# Local tool files

This directory holds the ignored local cache, native executable and current
owned-environment inputs used by local tools. No operator state is included in Git.

`node tools/local-session/preflight.mjs` checks Docker and retrieves the fixed Bee
factory artifact. Metadata and bytes must match the shared version, URL and hash.
The command does not start containers, deploy contracts or publish websites.

`bash websites/scripts/build-checkpoint.sh` builds and tests native checkpoint
processing and installs it under ignored .tools/. It needs no saved checkpoint.

The local uploader requires an existing owned environment and its current records.
Environment startup and profile generation are separate operator work, not supplied
by a saved example run. Actual current/, run data, credentials and downloaded
artifacts stay local.
