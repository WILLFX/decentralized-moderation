"""Checks the prepared search facts; production browser behavior is tested separately."""
import unittest
from pathlib import Path
from serve_search import SearchModel, SELECTORS
from serve_moderator import abi, digest, reference

class SearchFixtureTests(unittest.TestCase):
    def setUp(self):
        self.model=SearchModel(Path(__file__).resolve().parents[2]/"apps/search")
    def call(self,signature,*args):
        selector=next(k for k,v in SELECTORS.items()if v==signature)
        return self.model.rpc("eth_call",[{"to":self.model.addresses["index"],"data":selector+abi(*args)[2:]},{"blockHash":self.model.head["hash"],"requireCanonical":True}])
    def test_distinct_pages_match_declared_count(self):
        topic=digest(b"biology")
        self.assertEqual(int(self.call("listedCount(bytes32)",topic),16),5)
        one=self.call("listedPage(bytes32,uint256,uint256)",topic,0,2)
        two=self.call("listedPage(bytes32,uint256,uint256)",topic,2,2)
        self.assertNotEqual(one,two)
        self.assertEqual(int(one[66:130],16),2)
    def test_documents_authenticate_and_tampering_changes_reference(self):
        for item in self.model.items:
            self.assertEqual(reference(self.model.metadata(item["meta_ref"][2:])),item["meta_ref"])
        self.model.control("tamper")
        self.assertNotEqual(reference(self.model.metadata(self.model.items[0]["meta_ref"][2:])),self.model.items[0]["meta_ref"])
    def test_removal_changes_fresh_membership(self):
        item=self.model.items[0];topic=digest(b"biology")
        self.assertEqual(int(self.call("isListed(bytes32,bytes32)",item["claim"],topic),16),1)
        self.model.control("removed")
        self.assertEqual(int(self.call("isListed(bytes32,bytes32)",item["claim"],topic),16),0)
    def test_unsupported_methods_and_unknown_pins_are_refused(self):
        with self.assertRaises(ValueError):self.model.rpc("eth_sendTransaction",[{}])
        with self.assertRaises(ValueError):self.model.rpc("eth_getCode",[self.model.addresses["index"],{"blockHash":"0x"+"ff"*32,"requireCanonical":True}])
    def test_replacement_changes_existing_block_identity(self):
        original=dict(self.model.head);self.model.control("replaced")
        self.assertEqual(self.model.head["number"],original["number"])
        self.assertNotEqual(self.model.head["hash"],original["hash"])
if __name__=="__main__":unittest.main()
