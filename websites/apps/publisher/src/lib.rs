use wasm_bindgen::prelude::*;
#[wasm_bindgen(start)]
pub fn main() -> Result<(), JsValue> {
    swarm_browser::start_publisher()
}
