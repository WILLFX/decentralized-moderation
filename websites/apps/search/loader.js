// Only loads the Rust application. All search behavior lives in Rust.
import init from './pkg/swarm_search.js';
init().catch(() => { document.getElementById('boot').textContent = 'The Rust search application could not load. Check the Wasm collection assets.'; });
