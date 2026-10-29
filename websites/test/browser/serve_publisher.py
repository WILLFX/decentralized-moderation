#!/usr/bin/env python3
"""Controlled publisher wallet/receipt states. No keys, forwarding or chain sends."""
import argparse
import json
import threading
import time
from copy import deepcopy
from pathlib import Path
from serve_moderator import Model, ROOT, abi, digest, reference, serve


class WalletRejected(ValueError):
    code = 4001


class PublisherModel(Model):
    kind = "publisher-wallet-ui-fixture"
    def __init__(self, assets):
        super().__init__(assets)
        self.event_polling = True
        self.transactions = {}
        self.requests = []
        self.awaiting = None
        self.release = threading.Event()
        self.resolution = None
        self.allowance = 0
        self.next_nonce = 9
        self.cases = {}
        self.refunds = {}
        self.listed = set()
        self.balance = 990 * 10**16
        self.minimum = 10**14
        self.fail_funds = False
        self.wallet_chain = "0x27d8"
        self.snapshots = {}
        self.wallet_calls = []
        self.case_reads = []
        self.uploads = []
        self.profile_reads = 0
        self.metadata_documents = set()
        self.corrupt_content = False
        self.documents[self.content[2:]]=b"Synthetic field note. This is plain text, not an image."
        self.capture()

    def refresh(self):
        self.height += 3
        self.clock = max(int(time.time()), self.clock + 1, getattr(self, "minimum_timestamp", 0))
        self.latest = self.block(self.height, self.clock)
        self.finalized = self.block(self.height - 2, self.clock - 2)

    def capture(self):
        state = {"cases":deepcopy(self.cases), "refunds":dict(self.refunds), "listed":set(self.listed), "allowance":self.allowance, "balance":self.balance, "minimum":self.minimum}
        self.snapshots[self.latest["hash"]] = state
        self.snapshots[self.finalized["hash"]] = deepcopy(getattr(self,"previous_state",state))
        self.previous_state=deepcopy(state)

    def case_info(self, c):
        phase=c["phase"]
        return abi(c["content"],c["meta"],c["claim"],c["submitter"],len(c["topics"]),0,0,phase,0,
                   c["deadline_a"] if phase==1 else c["deadline_b"] if phase==2 else c["reveal_deadline"],
                   c["finalized_at"],800,900,0,0,0 if phase==1 else 3,0 if phase==1 else 3,
                   3 if phase==5 else 0,3 if phase==5 else 0,6 if phase==5 else 0,0,c["verdict"],3 if phase==5 else 0,0,c["fee"])

    def profile(self, origin, content_origin):
        result = super().profile(origin, content_origin)
        for key in ["gatewayUrl", "timing", "metadataPath", "contentPath"]: result.pop(key, None)
        result["upload"] = {"endpoint": origin, "postageBatchId": "11" * 32}
        result["display"] = {"decimals":16,"symbol":"TEST"}
        result["contentGatewayUrl"] = content_origin
        result["contentPath"] = "bytes"
        return result

    def upload(self, data, headers=None):
        ref = reference(data)[2:]
        self.documents[ref] = data
        try: value=json.loads(data)
        except (ValueError,UnicodeError): value=None
        metadata=isinstance(value,dict) and value.get("schemaVersion")==1
        if metadata: self.metadata_documents.add(ref)
        headers={k.lower():v for k,v in (headers or {}).items()}
        self.uploads.append({"reference":ref,"bytes":len(data),"metadata":metadata,"host":headers.get("host"),"batch":headers.get("swarm-postage-batch-id"),"authorizationPresent":bool(headers.get("authorization"))})
        return {"reference": ref}

    def read_document(self,ref):
        data=self.documents.get(ref)
        if data is not None and self.corrupt_content and ref not in self.metadata_documents: return b"Tampered content"
        return data

    def rpc(self, method, params):
        if method == "eth_getTransactionByHash": return self.transactions.get(params[0])
        if method == "eth_call":
            self.reads += 1
            state=self.snapshots[params[1]["blockHash"]]
            if params[0]["to"] not in self.codes or params[1].get("requireCanonical") is not True: raise ValueError("Unknown pin/target")
            data=params[0]["data"]
            selector=data[:10]
            if self.fail_funds and selector==digest(b"balanceOf(address)")[:10]: raise ValueError("Synthetic funding read unavailable")
            words=[int(data[i:i+64],16) for i in range(10,len(data),64)]
            for signature,name in [("stakes()","stakes"),("token()","token"),("index()","index"),("moderation()","moderation")]:
                if selector==digest(signature.encode())[:10]: return abi(self.addresses[name])
            for signature,value in [("guidelinesVersion()",1),("guidelinesHash()",digest(self.guidelines)),("feeMin()",state["minimum"]),("balanceOf(address)",state["balance"]),("allowance(address,address)",state["allowance"]),("nextCaseId()",max(state["cases"],default=18)+1)]:
                if selector==digest(signature.encode())[:10]: return abi(value)
            if selector==digest(b"isListed(bytes32,bytes32)")[:10]: return abi(int((f"0x{words[0]:064x}",f"0x{words[1]:064x}") in state["listed"]))
            case=words[0]
            if selector==digest(b"caseInfo(uint256)")[:10]:
                self.case_reads.append({"caseId":str(case),"blockHash":params[1]["blockHash"]})
                return self.case_info(state["cases"][case])
            c=state["cases"][case]
            if selector==digest(b"topicsOf(uint256)")[:10]: return abi(*c["topics"],*([0]*(5-len(c["topics"]))))
            if selector==digest(b"refundOwed(uint256)")[:10]: return abi(state["refunds"].get(case,0))
            if selector==digest(b"pairScheduleOf(uint256)")[:10]: return abi(c["deadline_a"],c["deadline_b"],0,0)
            raise ValueError("Publisher read not supported")
        return super().rpc(method, params)

    def handle_wallet(self, method, params):
        self.wallet_calls.append(method)
        if method=="eth_chainId": return self.wallet_chain
        if method != "eth_sendTransaction": return super().handle_wallet(method, params)
        with self.lock:
            tx = params[0]
            if self.awaiting is not None or tx["chainId"] != "0x27d8" or tx["from"] != self.account or tx["value"] != "0x0": raise ValueError("Unexpected publisher intent")
            data = tx["data"]
            if tx["to"] == self.addresses["token"]:
                if len(data) != 138 or data[:10] != digest(b"approve(address,uint256)")[:10] or int(data[10:74], 16) != int(self.addresses["moderation"],16): raise ValueError("Expected exact approval")
            elif tx["to"] == self.addresses["moderation"]:
                words = [data[i:i+64] for i in range(10,len(data),64)]
                if data[:10] == digest(b"withdrawRefund(uint256)")[:10]:
                    if len(words)!=1 or self.refunds.get(int(words[0],16),0)==0: raise ValueError("No refund")
                elif data[:10] != digest(b"submit(bytes32,bytes32,bytes32[],uint256)")[:10] or len(words) != 6 or words[0] not in self.documents or words[1] not in self.metadata_documents or int(words[2],16) != 128 or int(words[4],16) != 1 or words[5] != digest(b"biology")[2:]: raise ValueError("Unexpected publication intent")
            else: raise ValueError("Unknown destination")
            tx_hash = digest(f"publisher/request/{len(self.requests)}".encode())
            self.awaiting = {"hash": tx_hash, "chainId": "0x27d8", "from": tx["from"], "to": tx["to"], "input": data, "value": "0x0", "nonce": hex(self.next_nonce), "blockNumber": None, "blockHash": None}
            self.requests.append(dict(self.awaiting))
            self.release.clear()
            self.resolution = None
        if not self.release.wait(240): raise ValueError("Observer did not resolve wallet")
        with self.lock:
            mode = self.resolution
            sent = self.awaiting
            self.awaiting = None
            if mode == "reject": raise WalletRejected("Rejected")
            self.next_nonce += 1
            self.transactions[sent["hash"]] = sent
            self.sends.append({"hash": sent["hash"], "nonce": sent["nonce"], "to": sent["to"], "data": sent["input"]})
            if mode == "unknown": raise ValueError("Response lost after broadcast")
            return sent["hash"]

    def mine(self, original_hash, kind):
        original = self.transactions[original_hash]
        tx = dict(original)
        if kind != "original": tx["hash"] = digest((original_hash + kind).encode())
        if kind == "cancel": tx.update(to=tx["from"], input="0x")
        if kind == "wrong-nonce": tx["nonce"] = hex(int(tx["nonce"],16)+99)
        self.refresh()
        tx.update(blockNumber=self.latest["number"], blockHash=self.latest["hash"])
        self.transactions[tx["hash"]] = tx
        self.receipts[tx["hash"]] = {"transactionHash": tx["hash"], "from": tx["from"], "to": tx["to"], "blockNumber": tx["blockNumber"], "blockHash": tx["blockHash"], "status": "0x1"}
        if kind in ["original", "replacement"]:
            if original["to"] == self.addresses["token"]: self.allowance = int(original["input"][74:138],16)
            elif original["input"][:10] == digest(b"withdrawRefund(uint256)")[:10]:
                case=int(original["input"][10:74],16)
                self.balance+=self.refunds.get(case,0)
                self.refunds[case]=0
            else:
                words=[original["input"][i:i+64] for i in range(10,len(original["input"]),64)]
                case=max(self.cases,default=18)+1
                fee=int(words[3],16)
                claim=digest(bytes.fromhex(words[0]+words[1]))
                self.cases[case]={"content":"0x"+words[0],"meta":"0x"+words[1],"claim":claim,"submitter":original["from"],"topics":["0x"+w for w in words[5:]],"fee":fee,"phase":1,"verdict":0,"deadline_a":self.clock+900,"deadline_b":self.clock+4500,"reveal_deadline":self.clock+6300,"finalized_at":0}
                self.balance-=fee
                self.allowance=max(0,self.allowance-fee)
                self.receipts[tx["hash"]]["logs"]=[{"address":self.addresses["moderation"],"topics":[digest(b"Submitted(uint256,address,bytes32)"),abi(case),abi(original["from"])],"data":claim,"removed":False,"blockHash":tx["blockHash"],"transactionHash":tx["hash"]}]
        self.capture()
        return {"hash": tx["hash"], "kind": kind}

    def control(self, body):
        command = body["command"]
        if command=="history-storage":
            self.events.append({"name":"fixtureHistoryStorageFault","value":bool(body["fail"])})
            return {"historyStorageFault":bool(body["fail"])}
        if command=="seed-journal":
            count=int(body.get("count",100));uncertain=int(body.get("uncertain",0))
            if not 0<=uncertain<=count<=100: raise ValueError("Invalid synthetic history count")
            records=[]
            for i in range(count):
                state="unknown" if i<uncertain else "confirmed"
                records.append({"chainId":10200,"contract":self.addresses["moderation"],"publisher":self.account,"action":"approve","to":self.addresses["token"],"data":digest(b"approve(address,uint256)")[:10]+abi(self.addresses["moderation"],self.minimum)[2:],"intent":None,"caseId":"","state":state,"hash":None if state=="unknown" else "0x"+f"{10000+i:064x}","requestId":f"synthetic-prior-{i}"})
            key=f"swarm-publisher-last-10200-{self.addresses['moderation'].lower()}-{self.account.lower()}-history"
            self.events.append({"name":"fixtureHistorySeed","value":{"key":key,"raw":json.dumps(records,separators=(',',':'))}})
            return {"seeded":count,"uncertain":uncertain,"scope":"synthetic prior journal only"}
        if command=="corrupt-content": self.corrupt_content=bool(body["enabled"]); return {"corruptContent":self.corrupt_content}
        if command == "release":
            if self.awaiting is None or body["result"] not in ["broadcast","reject","unknown"]: raise ValueError("No pending request")
            self.resolution = body["result"]
            self.release.set()
            return {"released": self.resolution}
        if command == "mine":
            if body["kind"] not in ["original","replacement","cancel","wrong-nonce"]: raise ValueError("Unknown mined state")
            return self.mine(body["hash"],body["kind"])
        if command == "drop": self.transactions.pop(body["hash"],None); return {"dropped":body["hash"]}
        if command == "allowance": self.allowance = 0; self.refresh(); self.capture(); return {"allowance": 0}
        if command == "funds":
            for name in ["minimum","balance","allowance"]:
                if name in body:
                    number=int(body[name])
                    if not 0<=number<2**256: raise ValueError("Invalid synthetic amount")
                    setattr(self,name,number)
            self.refresh(); self.capture()
            return {name:str(getattr(self,name)) for name in ["minimum","balance","allowance"]}
        if command == "fail-funds": self.fail_funds=bool(body["enabled"]); return {"fundsUnavailable":self.fail_funds}
        if command == "wallet-chain":
            self.wallet_chain=hex(int(body["chainId"]))
            self.events.append({"name":"chainChanged","value":self.wallet_chain})
            return {"walletChain":self.wallet_chain}
        if command == "case-state":
            case=int(body["caseId"])
            c=self.cases[case]
            state=body["state"]
            if state=="approved":
                self.minimum_timestamp=c["reveal_deadline"]+3601
                c["phase"]=5; c["verdict"]=1
                self.listed.update((c["claim"],t) for t in c["topics"])
            elif state=="unresolved":
                self.minimum_timestamp=c["deadline_b"]+1
                c["phase"]=6; c["verdict"]=0; self.refunds[case]=c["fee"]
            elif state=="removed": self.listed.difference_update((c["claim"],t) for t in c["topics"])
            else: raise ValueError("Unsupported publication state")
            self.refresh()
            if state in ["approved","unresolved"]: c["finalized_at"]=self.clock
            self.capture()
            return {"caseId":case,"state":state}
        if command == "authoring-storage":
            self.events.append({"name":"fixtureAuthoringStorageFault","value":bool(body["fail"])})
            return {"storageFault":bool(body["fail"])}
        if command == "account":
            self.account = "0x" + body["byte"] * 20
            self.events.append({"name":"accountsChanged","value":[self.account]})
            return {"account":self.account}
        raise ValueError("Unknown observer command")

    def status(self):
        return {"scope":"synthetic publisher UI only","reads":self.reads,"profileReads":self.profile_reads,"walletCalls":self.wallet_calls,"caseReads":self.case_reads,"uploads":self.uploads,"awaiting":self.awaiting,"requests":self.requests,"sends":self.sends,"receipts":self.receipts,"transactions":self.transactions}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=ROOT / "dist/publisher")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    serve(parser.parse_args(), PublisherModel)
