// Only loads the compiled Rust application. Application behavior lives in Rust.
import init from './pkg/swarm_moderator.js';
init().catch(() => {
  document.getElementById('boot').textContent =
    'The Rust application could not load. Check that this collection includes its Wasm and generated bindings.';
});
