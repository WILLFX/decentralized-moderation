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

if __name__ == "__main__":
    unittest.main()
