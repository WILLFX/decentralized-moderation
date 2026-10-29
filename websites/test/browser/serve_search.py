#!/usr/bin/env python3
"""Prepared reader UI states. Serves the production Wasm; no wallet or RPC forwarding."""
import argparse
import hashlib
import json
import mimetypes
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from serve_moderator import ROOT, abi, digest, reference

SIGS = ["stakes()", "token()", "index()", "moderation()", "guidelinesVersion()", "guidelinesHash()", "nextCaseId()", "caseInfo(uint256)", "topicsOf(uint256)", "listedCount(bytes32)", "listedPage(bytes32,uint256,uint256)", "isListed(bytes32,bytes32)", "entryOf(bytes32,bytes32)"]
SELECTORS = {digest(s.encode())[:10]: s for s in SIGS}

class SearchModel:
    def __init__(self, assets):
        self.assets=assets
        self.addresses={n:"0x"+b*20 for n,b in [("moderation","10"),("stakes","20"),("index","30"),("token","40")]}
        self.codes={a:"0x60016000"+f"{i:02x}" for i,a in enumerate(self.addresses.values(),1)}
        self.guidelines=(assets/"MODERATION_GUIDELINES.md").read_bytes()
        self.height=1000
        self.blocks={}
        self.head=self.block(1000)
        self.calls=[]
        self.mode="normal"
        self.delay=0
        self.items=[]
        for i in range(1,6):
            topics=["biology"]+(["genetics"] if i in [2,4] else [])
            content=f"Reader fixture publication {i}. Independent text for item {i}.".encode()
            metadata={"schemaVersion":1,"type":"article","title":"Field notes on pollination" if i<3 else f"Study {i}: "+"A long topic title "*8,"description":"Observations from a small garden, with dates, plant names and a distinct item number "+str(i)+". "+("Long descriptive text. "*25 if i==3 else ""),"topics":topics,"language":"en","contentType":"text/plain","source":"Publisher note "+("unbroken"*30 if i==3 else str(i))}
            raw=json.dumps(metadata,separators=(",",":")).encode()
            content_ref,meta_ref=reference(content),reference(raw)
            claim=digest(bytes.fromhex(content_ref[2:]+meta_ref[2:]))
            keys=[digest(t.encode()) for t in topics]
            self.items.append({"id":i,"content":content,"content_ref":content_ref,"metadata":raw,"meta_ref":meta_ref,"claim":claim,"topics":keys})
        self.graph={"schemaVersion":1,"categories":[{"id":"science","label":"Science","topicKey":digest(b"science"),"parents":[]},{"id":"biology","label":"Biology","topicKey":digest(b"biology"),"parents":["science"]},{"id":"genetics","label":"Genetics","topicKey":digest(b"genetics"),"parents":["biology"]}]}
    def block(self,n):
        b={"number":hex(n),"timestamp":hex(1793090000+n),"hash":digest(f"reader/{n}/{self.mode if hasattr(self,'mode') else 'normal'}".encode())}
        self.blocks[b["number"]]=b
        return b
    def profile(self,origin,content_origin):
        return {"deployment":{"chainId":"10200",**{n:{"address":a,"codeHash":digest(bytes.fromhex(self.codes[a][2:]))}for n,a in self.addresses.items()},"guidelines":{"version":"1","hash":digest(self.guidelines)}},"rpcUrl":origin+"/fixture/rpc","gatewayUrl":origin,"contentGatewayUrl":content_origin,"contentPath":"bytes","pageSize":2,"scanSize":2}
    def control(self,mode):
        if mode not in ["normal","removed","tamper","unavailable","rpc-failure","replaced","slow"]: raise ValueError("Unknown mode")
        self.mode=mode
        self.delay=0.15 if mode=="slow" else 0
        if mode=="replaced":
            for tag,b in self.blocks.items(): b["hash"]=digest((tag+"/replacement").encode())
            self.head=self.blocks[hex(self.height)]
        elif mode=="removed":
            self.height+=1;self.head=self.block(self.height)
        return self.status()
    def status(self):return {"mode":self.mode,"calls":len(self.calls),"methods":sorted(set(m for m,_ in self.calls)),"scope":"Prepared read states, no real chain"}
    def listed(self,topic,current=False):
        return [x for x in self.items if topic in x["topics"] and not (self.mode=="removed" and current and x["id"]==1)]
    def rpc(self,method,params):
        self.calls.append((method,params))
        if method not in ["eth_chainId","eth_getBlockByNumber","eth_getCode","eth_call"]:raise ValueError("Read method required")
        if self.mode=="rpc-failure":raise ValueError("Prepared source failure")
        if self.delay:time.sleep(self.delay)
        if method=="eth_chainId":return "0x27d8"
        if method=="eth_getBlockByNumber":return self.head if params[0]=="latest" else self.blocks[params[0]]
        pin=params[1]
        if not isinstance(pin,dict) or pin.get("requireCanonical") is not True or pin.get("blockHash") not in [b["hash"] for b in self.blocks.values()]:raise ValueError("Unknown source pin")
        if method=="eth_getCode":return self.codes[params[0].lower()]
        call=params[0]
        if call["to"].lower() not in self.codes:raise ValueError("Unknown contract")
        data=call["data"];sig=SELECTORS[data[:10]];words=[int(data[i:i+64],16) for i in range(10,len(data),64)]
        links={"stakes()":"stakes","token()":"token","index()":"index","moderation()":"moderation"}
        if sig in links:return abi(self.addresses[links[sig]])
        if sig=="guidelinesVersion()":return abi(1)
        if sig=="guidelinesHash()":return abi(digest(self.guidelines))
        if sig=="nextCaseId()":return abi(6)
        if sig in ["caseInfo(uint256)","topicsOf(uint256)"]:
            x=self.items[words[0]-1]
            if sig=="topicsOf(uint256)":return abi(*x["topics"],*([0]*(5-len(x["topics"]))))
            return abi(x["content_ref"],x["meta_ref"],x["claim"],"0x"+"50"*20,len(x["topics"]),0,0,5,0,0,1793090000,800,900,950,0,3,3,3,3,6,0,1,3,0,100)
        topic="0x"+f"{words[0]:064x}"
        current=pin["blockHash"]==self.head["hash"]
        if sig=="listedCount(bytes32)":return abi(len(self.listed(topic,current)))
        if sig=="listedPage(bytes32,uint256,uint256)":
            rows=self.listed(topic,current)[words[1]:words[1]+words[2]]
            return abi(32,len(rows),*[digest(bytes.fromhex(x["claim"][2:]+topic[2:]))for x in rows])
        claim=topic;topic="0x"+f"{words[1]:064x}"
        listed=any(x["claim"]==claim for x in self.listed(topic,current))
        if sig=="isListed(bytes32,bytes32)":return abi(int(listed))
        if sig=="entryOf(bytes32,bytes32)":return abi(int(listed),1,0,0,6,0,1793090000)
        raise ValueError("Unsupported call")
    def metadata(self,ref):
        x=next((x for x in self.items if x["meta_ref"][2:]==ref),None)
        if not x or self.mode=="unavailable":return None
        return x["metadata"]+b" " if self.mode=="tamper" else x["metadata"]

