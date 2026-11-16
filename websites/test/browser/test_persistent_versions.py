"""Prepared provider facts, not an EVM or a wallet-extension test."""
import unittest
from fixture_unit_support import model_assets
from serve_persistent_versions import ReaderModel, PublishModel, ModeratorModel, AUTHORITY, NEXT
from serve_moderator import abi, digest


def call(model, to, signature, *words):
    head = model.head if hasattr(model, 'head') else model.latest
    return model.rpc('eth_call', [{'to': to, 'data': digest(signature.encode())[:10] + abi(*words)[2:]},
        {'blockHash': head['hash'], 'requireCanonical': True}])


class PersistentVersionFixtureTests(unittest.TestCase):
    def test_reader_origin_is_not_the_selected_contracts_equal_numeric_id(self):
        m = ReaderModel(model_assets(self))
        profile = m.profile('http://127.0.0.1:7001', 'http://127.0.0.1:7002')
        self.assertEqual(profile['deployment']['moderation']['address'], NEXT)
        self.assertEqual(profile['deployment']['guidelines']['version'], 2)
        item = m.items[0]
        key = digest(bytes.fromhex(item['claim'][2:] + item['topics'][0][2:]))
        origin = call(m, m.addresses['index'], 'originOf(bytes32)', key)
        self.assertEqual(int(origin[2:66], 16), int(m.previous, 16))
        self.assertEqual(int(origin[66:130], 16), 1)
        self.assertNotEqual(call(m, m.previous, 'caseInfo(uint256)', 1), call(m, NEXT, 'caseInfo(uint256)', 1))
        self.assertTrue(all(r['pin']['requireCanonical'] for r in m.version_reads))

    def test_active_change_does_not_revoke_previous_approval_or_rewrite_profile(self):
        m = PublishModel(model_assets(self))
        profile = m.profile('http://127.0.0.1:7001', 'http://localhost:7002')
        self.assertEqual(int(call(m, AUTHORITY, 'codeHashOf(address)', NEXT), 16), 0)
        m.control({'command': 'activate-version'})
        self.assertEqual(int(call(m, AUTHORITY, 'active()'), 16), int(NEXT, 16))
        self.assertNotEqual(int(call(m, AUTHORITY, 'codeHashOf(address)', m.previous), 16), 0)
        self.assertNotEqual(int(call(m, AUTHORITY, 'codeHashOf(address)', NEXT), 16), 0)
        self.assertEqual(profile['deployment']['moderation']['address'], m.previous)

    def test_removal_registration_identifies_target_and_unknown_cases_are_not_registered(self):
        m = ModeratorModel(model_assets(self))
        raw = call(m, AUTHORITY, 'registration(address,uint256)', m.previous, 18)
        self.assertEqual(int(raw[130:194], 16), int(m.previous, 16))
        self.assertEqual(int(raw[194:258], 16), 16)
        self.assertEqual(int(call(m, AUTHORITY, 'registration(address,uint256)', m.previous, 999)[2:66], 16), 0)

    def test_authority_reads_refuse_an_unpinned_block(self):
        m = ReaderModel(model_assets(self))
        with self.assertRaises(ValueError):
            m.rpc('eth_call', [{'to': AUTHORITY, 'data': digest(b'active()')[:10]}, 'latest'])

    def test_reader_negative_controls_are_independent(self):
        m = ReaderModel(model_assets(self))
        m.control('unknown-origin'); self.assertTrue(m.bad_origin)
        m.control('wrong-guidelines'); self.assertFalse(m.bad_origin); self.assertTrue(m.bad_guidelines)
        m.control('unknown-case'); self.assertTrue(m.bad_registration)
        m.control('normal'); self.assertFalse(m.bad_registration)


if __name__ == '__main__': unittest.main()
