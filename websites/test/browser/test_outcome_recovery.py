import unittest
from pathlib import Path
from serve_outcome_recovery import RecoveryModel, READ, CALLS
from serve_moderator import ROOT, abi

class RecoveryObserverTests(unittest.TestCase):
    def setUp(self): self.m=RecoveryModel(ROOT/'dist/moderator')
    def checkpoint(self,name): self.m.control({'command':'recovery-checkpoint','checkpoint':name})
    def read(self): return self.m.rpc('eth_call',[{'to':self.m.addresses['moderation'],'data':READ+f'{1:064x}'},{'blockHash':self.m.latest['hash'],'requireCanonical':True}])
    def send(self,signature,extra=()):
        selector=next(k for k,v in CALLS.items() if v==signature)
        return self.m.handle_wallet('eth_sendTransaction',['alpha',{'from':self.m.accounts['alpha'],'to':self.m.addresses['moderation'],'chainId':'0x27d8','value':'0x0','nonce':hex(self.m.next_nonce),'data':selector+abi(1,*extra)[2:]}])
    def test_original_cache_outlives_window_and_refuses_expiry(self):
        self.checkpoint('recoverable');self.send('cacheOutcome(uint256)')
        self.assertTrue(self.m.cached)
        self.m.height=30000;self.m.refresh()
        self.send('expireOutcome(uint256,uint8,uint40)',(1,100));self.assertFalse(self.m.sends[-1]['accepted'])
        self.send('draw(uint256)');self.assertTrue(self.m.sends[-1]['accepted'])
    def test_exact_boundary_cannot_expire(self):
        self.checkpoint('last');self.send('expireOutcome(uint256,uint8,uint40)',(1,100))
        self.assertFalse(self.m.sends[-1]['accepted'])
    def test_expiry_binds_round_and_target(self):
        self.checkpoint('expired');self.send('expireOutcome(uint256,uint8,uint40)',(0,100))
        self.assertFalse(self.m.sends[-1]['accepted'])
        self.send('expireOutcome(uint256,uint8,uint40)',(1,100));self.assertEqual(self.m.phase,5)
    def test_initial_expiry_is_refundable(self):
        self.checkpoint('initial-expired');self.send('expireOutcome(uint256,uint8,uint40)',(0,100))
        self.assertEqual((self.m.phase,self.m.refund),(6,100))
    def test_capability_unknown_error_and_malformed_remain_distinct(self):
        self.assertEqual(len(self.read()),258)
        self.m.capability='unknown';self.assertTrue(self.read().startswith('0x'+f'{2:064x}'))
        self.m.capability='malformed';self.assertEqual(self.read(),'0x1')
        self.m.capability='error'
        with self.assertRaises(ValueError):self.read()
    def test_lost_response_preserves_transaction_and_nonce(self):
        self.checkpoint('recoverable');self.m.lost_response=True
        with self.assertRaises(ValueError):self.send('cacheOutcome(uint256)')
        self.assertTrue(self.m.cached);self.assertEqual(self.m.next_nonce,10)
        self.assertEqual(len(self.m.transactions),1)
