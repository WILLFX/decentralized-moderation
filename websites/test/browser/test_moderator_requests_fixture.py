"""Observer checks: no browser, key, extension or remote chain is involved."""
import unittest
from serve_moderator_requests import RequestsModel
from serve_moderator_timing import TimingModel
import serve_moderator as base


class RequestFixtureTests(unittest.TestCase):
    def model(self):
        model = RequestsModel(base.ROOT / 'dist' / 'moderator')
        tx = {'from': model.accounts['alpha'], 'to': model.addresses['token'],
              'chainId': '0x27d8', 'value': '0x0', 'nonce': '0x9',
              'data': base.digest(b'approve(address,uint256)')[:10] + model.addresses['stakes'][2:].zfill(64) + f'{10:064x}'}
        return model, ['alpha', tx]

    def test_unknown_response_keeps_mined_transaction(self):
        model, params = self.model()
        boundary = int(model.rpc('eth_blockNumber', []), 16)
        self.assertEqual(model.rpc('eth_getTransactionCount', [params[1]['from'], 'pending']), '0x9')
        model.control({'command': 'lose-next-response'})
        with self.assertRaises(ValueError):
            model.handle_wallet('eth_sendTransaction', params)
        h = model.sends[-1]['hash']
        tx = model.rpc('eth_getTransactionByHash', [h])
        self.assertEqual(tx['nonce'], '0x9')
        self.assertGreater(int(tx['blockNumber'], 16), boundary)
        self.assertEqual(len(model.sends), 1)

    def test_finality_lags_then_advances(self):
        model, params = self.model()
        h = model.handle_wallet('eth_sendTransaction', params)
        height = int(model.receipts[h]['blockNumber'], 16)
        self.assertLess(int(model.finalized['number'], 16), height)
        model.control({'command': 'advance-finality'})
        self.assertGreaterEqual(int(model.finalized['number'], 16), height)

    def test_explicit_rejection_does_not_send(self):
        model, params = self.model()
        model.control({'command': 'reject-next'})
        with self.assertRaises(ValueError) as caught:
            model.handle_wallet('eth_sendTransaction', params)
        self.assertEqual(caught.exception.code, 4001)
        self.assertEqual(model.sends, [])

    def test_wrong_candidate_has_different_nonce(self):
        model, params = self.model()
        h = model.handle_wallet('eth_sendTransaction', params)
        wrong = model.control({'command': 'wrong-transaction'})['hash']
        self.assertNotEqual(model.transactions[wrong]['nonce'], model.transactions[h]['nonce'])

    def test_speedup_keeps_original_transaction_and_exact_payload(self):
        model, params = self.model()
        original = model.handle_wallet('eth_sendTransaction', params)
        replacement = model.control({'command': 'speed-up'})['hash']
        self.assertEqual(model.transactions[original]['nonce'], model.transactions[replacement]['nonce'])
        self.assertEqual(model.transactions[original]['input'], model.transactions[replacement]['input'])
        self.assertIsNone(model.receipts[original])
        self.assertEqual(len(model.sends), 1)

    def test_cancellation_is_same_nonce_and_leaves_original_payload_available(self):
        model, params = self.model()
        original = model.handle_wallet('eth_sendTransaction', params)
        cancellation = model.control({'command': 'cancel'})['hash']
        tx = model.transactions[cancellation]
        self.assertEqual(tx['nonce'], model.transactions[original]['nonce'])
        self.assertEqual(tx['from'], tx['to'])
        self.assertEqual(tx['input'], '0x')
        self.assertEqual(tx['value'], '0x0')
        self.assertEqual(model.transactions[original]['input'], params[1]['data'])

    def test_timing_hook_changes_finalized_evidence_after_the_first_guard_read(self):
        cls = type('RequestsTimingFixture', (RequestsModel, TimingModel), {})
        model = cls(base.ROOT / 'dist' / 'moderator')
        model.control({'mode': 'reveal'})
        model.control({'command': 'wallet-boundary', 'mode': 'finality-lag'})
        model.rpc('eth_getBlockByNumber', ['finalized', False])
        model.handle_wallet('eth_accounts', ['alpha'])
        self.assertEqual(model.mode, 'finality-lag')
        self.assertEqual(model.boundaries[-1]['finalizedReadsBeforeWalletChange'], 1)
        self.assertEqual(model.sends, [])


if __name__ == '__main__':
    unittest.main()
