"""Known-answer timing states for the normal compiled moderator UI."""
import tempfile
import threading
import time
import unittest
from pathlib import Path
from serve_moderator import abi, commitment, digest
from serve_moderator_timing import TimingModel

class TimingCheckpoints(unittest.TestCase):
    def model(self):
        folder=tempfile.TemporaryDirectory();self.addCleanup(folder.cleanup)
        assets=Path(folder.name);(assets/"MODERATION_GUIDELINES.md").write_bytes(b"Synthetic timing guidelines")
        return TimingModel(assets)
    def words(self,model):
        raw=model.info(17);return [int(raw[i:i+64],16) for i in range(2,len(raw),64)]
    def transaction(self,model,signature,*words):
        return {"chainId":"0x27d8","from":model.account,"to":model.addresses["moderation"],"value":"0x0","data":digest(signature.encode())[:10]+abi(*words)[2:]}
    def test_wallet_hold_waits_without_lock_or_send_until_observer_releases(self):
        m=self.model();m.control({"command":"hold-wallet"})
        result=[];errors=[]
        tx=self.transaction(m,"commit(uint256,bytes32)",17,123)
        def send():
            try: result.append(m.handle_wallet("eth_sendTransaction",[tx]))
            except Exception as error: errors.append(error)
        worker=threading.Thread(target=send,daemon=True)
        worker.start()
        self.addCleanup(m.wallet_release.set)
        self.assertTrue(m.wallet_waiting.wait(1),"Synthetic request did not reach its hold")
        acquired=m.lock.acquire(timeout=1)
        self.assertTrue(acquired,"Wallet wait held the observer's model lock")
        try:
            self.assertEqual(m.status()["walletHeld"],True)
            self.assertEqual(m.status()["walletWaiting"],True)
            self.assertFalse(m.sends)
            self.assertNotIn(17,m.votes)
            self.assertEqual(m.handle_wallet("eth_accounts",[]),[m.account])
            m.control({"command":"release-wallet"})
        finally: m.lock.release()
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors)
        self.assertEqual(result,[m.sends[0]["hash"]])
        self.assertEqual(len(m.sends),1)
        self.assertEqual(m.sends[0]["action"],"commit(uint256,bytes32)")
        self.assertEqual(m.votes[17][0],123)
        self.assertFalse(m.status()["walletWaiting"])
        self.assertFalse(m.status()["walletHeld"])
    def test_wallet_hold_timeout_cannot_send_later_after_release(self):
        m=self.model();m.WALLET_WAIT_SECONDS=0.01
        m.control({"command":"hold-wallet"})
        tx=self.transaction(m,"commit(uint256,bytes32)",17,123)
        with self.assertRaisesRegex(ValueError,"no transaction sent"):
            m.handle_wallet("eth_sendTransaction",[tx])
        self.assertFalse(m.status()["walletWaiting"])
        self.assertFalse(m.sends)
        m.control({"command":"release-wallet"})
        self.assertFalse(m.sends)
        self.assertNotIn(17,m.votes)
    def test_finalized_checkpoint_requires_reveal_and_keeps_base_terminal_evidence(self):
        m=self.model();vote=2;salt=33
        saved=commitment(10200,m.addresses["moderation"],17,0,m.account,vote,salt)
        m.handle_wallet("eth_sendTransaction",[self.transaction(m,"commit(uint256,bytes32)",17,saved)])
        with self.assertRaisesRegex(ValueError,"reveals"):
            m.control({"mode":"finalized"})
        self.assertEqual(m.mode,"commit")
        m.control({"mode":"reveal"})
        m.handle_wallet("eth_sendTransaction",[self.transaction(m,"reveal(uint256,uint8,bytes32)",17,vote,salt)])
        m.control({"mode":"finalized"})
        values=self.words(m)
        self.assertEqual(values[7],5)
        self.assertEqual(values[10],m.clock)
        self.assertEqual(values[21],2)
        self.assertEqual(m.votes[17][3],vote)
        self.assertEqual(m.target,0)
        m.handle_wallet("eth_sendTransaction",[self.transaction(m,"claim(uint256,address)",17,m.account)])
        self.assertTrue(m.votes[17][4])
    def test_draw_boundaries_use_heights_and_closed_reveal(self):
        m=self.model()
        for mode,age in m.AGES.items():
            m.control({"mode":mode});values=self.words(m)
            self.assertEqual(values[7],3);self.assertEqual(m.height-values[13],age)
            self.assertLess(values[9],m.clock)
            self.assertEqual(values[17]+values[18],values[19]+values[20])
    def test_budget_states_keep_finalized_latest_deadline_equal_and_use_wall_time(self):
        m=self.model()
        for mode,offset in m.OFFSETS.items():
            m.control({"mode":mode});m.rpc("eth_getBlockByNumber",["finalized",False])
            self.assertLessEqual(abs(m.clock-int(time.time())),1)
            self.assertEqual(self.words(m)[9]-m.clock,offset)
            self.assertEqual(m.info(17,True),m.info(17,False))
    def test_wallet_boundary_changes_evidence_after_finalized_read_without_send(self):
        m=self.model();m.control({"mode":"reveal"});m.control({"command":"wallet-boundary","mode":"finality-lag"})
        m.rpc("eth_getBlockByNumber",["finalized",False]);m.wallet("eth_accounts",[])
        self.assertEqual(m.mode,"finality-lag")
        self.assertEqual(m.boundaries[0]["finalizedReadsBeforeWalletChange"],1)
        self.assertFalse(m.sends)
        raw=m.info(17,True);self.assertEqual(int(raw[2+7*64:2+8*64],16),2)
    def test_stale_head_and_unavailable_read_are_distinct(self):
        m=self.model();m.control({"mode":"stale-head"})
        self.assertEqual(m.clock-int(m.latest["timestamp"],16),60)
        m.control({"mode":"read-error"})
        with self.assertRaises(ValueError):m.rpc("eth_getBlockByNumber",["latest",False])

if __name__=="__main__":unittest.main()
