"""Check the isolated wallet observer before using it for browser acceptance."""
from concurrent.futures import ThreadPoolExecutor
import unittest
from fixture_unit_support import model_assets

from serve_moderator import Model, digest
from serve_publisher import PublisherModel
from serve_wallet_selection import SelectionModelMixin


class ModeratorSelection(SelectionModelMixin, Model):
    role = "moderator"


class PublisherSelection(SelectionModelMixin, PublisherModel):
    role = "publisher"


class WalletSelectionFixtureTests(unittest.TestCase):
    def setUp(self):
        self.model = ModeratorSelection(model_assets(self))

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
        model = SameAccountSelection(model_assets(self))
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
        model = PublisherSelection(model_assets(self))
        value = model.handle_wallet("eth_sendTransaction", ["beta", self.approval(model, "beta")])
        self.assertEqual(model.transactions[value]["from"], model.accounts["beta"])
        self.assertEqual(model.transactions[value]["nonce"], "0x9")
        self.assertEqual(model.sends[0]["provider"], "beta")

    def test_observer_ack_is_not_account_access(self):
        queued = self.model.control({"command": "selection-event", "event": {"kind": "observe"}})
        self.model.handle_wallet("fixture_ack", [{"seq": queued["queued"], "listeners": {}}])
        self.assertEqual(self.model.acks[0]["seq"], 1)
        self.assertEqual(self.model.selection_calls, [])


class ProviderSourceTests(unittest.TestCase):
    def test_configuration_rejects_unknown_modes_and_non_boolean_options(self):
        from serve_wallet_selection import provider_source

        with self.assertRaisesRegex(ValueError, "Unknown synthetic wallet mode"):
            provider_source(mode="unknown")
        for option in ["authorization_event", "request_storage_faults", "observe_requests",
                       "observe_vault", "capture_recovery"]:
            for value in [None, 0, 1, "false"]:
                with self.subTest(option=option, value=value), self.assertRaisesRegex(ValueError, "boolean"):
                    provider_source(**{option: value})

    def test_server_instances_keep_distinct_provider_bytes_without_changing_default(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        import serve_moderator as base
        from serve_wallet_selection import provider_source

        servers = []

        def server(address, handler):
            self.assertEqual(address[0], "127.0.0.1")
            instance = SimpleNamespace(server_port=7000 + len(servers), handler=handler,
                                       serve_forever=Mock(), server_close=Mock(), shutdown=Mock())
            servers.append(instance)
            return instance

        original = base.WALLET
        sources = [provider_source(mode="single"), provider_source(mode="none")]
        with patch.object(base, "ThreadingHTTPServer", side_effect=server), \
             patch.object(base.threading, "Thread"), patch("builtins.print"):
            for source in sources:
                assets = model_assets(self)
                (assets / "asset-hashes.json").write_text("{}", encoding="utf8")
                args = SimpleNamespace(assets=assets, output=assets / "session", port=0)
                base.serve(args, wallet_source=source)

        self.assertEqual(base.WALLET, original)
        self.assertEqual(len(servers), 4)
        for instance, source in zip(servers[::2], sources):
            handler = object.__new__(instance.handler)
            handler.server = instance
            handler.headers = {"Host": instance.expected_host}
            handler.path = "/fixture-wallet.js"
            handler.reply = Mock()
            instance.handler.do_GET(handler)
            handler.reply.assert_called_once_with(200, source, "text/javascript")


if __name__ == "__main__":
    unittest.main()
