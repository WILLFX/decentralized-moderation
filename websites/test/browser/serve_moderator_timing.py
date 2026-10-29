#!/usr/bin/env python3
"""Isolated M3 timing checkpoints. No forwarding, signing or clock modification."""
import argparse
from pathlib import Path
import threading
import time
from serve_moderator import Model, ROOT, abi, serve, digest

class TimingModel(Model):
    kind="moderator-timing-ui-fixture"
    WALLET_WAIT_SECONDS=120
    MODES={"commit","commit-b","reveal","finality-lag","stale-head","read-error","reveal-closed","budget-above","budget-at","budget-below","window-expired","draw-before","draw-at","draw-first","draw-near","draw-last","draw-expired"}
    OFFSETS={"budget-above":126,"budget-at":125,"budget-below":124,"window-expired":5}
    AGES={"draw-before":-1,"draw-at":0,"draw-first":1,"draw-near":249,"draw-last":250,"draw-expired":251}
    def __init__(self,assets):
        super().__init__(assets)
        self.cutoff=self.clock+1800
        self.target=0
        self.capture_on_finalized=False
        self.wallet_calls=[]
        self.finalized_reads=0
        self.block_reads=[]
        self.flip_after_wallet=None
        self.boundaries=[]
        self.wallet_held=False
        self.wallet_waiting=threading.Event()
        self.wallet_release=threading.Event()
        self.wallet_release.set()
    def set_checkpoint(self,mode):
        if mode not in self.MODES: raise ValueError("Unknown timing checkpoint")
        self.mode=mode
        super().refresh()
        self.cutoff=self.clock+self.OFFSETS.get(mode,1800)
        self.target=self.height-self.AGES[mode] if mode in self.AGES else 0
        if mode=="stale-head":
            self.latest=self.block(self.height,self.clock-60)
            self.finalized=self.block(self.height-2,self.clock-62)
        self.capture_on_finalized=mode in self.OFFSETS
    def control(self,body):
        if body.get("command")=="hold-wallet":
            if self.wallet_waiting.is_set(): raise ValueError("A synthetic wallet request is already waiting")
            self.wallet_held=True
            self.wallet_release.clear()
            return {"walletHeld":True}
        if body.get("command")=="release-wallet":
            self.wallet_held=False
            self.wallet_release.set()
            return {"walletHeld":False}
        if body.get("command")=="wallet-boundary":
            if body["mode"]!="finality-lag": raise ValueError("Unsupported boundary checkpoint")
            self.flip_after_wallet=body["mode"]
            self.finalized_reads=0
            self.block_reads=[]
            return {"boundaryArmed":body["mode"]}
        if body.get("mode")=="finalized":
            # Keep the base constraint: every recorded synthetic vote must
            # reveal before this prepared finalization checkpoint is allowed.
            result=super().control(body)
            self.target=0
            self.capture_on_finalized=False
            return {**result,"preparedAt":self.clock,"observedHeight":self.height,"target":self.target}
        self.set_checkpoint(body["mode"])
        return {"mode":self.mode,"preparedAt":self.clock,"observedHeight":self.height,"target":self.target}
    def info(self,case,finalized=False):
        raw=super().info(case,finalized)
        values=[int(raw[i:i+64],16) for i in range(2,len(raw),64)]
        if self.mode in {"commit","finalized"}: return raw
        if self.mode=="commit-b":
            values[7]=1;values[9]=self.clock-30;values[12]=self.height-1
            values[15]=3+int(case in self.votes);values[16]=0
            values[17:21]=[0,0,0,0]
        else:
            values[9]=self.cutoff
            if self.target or self.mode=="reveal-closed":
                values[9]=self.clock-10
                values[17:21]=[3,3,3,3]
            values[13]=self.target
        return abi(*values)
    def rpc(self,method,params):
        if self.mode=="read-error" and method=="eth_getBlockByNumber": raise ValueError("Synthetic read unavailable")
        if method=="eth_getBlockByNumber" and params[0] in ["latest","finalized"]:
            if params[0]=="finalized" and self.capture_on_finalized:
                mode=self.mode;self.set_checkpoint(mode);self.capture_on_finalized=False
            self.block_reads.append({"tag":params[0],"mode":self.mode})
            if params[0]=="finalized": self.finalized_reads+=1
        if method=="eth_call" and params[0]["data"].startswith(digest(b"pairScheduleOf(uint256)")[:10]) and self.mode=="commit-b":
            # Let the normal reader validate the pin before replacing only its schedule.
            super().rpc(method,params)
            return abi(self.clock-30,self.clock+600,0,0)
        return super().rpc(method,params)
    def wallet(self,method,params):
        self.wallet_calls.append(method)
        if method=="eth_accounts" and self.flip_after_wallet:
            mode=self.flip_after_wallet;self.flip_after_wallet=None
            self.boundaries.append({"mode":mode,"finalizedReadsBeforeWalletChange":self.finalized_reads,"heightBefore":self.height})
            self.set_checkpoint(mode)
        return super().wallet(method,params)
    def handle_wallet(self,method,params):
        with self.lock:
            if method!="eth_sendTransaction" or not self.wallet_held:
                return self.wallet(method,params)
            if self.wallet_waiting.is_set(): raise ValueError("A synthetic wallet request is already waiting")
            self.wallet_waiting.set()
            release=self.wallet_release
        # Never wait under model.lock: the observer must be able to inspect
        # status and release this request. No model send occurs before release.
        try:
            if not release.wait(self.WALLET_WAIT_SECONDS):
                raise ValueError("Synthetic wallet wait timed out; no transaction sent")
            with self.lock:
                return self.wallet(method,params)
        finally:
            self.wallet_waiting.clear()
    def status(self):
        return {**super().status(),"walletCalls":self.wallet_calls,"blockReadTrace":self.block_reads,"walletBoundaries":self.boundaries,"target":self.target,"deadline":self.cutoff,"walletHeld":self.wallet_held,"walletWaiting":self.wallet_waiting.is_set()}

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets",type=Path,default=ROOT/"dist/moderator")
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--port",type=int,default=0)
    serve(parser.parse_args(),TimingModel)
