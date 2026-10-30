# Native checkpoint processor

`swarm-checkpoint` is a native Rust tool for local-chain checkpoint files. It is
not a participant website and must not enter a public website collection.

The commands select and check saved checkpoints, prepare an Anvil startup file,
inspect a streamed RPC dump and atomically package a checkpoint. Callers supply
the run, deployment and fingerprint context. These are local file operations,
not a way to alter public-network time or prove blockchain consensus.

Processing checks compressed-state SHA-256, gzip CRC, truncation, required history
sections and agreement between a header and its declared fingerprint. Conflicting
highest heads or a corrupt newest save are reported. Private temporary files,
readback and atomic replacement preserve an earlier save on write failure.

Compressed hex is bounded to 512 MiB, checkpoint JSON to 513 MiB and expanded JSON
to 1 GiB. History is streamed rather than retained as a complete decoded graph.

Build from the repository root:

```sh
bash websites/scripts/build-checkpoint.sh
```

The binary is installed under ignored `tools/local-session/.tools/`. Building it
does not require or replace an existing saved session. Keep actual checkpoint
files, runtime configuration and recovery material outside public release assets.
