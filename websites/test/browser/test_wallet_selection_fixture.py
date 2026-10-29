"""Check the isolated wallet observer before using it for browser acceptance."""
from concurrent.futures import ThreadPoolExecutor
import unittest

from serve_moderator import Model, ROOT, digest
from serve_publisher import PublisherModel
from serve_wallet_selection import SelectionModelMixin


class ModeratorSelection(SelectionModelMixin, Model):
    role = "moderator"


class PublisherSelection(SelectionModelMixin, PublisherModel):
    role = "publisher"


class WalletSelectionFixtureTests(unittest.TestCase):
    def setUp(self):
        self.model = ModeratorSelection(ROOT / "dist/moderator")

    def approval(self, model, provider="alpha"):
        spender = model.addresses["stakes" if model.role == "moderator" else "moderation"]
        amount = 10 if model.role == "moderator" else model.minimum
        return {
            "from": model.accounts[provider], "chainId": "0x27d8", "value": "0x0",
            "to": model.addresses["token"],
            "data": digest(b"approve(address,uint256)")[:10] + spender[2:].zfill(64) + f"{amount:064x}",
        }

    def test_initial_state_has_no_account_access_or_sends(self):
        self.assertEqual(self.model.status()["selectionCalls"], [])
        self.assertEqual(self.model.sends, [])

    def test_providers_return_distinct_accounts(self):
        for provider in ["alpha", "beta"]:
            self.assertEqual(self.model.handle_wallet("eth_requestAccounts", [provider]), [self.model.accounts[provider]])
        self.assertNotEqual(self.model.accounts["alpha"], self.model.accounts["beta"])

    def test_same_account_does_not_erase_provider_identity(self):
        class SameAccountSelection(ModeratorSelection):
            same_account = True
        model = SameAccountSelection(ROOT / "dist/moderator")
        self.assertEqual(model.handle_wallet("eth_accounts", ["alpha"]), model.handle_wallet("eth_accounts", ["beta"]))
        self.assertEqual([call["provider"] for call in model.selection_calls], ["alpha", "beta"])

    def test_unknown_provider_cannot_receive_requests(self):
        with self.assertRaises(ValueError):
            self.model.handle_wallet("eth_accounts", ["unregistered"])
        self.assertEqual(self.model.selection_calls, [])

    def test_request_cannot_change_original_sender(self):
        tx = self.approval(self.model, "beta")
        with self.assertRaises(ValueError):
            self.model.handle_wallet("eth_sendTransaction", ["alpha", tx])
        self.assertEqual(self.model.sends, [])

    def test_exact_stake_approval_keeps_provider_identity(self):
        value = self.model.handle_wallet("eth_sendTransaction", ["alpha", self.approval(self.model)])
        self.assertEqual(self.model.sends[0]["provider"], "alpha")
        self.assertEqual(self.model.receipts[value]["status"], "0x1")

    def test_changed_chain_value_destination_or_amount_is_rejected(self):
        mutations = [
            {"chainId": "0x1"}, {"value": "0x1"},
            {"to": self.model.addresses["moderation"]}, {"data": "0x095ea7b3" + "00" * 64},
        ]
        for changes in mutations:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.model.handle_wallet("eth_sendTransaction", ["alpha", {**self.approval(self.model), **changes}])
        self.assertEqual(self.model.sends, [])

    def test_held_send_keeps_observer_available_and_does_not_send_early(self):
        self.model.control({"command": "hold-selection-send"})
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.model.handle_wallet, "eth_sendTransaction", ["alpha", self.approval(self.model)])
            try:
                self.assertTrue(self.model.waiting.wait(1))
                self.assertTrue(self.model.status()["sendWaiting"])
                self.assertEqual(self.model.sends, [])
            finally:
                self.model.control({"command": "release-selection-send"})
            self.assertTrue(pending.result(timeout=2).startswith("0x"))
        self.assertEqual([s["provider"] for s in self.model.sends], ["alpha"])

    def test_publisher_approval_checks_its_own_spender_and_retains_nonce(self):
        model = PublisherSelection(ROOT / "dist/publisher")
        value = model.handle_wallet("eth_sendTransaction", ["beta", self.approval(model, "beta")])
        self.assertEqual(model.transactions[value]["from"], model.accounts["beta"])
        self.assertEqual(model.transactions[value]["nonce"], "0x9")
        self.assertEqual(model.sends[0]["provider"], "beta")

    def test_observer_ack_is_not_account_access(self):
        queued = self.model.control({"command": "selection-event", "event": {"kind": "observe"}})
        self.model.handle_wallet("fixture_ack", [{"seq": queued["queued"], "listeners": {}}])
        self.assertEqual(self.model.acks[0]["seq"], 1)
        self.assertEqual(self.model.selection_calls, [])


if __name__ == "__main__":
    unittest.main()
