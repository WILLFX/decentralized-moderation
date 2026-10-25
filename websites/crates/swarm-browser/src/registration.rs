/// Install one complete event subscription set or roll back every attempted
/// registration. A throwing provider may attach a handler before throwing, so
/// rollback includes the failed attempt. Failed removals retain their handlers
/// for a cleanup retry instead of dropping callbacks still referenced by JS.
pub(crate) fn install_handlers<H>(
    handlers: Vec<H>,
    mut register: impl FnMut(&H) -> bool,
    mut remove: impl FnMut(&H) -> bool,
) -> Result<Vec<H>, Vec<H>> {
    let mut attempted = Vec::new();
    for handler in handlers {
        let success = register(&handler);
        attempted.push(handler);
        if !success {
            return Err(attempted.into_iter().filter(|h| !remove(h)).collect());
        }
    }
    Ok(attempted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn registration_that_attaches_then_throws_is_also_rolled_back() {
        let active = RefCell::new(Vec::new());
        let result = install_handlers(
            vec![1, 2, 3],
            |h| {
                active.borrow_mut().push(*h);
                *h != 2
            },
            |h| {
                active.borrow_mut().retain(|v| v != h);
                true
            },
        );
        assert!(result.unwrap_err().is_empty());
        assert!(active.borrow().is_empty());
    }

    #[test]
    fn failed_cleanup_retains_the_live_handler_for_a_later_retry() {
        let retained = install_handlers(vec![1, 2, 3], |h| *h != 2, |h| *h != 1).unwrap_err();
        assert_eq!(retained, vec![1]);
        let active = install_handlers(vec![1, 2, 3], |_| true, |_| true).unwrap();
        assert_eq!(active, vec![1, 2, 3]);
    }
}
