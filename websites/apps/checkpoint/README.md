# Native checkpoint processing

swarm-checkpoint validates and processes local-chain checkpoint files. It is a
native Rust executable, separate from browser Wasm. It never enters a public site.

Commands select and verify checkpoints, prepare an Anvil startup file, inspect a
streamed RPC dump, and atomically package a checkpoint. Callers supply the declared
run/deployment/fingerprint context. File consistency checks are not independent
blockchain consensus verification.

Validation covers compressed-state SHA-256, gzip CRC, truncation, required history
sections, and agreement between the exported header and its declared fingerprint.
Conflicting highest heads or corrupt newest saves fail explicitly. Writes use
private temporary files, file sync, readback verification and atomic replacement;
a failed verification cannot replace the prior checkpoint.

Compressed hex is bounded at 512 MiB, checkpoint JSON at 513 MiB and expanded JSON
at 1 GiB. History is streamed rather than retained as decoded object graphs.
These are bounded-memory limits, not a claim of constant memory for all input.

From the repository root:

```bash
bash websites/scripts/build-checkpoint.sh
```

The binary is installed under tools/local-session/.tools. Building/testing does
not require a personal configuration, start a chain or change a saved session.
