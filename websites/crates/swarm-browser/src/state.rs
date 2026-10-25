/// Events from the wallet are invalidation signals. A duplicate account event
/// must not turn an already connected account into a reconnect loop.
#[derive(Default, Debug)]
pub struct WalletState {
    pub account: Option<String>,
    pub chain: Option<u64>,
    pub connected: bool,
    pub epoch: u64,
}

impl WalletState {
    pub fn account_changed(&mut self, account: Option<String>) -> bool {
        let normalized = account.map(|a| a.to_lowercase());
        if normalized == self.account {
            return false;
        }
        self.account = normalized;
        self.invalidate();
        true
    }

    pub fn chain_changed(&mut self, chain: Option<u64>) -> bool {
        if chain == self.chain {
            return false;
        }
        self.chain = chain;
        self.invalidate();
        true
    }

    pub fn invalidate(&mut self) {
        self.connected = false;
        self.epoch = self.epoch.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_same_account_events_do_not_disconnect() {
        let mut state = WalletState::default();
        state.account_changed(Some("0xAB".into()));
        state.connected = true;
        let epoch = state.epoch;
        assert!(!state.account_changed(Some("0xab".into())));
        assert!(state.connected);
        assert_eq!(state.epoch, epoch);
    }

    #[test]
    fn actual_account_or_chain_changes_invalidate_pending_results() {
        let mut state = WalletState::default();
        state.account_changed(Some("0xaa".into()));
        state.chain_changed(Some(10200));
        state.connected = true;
        let pending_epoch = state.epoch;
        state.account_changed(Some("0xbb".into()));
        assert!(!state.connected);
        assert_ne!(pending_epoch, state.epoch);
        state.connected = true;
        state.chain_changed(Some(100));
        assert!(!state.connected);
    }

    #[test]
    fn wallet_disconnect_clears_connection_even_with_same_account() {
        let mut state = WalletState {
            connected: true,
            ..Default::default()
        };
        state.invalidate();
        assert!(!state.connected);
        assert_eq!(state.epoch, 1);
    }
}
