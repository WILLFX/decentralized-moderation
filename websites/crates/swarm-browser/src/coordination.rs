//! Nonwaiting browser locks shared by the signing applications.
use crate::BrowserResult as Result;
use js_sys::{Function, Object, Promise, Reflect};
use std::{cell::RefCell, future::Future, rc::Rc};
use wasm_bindgen::{closure::Closure, JsCast, JsValue};
use wasm_bindgen_futures::{future_to_promise, JsFuture};

#[derive(Clone, Copy)]
pub(crate) struct Errors {
    pub unavailable: &'static str,
    pub busy: &'static str,
    pub failed: &'static str,
}

/// Run only when the lock is immediately available. The caller supplies its
/// context checks and keeps any operation-specific state inside the future.
pub(crate) async fn run_if_available<F, T>(
    name: &'static str,
    errors: Errors,
    operation: impl Fn() -> F + 'static,
) -> Result<T>
where
    F: Future<Output = T> + 'static,
    T: 'static,
{
    let navigator = Reflect::get(web_sys::window().unwrap().as_ref(), &"navigator".into())
        .map_err(|_| errors.unavailable)?;
    let locks = Reflect::get(&navigator, &"locks".into()).map_err(|_| errors.unavailable)?;
    let request = Reflect::get(&locks, &"request".into())
        .map_err(|_| errors.unavailable)?
        .dyn_into::<Function>()
        .map_err(|_| errors.unavailable)?;
    let result = Rc::new(RefCell::new(None));
    let output = result.clone();
    let callback = Closure::<dyn FnMut(JsValue) -> Promise>::new(move |lock: JsValue| {
        let pending = if lock.is_null() {
            None
        } else {
            Some(operation())
        };
        let output = output.clone();
        future_to_promise(async move {
            let result = match pending {
                Some(operation) => Ok(operation.await),
                None => Err(errors.busy),
            };
            *output.borrow_mut() = Some(result);
            Ok(JsValue::UNDEFINED)
        })
    });
    let options = Object::new();
    Reflect::set(&options, &"ifAvailable".into(), &JsValue::TRUE)
        .map_err(|_| errors.unavailable)?;
    let promise = request
        .call3(&locks, &name.into(), &options, callback.as_ref())
        .map_err(|_| errors.unavailable)?
        .dyn_into::<Promise>()
        .map_err(|_| errors.unavailable)?;
    // Keep the callback alive and await the outer promise so the lock has been
    // released before the caller resumes, including when the operation failed.
    JsFuture::from(promise).await.map_err(|_| errors.failed)?;
    let result = result.borrow_mut().take().ok_or(errors.failed)?;
    result
}