def serve(args):
    model=SearchModel(args.assets)
    manifest=json.loads((args.assets/"asset-hashes.json").read_text())
    app_origin=content_origin=""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def reply(self,status,value,kind="application/json"):
            data=value if isinstance(value,bytes) else json.dumps(value).encode()
            self.send_response(status)
            for k,v in {"Content-Type":kind,"Content-Length":str(len(data)),"Cache-Control":"no-store","Access-Control-Allow-Origin":app_origin,"X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer"}.items():self.send_header(k,v)
            if self.server.content:self.send_header("Content-Security-Policy","default-src 'none'; sandbox")
            self.end_headers()
            try:self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError):pass
        def do_GET(self):
            if self.headers.get("Host")!=self.server.host:return self.reply(403,{})
            path=urlsplit(self.path).path
            if self.server.content:
                x=next((x for x in model.items if path=="/bytes/"+x["content_ref"][2:]),None)
                return self.reply(200,x["content"],"text/plain")if x else self.reply(404,{})
            if path=="/fixture/viewport":
                params=parse_qs(urlsplit(self.path).query)
                width=max(240,min(1920,int(params.get("width",["390"])[0])))
                height=max(240,min(1200,int(params.get("height",["844"])[0])))
                scale=200 if params.get("text",["100"])[0]=="200" else 100
                page=f'<!doctype html><html><head><title>Reader viewport test</title></head><body style="margin:12px;background:#ddd"><iframe title="Reader viewport" width="{width}" height="{height}" src="/?text={scale}" style="border:1px solid #555"></iframe></body></html>'
                return self.reply(200,page.encode(),"text/html")
            if path=="/fixture/text.css":return self.reply(200,b":root { font-size: 200%; }","text/css")
            if path=="/fixture/profile.json":return self.reply(200,model.profile(app_origin,content_origin))
            if path=="/fixture/categories.json":return self.reply(200,model.graph)
            if path=="/fixture/status":return self.reply(200,model.status())
            if path.startswith("/bytes/"):
                data=model.metadata(path.removeprefix("/bytes/"))
                return self.reply(200,data,"application/octet-stream")if data is not None else self.reply(404,{})
            name="index.html"if path=="/"else path[1:]
            if name not in manifest:return self.reply(404,{})
            data=(args.assets/name).read_bytes()
            if hashlib.sha256(data).hexdigest()!=manifest[name]:return self.reply(500,{"error":"Rebuild requires fixture restart"})
            if name=="index.html" and parse_qs(urlsplit(self.path).query).get("text")==["200"]:
                data=data.replace(b"</head>",b'<link rel="stylesheet" href="/fixture/text.css"></head>')
            return self.reply(200,data,"application/wasm"if name.endswith(".wasm")else mimetypes.guess_type(name)[0]or"text/plain")
        def do_POST(self):
            if self.server.content or self.headers.get("Host")!=self.server.host or self.headers.get("Origin")not in [None,app_origin]:return self.reply(403,{})
            length=int(self.headers.get("Content-Length",0))
            if not 1<=length<=65536:return self.reply(413,{})
            body=json.loads(self.rfile.read(length))
            try:
                if self.path=="/fixture/control":return self.reply(200,model.control(body["mode"]))
                if self.path=="/fixture/rpc":return self.reply(200,{"jsonrpc":"2.0","id":body["id"],"result":model.rpc(body["method"],body.get("params",[]))})
                return self.reply(404,{})
            except (ValueError,KeyError,IndexError):return self.reply(200,{"jsonrpc":"2.0","id":body.get("id"),"error":{"code":-32000,"message":"Prepared read rejected"}})
    app=ThreadingHTTPServer(("127.0.0.1",args.port),Handler);app.host=f"127.0.0.1:{app.server_port}";app.content=False;app_origin="http://"+app.host
    content=ThreadingHTTPServer(("127.0.0.1",0),Handler);content.host=f"127.0.0.1:{content.server_port}";content.content=True;content_origin="http://"+content.host
    args.output.mkdir(parents=True,exist_ok=True)
    raw=json.dumps(model.profile(app_origin,content_origin)).encode()
    session={"kind":"reader-ui-fixture","url":app_origin,"contentOrigin":content_origin,"profileUrl":app_origin+"/fixture/profile.json","fingerprint":digest(raw),"realChain":False,"assets":manifest}
    (args.output/"session.json").write_text(json.dumps(session,indent=2))
    (args.output/"categories.json").write_text(json.dumps(model.graph))
    (args.output/"profile.json").write_bytes(raw)
    print(json.dumps(session),flush=True)
    threading.Thread(target=content.serve_forever,daemon=True).start()
    try:app.serve_forever()
    except KeyboardInterrupt:pass
    finally:app.server_close();content.shutdown();content.server_close()
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--assets",type=Path,default=ROOT/"dist/search");p.add_argument("--output",type=Path,required=True);p.add_argument("--port",type=int,default=0);serve(p.parse_args())
