"""Checks the keyless observer, not the contract or the browser implementation."""
import unittest
from serve_challenge_intent import ChallengeModel, CAPABILITY, SELECTOR
import serve_moderator as base

class ChallengeObserverTests(unittest.TestCase):
    def model(self):
        m=ChallengeModel(base.ROOT/'dist/moderator')
        tx={'from':m.accounts['alpha'],'to':m.addresses['moderation'],'value':'0x0','chainId':'0x27d8','nonce':'0x9','data':SELECTOR+base.abi(17,0,1)[2:]}
        return m,tx
    def test_exact_intent_succeeds_once(self):
        m,tx=self.model();h=m.handle_wallet('eth_sendTransaction',['alpha',tx]);self.assertEqual(m.receipts[h]['status'],'0x1');self.assertEqual(m.votes[17],[1,0,0,2,0]);self.assertEqual(m.challenge_round,1)
    def test_stale_round_and_same_outcome_mines_reverted_without_vote(self):
        m,tx=self.model();m.control({'command':'advance-challenge-review','round':1,'outcome':1});h=m.handle_wallet('eth_sendTransaction',['alpha',tx]);self.assertEqual(m.receipts[h]['status'],'0x0');self.assertEqual(m.votes,{})
    def test_stale_outcome_mines_reverted_without_vote(self):
        m,tx=self.model();m.preliminary=2;h=m.handle_wallet('eth_sendTransaction',['alpha',tx]);self.assertEqual(m.receipts[h]['status'],'0x0');self.assertEqual(m.votes,{})
    def test_lost_reply_keeps_exact_transaction(self):
        m,tx=self.model();m.control({'command':'lose-next-response'})
        with self.assertRaises(ValueError):m.handle_wallet('eth_sendTransaction',['alpha',tx])
        self.assertEqual(len(m.sends),1);self.assertEqual(m.transactions[m.sends[0]['hash']]['input'],tx['data'])
    def test_capability_reply_is_pinned_and_unknown_versions_stay_distinct(self):
        m,_=self.model();pin={'blockHash':m.latest['hash'],'requireCanonical':True};call={'to':m.addresses['moderation'],'data':CAPABILITY}
        self.assertEqual(m.rpc('eth_call',[call,pin]),base.abi(1));m.capability='unknown';self.assertEqual(m.rpc('eth_call',[call,pin]),base.abi(2));m.capability='legacy'
        with self.assertRaises(ValueError):m.rpc('eth_call',[call,pin])
        with self.assertRaises(ValueError):m.rpc('eth_call',[call,{'blockHash':'0x'+'00'*32}])
    def test_legacy_selector_and_bad_nonce_never_send(self):
        m,tx=self.model();tx['data']=base.digest(b'challenge(uint256)')[:10]+base.abi(17)[2:]
        with self.assertRaises(ValueError):m.handle_wallet('eth_sendTransaction',['alpha',tx])
        self.assertEqual(m.sends,[])

if __name__=='__main__':unittest.main()
