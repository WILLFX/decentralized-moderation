import json
import unittest
from urllib.parse import parse_qs, urlsplit
from publisher_setup import setup_link, validate_public

class PublisherSetup(unittest.TestCase):
    def profile(self):
        pins = {name: {"address": "0x"+"11"*20, "codeHash": "0x"+"22"*32} for name in ["moderation", "stakes", "index", "token"]}
        return {"deployment": {"chainId": 10200, **pins, "guidelines": {"version": 1, "hash": "0x"+"33"*32}}, "rpcUrl": "https://rpc.example.org", "upload": {"endpoint": "http://127.0.0.1:1633", "postageBatchId": "44"*32}}

    def test_exact_bytes_are_bound_and_profile_data_is_not_embedded(self):
        raw = json.dumps(self.profile()).encode()
        link = setup_link(raw, "https://example.org/profile.json", "https://publisher.example.org/")
        values = parse_qs(urlsplit(link).fragment)
        self.assertEqual(values["profile"], ["https://example.org/profile.json"])
        changed = setup_link(raw+b"\n", "https://example.org/profile.json", "https://publisher.example.org/")
        self.assertNotEqual(values["profileHash"], parse_qs(urlsplit(changed).fragment)["profileHash"])
        self.assertNotIn("postageBatchId", link)

    def test_private_access_settings_and_ambiguous_json_are_refused(self):
        profile = self.profile()
        profile["upload"]["authorization"] = "Bearer do-not-share"
        with self.assertRaises(ValueError):
            validate_public(json.dumps(profile).encode())
        profile = self.profile()
        profile["rpcUrl"] = "https://rpc.example.org/?key=do-not-share"
        with self.assertRaises(ValueError):
            validate_public(json.dumps(profile).encode())
        with self.assertRaises(ValueError):
            validate_public(b'{"rpcUrl":"a","rpcUrl":"b"}')
        with self.assertRaises(ValueError):
            setup_link(json.dumps(self.profile()).encode(), "http://remote.example/profile.json", "https://example.org/")

class VersionedPublisherSetup(unittest.TestCase):
    def profile(self):
        def pin(n):return {"address":"0x"+format(n,"040x"),"codeHash":"0x"+format(n,"064x")}
        def version(n):return {"moderation":pin(n),"guidelines":{"version":n,"hash":"0x"+format(n+10,"064x")},"rulesHash":"0x"+format(n+20,"064x"),"guidelinesUrl":f"https://guidelines.example/{n}.md"}
        return {"deployment":{"chainId":10200,"moderation":pin(1),"stakes":pin(3),"index":pin(4),"token":pin(5),"guidelines":version(1)["guidelines"],"persistent":{"authority":pin(6),"versions":[version(1),version(2)]}},"rpcUrl":"https://rpc.example/","guidelinesUrl":"https://guidelines.example/1.md"}
    def test_version_profile_is_public_and_exactly_bound(self):
        p=self.profile();validate_public(json.dumps(p).encode())
        link=setup_link(json.dumps(p).encode(),"https://profiles.example/p.json","https://app.example/")
        self.assertIn("profileHash=",link)
        self.assertNotIn("rulesHash",link)
    def test_invalid_version_url_types_are_validation_errors(self):
        for value in [None, True, 42, [], {}]:
            p=self.profile();p["deployment"]["persistent"]["versions"][1]["guidelinesUrl"]=value
            with self.assertRaises(ValueError):validate_public(json.dumps(p).encode())
    def test_duplicate_selected_mismatch_and_private_version_urls_are_refused(self):
        for change in range(4):
            p=self.profile()
            if change==0:p["deployment"]["persistent"]["versions"][1]=p["deployment"]["persistent"]["versions"][0]
            elif change==1:p["deployment"]["guidelines"]["version"]=2
            elif change==2:p["deployment"]["persistent"]["versions"][1]["guidelinesUrl"]="https://example.org/?secret=private"
            else:p["deployment"]["persistent"]["versions"]*=9
            with self.assertRaises(ValueError):validate_public(json.dumps(p).encode())

class ExistingWorkSetup(unittest.TestCase):
    def test_existing_work_policy_is_preserved_in_exact_profile_bytes(self):
        profile=PublisherSetup().profile();profile["purpose"]="existingWork"
        raw=json.dumps(profile).encode();self.assertEqual(validate_public(raw)["purpose"],"existingWork")
        normal=PublisherSetup().profile();self.assertNotIn("purpose",validate_public(json.dumps(normal).encode()))
        for purpose in [None,True,"existing-work",{}]:
            profile["purpose"]=purpose
            with self.assertRaises(ValueError):validate_public(json.dumps(profile).encode())

if __name__ == "__main__":
    unittest.main()
