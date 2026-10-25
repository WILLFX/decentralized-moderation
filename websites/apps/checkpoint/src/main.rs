fn main() {
    if swarm_checkpoint::run().is_err() {
        // State, paths, RPC responses and user data must never enter diagnostics.
        eprintln!("NATIVE_CHECKPOINT_FAILED");
        std::process::exit(1);
    }
}
