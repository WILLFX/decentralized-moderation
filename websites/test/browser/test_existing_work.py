"""Check the synthetic existing-work checkpoints and their send boundaries."""
import unittest
from serve_existing_work import PublisherModel, ModeratorModel, ReaderModel
from serve_moderator import ROOT, digest


class ExistingWorkTests(unittest.TestCase):
    def test_profiles_preserve_identity_and_do_not_supply_upload_access(self):
        for role, cls in [('publisher', PublisherModel), ('moderator', ModeratorModel), ('search', ReaderModel)]:
            m = cls(ROOT / 'dist' / role)
            p = m.profile('http://127.0.0.1:7001', 'http://localhost:7002')
            self.assertEqual(p['purpose'], 'existingWork')
            self.assertNotIn('upload', p)
            self.assertEqual(p['deployment']['moderation']['address'], m.addresses['moderation'])

    def test_publisher_has_an_existing_refund(self):
        m = PublisherModel(ROOT / 'dist/publisher')
        self.assertEqual(m.cases[1]['phase'], 6)
        self.assertEqual(m.refunds[1], m.minimum)
        self.assertEqual(m.sends, [])

    def test_withdrawal_requires_closed_obligations_and_no_freeze(self):
        m = ModeratorModel(ROOT / 'dist/moderator')
        tx = {'from': m.account, 'to': m.addresses['stakes'], 'chainId': '0x27d8',
              'value': '0x0', 'nonce': '0x9', 'data': digest(b'withdraw()')[:10]}
        with self.assertRaises(ValueError): m.wallet('eth_sendTransaction', [tx])
        m.control({'command': 'prepare-completion'})
        with self.assertRaises(ValueError): m.wallet('eth_sendTransaction', [tx])
        m.votes[1][4] = 1
        m.frozen_until = m.clock + 100
        with self.assertRaises(ValueError): m.wallet('eth_sendTransaction', [tx])
        m.frozen_until = 0
        h = m.wallet('eth_sendTransaction', [tx])
        self.assertFalse(m.staked)
        self.assertEqual(m.transactions[h]['nonce'], '0x9')
        self.assertEqual(m.next_nonce, 10)
        with self.assertRaises(ValueError): m.wallet('eth_sendTransaction', [tx])


if __name__ == '__main__': unittest.main()
