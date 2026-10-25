// Application behavior is implemented in Rust.
import init from './pkg/swarm_publisher.js';
init().catch(() => { document.getElementById('boot').textContent = 'The Rust publisher could not load. Check its Wasm and generated bindings.'; });
