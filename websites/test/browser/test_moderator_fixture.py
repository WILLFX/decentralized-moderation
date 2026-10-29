"""Known-answer codec checks for the independent browser observer."""
import unittest
from pathlib import Path
import tempfile
from html.parser import HTMLParser
from serve_moderator import ROOT, Model, abi, commitment, digest, fixture_html, reference, viewport_html
from serve_publisher import PublisherModel


class FixtureCodecs(unittest.TestCase):
    def viewport_tags(self,path):
        class Tags(HTMLParser):
            def __init__(self): super().__init__();self.tags=[]
            def handle_starttag(self,tag,attrs): self.tags.append((tag,dict(attrs)))
        parser=Tags();page=viewport_html(path).decode();parser.feed(page)
        return page,parser.tags
    def test_fixed_viewport_is_only_an_explicit_test_option(self):
        page,tags=self.viewport_tags('/fixture/viewport?width=768&height=1024&text=200')
        frames=[attrs for tag,attrs in tags if tag=='iframe']
        self.assertEqual(len(frames),1)
        self.assertEqual(frames[0]['title'],'Application viewport')
        self.assertEqual((frames[0]['width'],frames[0]['height']),('768','1024'))
        self.assertEqual(frames[0]['src'],'/?text=200')
        self.assertNotIn('<form',page)
        self.assertNotIn('Apply viewport',page)
        for forbidden in ['frame.src =','contentWindow','contentDocument','location.reload']:
            self.assertNotIn(forbidden,page)
        wrapped=fixture_html((ROOT/'apps/moderator/index.html').read_bytes())
        self.assertNotIn(b'viewport-controls',wrapped)
        self.assertNotIn(b'frame.width =',wrapped)
    def test_default_viewport_automatically_follows_window_and_rotation(self):
        page,tags=self.viewport_tags('/fixture/viewport')
        frame=next(attrs for tag,attrs in tags if tag=='iframe')
        self.assertNotIn('width',frame)
        self.assertNotIn('height',frame)
        self.assertIn('width:100%',frame['style'])
        self.assertIn('height:100dvh',frame['style'])
        self.assertNotIn('<form',page)
        self.assertIn('width=device-width,initial-scale=1',page)
    def test_viewport_dimensions_clamp_and_bad_values_are_not_reflected(self):
        page,tags=self.viewport_tags('/fixture/viewport?width=-1&height=9999&text=300')
        frame=next(attrs for tag,attrs in tags if tag=='iframe')
        self.assertEqual((frame['width'],frame['height'],frame['src']),('240','1200','/?text=100'))
        page,tags=self.viewport_tags('/fixture/viewport?width=%3Cscript%3E&height=bad')
        frame=next(attrs for tag,attrs in tags if tag=='iframe')
        self.assertEqual((frame['width'],frame['height']),('390','844'))
        self.assertNotIn('value="<script>"',page)
    def test_publisher_receipt_checkpoint_keeps_original_case_after_later_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            assets = Path(folder)
            (assets / "MODERATION_GUIDELINES.md").write_bytes(b"Synthetic guidelines")
            model = PublisherModel(assets)
            model.cases[19] = {"content":"0x"+"11"*32,"meta":"0x"+"22"*32,"claim":"0x"+"33"*32,"submitter":model.account,"topics":[digest(b"biology")],"fee":10,"phase":1,"verdict":0,"deadline_a":900,"deadline_b":4500,"reveal_deadline":6300,"finalized_at":0}
            model.capture()
            call = {"to":model.addresses["moderation"],"data":digest(b"caseInfo(uint256)")[:10]+abi(19)[2:]}
            pin = {"blockHash":model.latest["hash"],"requireCanonical":True}
            original = model.rpc("eth_call", [call, pin])
            model.control({"command":"case-state","caseId":19,"state":"approved"})
            self.assertEqual(model.rpc("eth_call", [call, pin]), original)
            current = {"blockHash":model.latest["hash"],"requireCanonical":True}
            self.assertNotEqual(model.rpc("eth_call", [call, current]), original)

    def test_publisher_prior_history_checkpoint_keeps_uncertainty(self):
        with tempfile.TemporaryDirectory() as folder:
            assets=Path(folder)
            (assets/"MODERATION_GUIDELINES.md").write_bytes(b"Synthetic guidelines")
            model=PublisherModel(assets)
            model.control({"command":"seed-journal","count":100,"uncertain":1})
            import json
            event=model.events[-1]
            rows=json.loads(event["value"]["raw"])
            self.assertEqual(len(rows),100)
            self.assertEqual(rows[0]["state"],"unknown")
            self.assertIsNone(rows[0]["hash"])
            self.assertTrue(event["value"]["key"].endswith('-history'))
            model.control({"command":"history-storage","fail":True})
            self.assertEqual(model.events[-1],{"name":"fixtureHistoryStorageFault","value":True})

    def test_production_entry_is_guarded_or_refused(self):
        wrapped = fixture_html((ROOT / "apps/moderator/index.html").read_bytes())
        self.assertIn(b'src="./fixture-entry.js"', wrapped)
        self.assertNotIn(b'src="./loader.js"', wrapped)
        event_wrapped = fixture_html((ROOT / "apps/publisher/index.html").read_bytes(), True)
        self.assertIn(b'src="./fixture-events.js"', event_wrapped)
        self.assertNotIn(b'<script>', event_wrapped)
        with self.assertRaisesRegex(ValueError, "unguarded"):
            fixture_html(b'<script type="module" src="different-loader.js"></script>')
    def test_commitment_includes_domain_and_matches_existing_abi_vector(self):
        self.assertEqual(
            commitment(10200, "0x" + "22" * 20, 2, 0, "0x" + "11" * 20, 1, 0),
            "0xee5da45dac3b8de42cacf0e80345648b3ac172e27577a4eedb5f32fc0ff4fea2",
        )

    def test_reference_matches_publisher_vector(self):
        data = b'{"schemaVersion":1,"type":"article","title":" local bee browser submission ","topics":["biology"],"contentType":"text/plain"}'
        self.assertEqual(reference(data), "0x4f739cef314f324ef9f83c8960304a09b3be2a9f9d087ede711d9fc1673ca934")
        data=bytes((i*37+(i>>8)*17+(i>>16)*11+17)%256 for i in range(4097))
        self.assertEqual(reference(data),"0x4e47ece0ea2d437c688fe407f8240bed436b15eb780ec3d85607ab8c22b9f3f8")

    def test_old_checkpoint_cannot_return_later_mutable_state(self):
        with tempfile.TemporaryDirectory() as folder:
            assets = Path(folder)
            (assets / "MODERATION_GUIDELINES.md").write_bytes(b"Synthetic guidelines")
            model = Model(assets)
            call = {"to": model.addresses["moderation"], "data": digest(b"caseInfo(uint256)")[:10] + abi(17)[2:]}
            pin = {"blockHash": model.latest["hash"], "requireCanonical": True}
            model.rpc("eth_call", [call, pin])
            model.refresh()
            with self.assertRaisesRegex(ValueError, "checkpoint"):
                model.rpc("eth_call", [call, pin])


if __name__ == "__main__":
    unittest.main()
