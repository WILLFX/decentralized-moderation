#!/usr/bin/env python3
"""Loopback UI fixture for the built moderator. Never forwards RPC or signs.

The real Rust/Wasm assets run with a synthetic injected provider. Only index.html
gets a test bootstrap. The observer changes phase through /fixture/control;
actors use the normal application. This is not a contract implementation test.
"""
import argparse
import hashlib
import json
import mimetypes
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent / "simulation"))
from keccak import keccak256  # noqa: E402; existing independently checked codec


def digest(data):
    return "0x" + keccak256(data).hex()


def abi(*values):
    return "0x" + "".join(f"{v:064x}" if isinstance(v, int) else v.removeprefix("0x").zfill(64) for v in values)


def reference(data):
    assert len(data) <= 256 * 1024
    if len(data)>4096:
        children=b"".join(bytes.fromhex(reference(data[i:i+4096])[2:]) for i in range(0,len(data),4096))
        return chunk_reference(children,len(data))
    return chunk_reference(data,len(data))

def chunk_reference(data,span):
    nodes = data.ljust(4096, b"\0")
    while len(nodes) > 32:
        nodes = b"".join(keccak256(nodes[i:i + 64]) for i in range(0, len(nodes), 64))
    return digest(span.to_bytes(8, "little") + nodes)


def commitment(chain, contract, case, round_number, voter, vote, salt):
    encoded = abi(digest(b"commit"), chain, contract, case, round_number, voter, vote, salt)
    return digest(bytes.fromhex(encoded[2:]))


SIGNATURES = ["stakes()", "token()", "index()", "moderation()", "guidelinesVersion()", "guidelinesHash()", "infoOf(address)", "stakeAmount()", "balanceOf(address)", "allowance(address,address)", "caseInfo(uint256)", "voteOf(uint256,address)", "pairScheduleOf(uint256)", "topicsOf(uint256)", "refundOwed(uint256)", "isEligible(uint256,address)", "nextCaseId()", "commit(uint256,bytes32)", "reveal(uint256,uint8,bytes32)", "claim(uint256,address)"]
SELECTORS = {digest(s.encode())[:10]: s for s in SIGNATURES}

FIXTURE_DIR = Path(__file__).resolve().parent
WALLET = (FIXTURE_DIR / "fixture-wallet.js").read_bytes()
ENTRY = (FIXTURE_DIR / "fixture-entry.js").read_bytes()


def fixture_html(data, event_polling=False):
    loader = b'<script type="module" src="./loader.js">'
    if data.count(loader) != 1:
        raise ValueError("Unexpected production entry; refusing an unguarded fixture")
    events = b'<script src="./fixture-events.js"></script>' if event_polling else b''
    return data.replace(loader, events + b'<script src="./fixture-wallet.js"></script><script type="module" src="./fixture-entry.js">')


def viewport_html(path):
    """Automatic viewport; fixed sizes are an explicit synthetic test option."""
    query = parse_qs(urlsplit(path).query)
    def dimension(name, default, maximum):
        try: value = int(query.get(name, [str(default)])[0])
        except (ValueError, TypeError): value = default
        return max(240, min(maximum, value))
    scale = 200 if query.get("text", ["100"])[0] == "200" else 100
    fixed = "width" in query or "height" in query
    dimensions = f'width="{dimension("width",390,1920)}" height="{dimension("height",844,1200)}"' if fixed else ''
    style = 'display:block;border:0;' + ('max-width:none' if fixed else 'width:100%;height:100vh;height:100dvh')
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>Application viewport test</title></head><body style="margin:0">'
            f'<iframe id="application-viewport" title="Application viewport" {dimensions} '
            f'src="/?text={scale}" style="{style}"></iframe></body></html>').encode()


class Model:
    def __init__(self, assets):
        self.assets = assets
        self.lock = threading.RLock()
        self.addresses = {name: "0x" + byte * 20 for name, byte in [("moderation", "10"), ("stakes", "20"), ("index", "30"), ("token", "40")]}
        self.account = "0x" + "50" * 20
        self.codes = {addr: "0x60016000" + f"{i:02x}" for i, addr in enumerate(self.addresses.values(), 1)}
        self.guidelines = (assets / "MODERATION_GUIDELINES.md").read_bytes()
        metadata = {"schemaVersion": 1, "type": "image", "title": "A plain text field note", "description": "An authenticated declaration that needs human checking.", "topics": ["biology"], "language": "en", "contentType": "text/plain", "source": "Synthetic publisher claim"}
        self.metadata = json.dumps(metadata, separators=(",", ":")).encode()
        self.meta = reference(self.metadata)
        self.topic = digest(b"biology")
        self.content = reference(b"Synthetic field note. This is plain text, not an image.")
        self.height = 1000
        self.blocks = {}
        self.votes = {}
        self.receipts = {}
        self.sends = []
        self.mode = "commit"
        self.clock = int(time.time())
        self.created = self.clock
        self.reads = 0
        self.documents = {}
        self.events = []
        self.event_polling = False
        self.refresh()

    def status(self):
        return {"scope": "synthetic UI only", "mode": self.mode, "reads": self.reads, "sends": self.sends, "votes": {str(k): {"revealed": v[3], "settled": bool(v[4])} for k, v in self.votes.items()}}

    def control(self, body):
        mode = body["mode"]
        if mode not in ["commit", "finality-lag", "reveal", "finalized"]: raise ValueError("Unknown phase")
        if mode == "finalized" and any(not v[3] for v in self.votes.values()): raise ValueError("Finish the fixture's reveals first")
        self.mode = mode
        self.refresh()
        return {"mode": mode}

    def handle_wallet(self, method, params):
        with self.lock: return self.wallet(method, params)

    def block(self, number, timestamp):
        result = {"number": hex(number), "timestamp": hex(timestamp), "hash": digest(f"synthetic/{number}/{timestamp}".encode())}
        self.blocks[result["number"]] = result
        return result

    def refresh(self):
        self.height += 3
        self.clock = int(time.time())
        self.latest = self.block(self.height, self.clock)
        finalized_time = self.clock - (605 if self.mode == "finality-lag" else 2)
        self.finalized = self.block(self.height - 2, finalized_time)

    def profile(self, origin, content_origin):
        return {"deployment": {"chainId": "10200", **{name: {"address": addr, "codeHash": digest(bytes.fromhex(self.codes[addr][2:]))} for name, addr in self.addresses.items()}, "guidelines": {"version": "1", "hash": digest(self.guidelines)}}, "rpcUrl": origin + "/fixture/rpc", "guidelinesUrl": origin + "/MODERATION_GUIDELINES.md", "gatewayUrl": content_origin, "metadataPath": "bytes", "contentPath": "bytes", "timing": {"clockErrorSeconds": 5, "maxEvidenceAgeSeconds": 30, "maxHeadLagSeconds": 30, "inclusionBudgetSeconds": 120}, "display": {"decimals": 0, "symbol": "TEST"}}

    def info(self, case, finalized=False):
        if not 1 <= case <= 18:
            raise ValueError("Unknown synthetic case")
        phase = 1 if self.mode == "commit" else 5 if self.mode == "finalized" else 3
        if self.mode == "finality-lag" and finalized: phase = 2
        in_commit = phase in [1, 2]
        vote = self.votes.get(case, [0, 0, 0, 0, 0])
        reveals_a = 0 if in_commit else 2 + int(bool(vote[3]))
        reveals_b = 0 if in_commit else 3
        approves = 0 if in_commit else (2 if case == 17 else 5) + int(vote[3] == 1)
        rejects = 0 if in_commit else (3 if case == 17 else 0) + int(vote[3] == 2)
        verdict = (2 if case == 17 else 1) if phase == 5 else 0
        a_close = self.created + (900 if case == 17 else 720)
        b_close = self.clock - (300 if case == 17 else 600)
        deadline = a_close if phase == 1 else b_close if phase == 2 else b_close + 1800
        # Canonical caseInfo tuple order, matching the contract's 25 fields.
        values = [
            self.content, self.meta, digest(f"claim/{case}".encode()),
            self.account, 1,                        # submitter, topic count
            int(case == 18), 16 if case == 18 else 0,  # REMOVE, target listing
            phase, 0, deadline,                    # phase, challenge round, deadline
            self.clock if phase == 5 else 0,       # finalized at
            800, 900, 0, 0,                        # A/B/outcome seed, eligibility bits
            3 + int(bool(vote[0])), 0 if phase == 1 else 3,
            reveals_a, reveals_b, approves, rejects,
            verdict, 3 if verdict == 1 else 0, 0, 100,
        ]
        return abi(*values)

    def rpc(self, method, params):
        self.reads += 1
        if method == "eth_chainId": return "0x27d8"
        if method == "eth_getBlockByNumber":
            return self.latest if params[0] == "latest" else self.finalized if params[0] == "finalized" else self.blocks[params[0]]
        if method == "eth_getCode": return self.codes[params[0].lower()]
        if method == "eth_getTransactionReceipt": return self.receipts.get(params[0])
        if method != "eth_call": raise ValueError("Read not allowed")
        pin = params[1]
        if not isinstance(pin, dict) or pin.get("blockHash") not in [self.latest["hash"], self.finalized["hash"]]:
            raise ValueError("Prepared UI checkpoint is no longer available")
        call = params[0]
        if call["to"].lower() not in self.codes: raise ValueError("Unknown target")
        data = call["data"]
        signature = SELECTORS[data[:10]]
        words = [int(data[i:i + 64], 16) for i in range(10, len(data), 64)]
        links = {"stakes()": "stakes", "token()": "token", "index()": "index", "moderation()": "moderation"}
        if signature in links: return abi(self.addresses[links[signature]])
        if signature == "guidelinesVersion()": return abi(1)
        if signature == "guidelinesHash()": return abi(digest(self.guidelines))
        if signature == "infoOf(address)": return abi(1, 0, sum(not v[4] for v in self.votes.values()), 0)
        if signature in ["stakeAmount()", "balanceOf(address)", "allowance(address,address)"]: return abi(10 if signature == "stakeAmount()" else 990)
        if signature == "nextCaseId()": return abi(19)
        case = words[0]
        if signature == "caseInfo(uint256)": return self.info(case, params[1].get("blockHash") == self.finalized["hash"])
        if signature == "voteOf(uint256,address)": return abi(*self.votes.get(case, [0, 0, 0, 0, 0]))
        if signature == "pairScheduleOf(uint256)":
            a_close = self.created + (900 if case == 17 else 720)
            b_close = self.clock - (300 if case == 17 else 600)
            return abi(a_close, a_close + 3600, 0, 0) if self.mode == "commit" else abi(b_close - 600, b_close, 0, 0)
        if signature == "topicsOf(uint256)": return abi(self.topic, 0, 0, 0, 0)
        if signature == "refundOwed(uint256)": return abi(0)
        if signature == "isEligible(uint256,address)": return abi(1)
        raise ValueError("Call not allowed")

    def wallet(self, method, params):
        if method in ["eth_requestAccounts", "eth_accounts"]: return [self.account]
        if method == "eth_chainId": return "0x27d8"
        if method != "eth_sendTransaction": raise ValueError("Wallet method not allowed")
        tx = params[0]
        if tx["chainId"] != "0x27d8" or tx["from"].lower() != self.account or tx["to"].lower() != self.addresses["moderation"] or tx["value"] != "0x0": raise ValueError("Unexpected synthetic intent")
        data = tx["data"]
        signature = SELECTORS[data[:10]]
        words = [int(data[i:i + 64], 16) for i in range(10, len(data), 64)]
        case = words[0]
        self.info(case)
        if signature == "commit(uint256,bytes32)":
            if self.mode != "commit" or case in self.votes: raise ValueError("Commit not allowed")
            self.votes[case] = [words[1], 1, 0, 0, 0]
        elif signature == "reveal(uint256,uint8,bytes32)":
            vote = self.votes[case]
            expected = commitment(10200, self.addresses["moderation"], case, 0, self.account, words[1], words[2])
            if self.mode != "reveal" or vote[3] or int(expected, 16) != vote[0]: raise ValueError("Reveal does not match the commitment")
            vote[3] = words[1]
        elif signature == "claim(uint256,address)":
            if self.mode != "finalized" or self.votes[case][4] or words[1] != int(self.account, 16): raise ValueError("Settlement not allowed")
            self.votes[case][4] = 1
        else: raise ValueError("Send not allowed")
        self.refresh()
        tx_hash = digest(f"synthetic/send/{len(self.sends)}".encode())
        self.sends.append({"action": signature, "caseId": case, "hash": tx_hash})
        self.receipts[tx_hash] = {"transactionHash": tx_hash, "blockNumber": self.latest["number"], "blockHash": self.latest["hash"], "status": "0x1"}
        return tx_hash


def serve(args, model_type=Model):
    model = model_type(args.assets.resolve())
    app_origin = ""
    content_origin = ""
    manifest = json.loads((model.assets / "asset-hashes.json").read_text())

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def reply(self, status, value, content_type="application/json"):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(status)
            allowed_origin = self.headers.get("Origin")
            if allowed_origin not in [app_origin, app_origin.replace("127.0.0.1", "localhost")]: allowed_origin = app_origin
            for key, value in {"Content-Type": content_type, "Content-Length": str(len(data)), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Access-Control-Allow-Origin": allowed_origin}.items(): self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.headers.get("Host") not in [self.server.expected_host, self.server.expected_host.replace("127.0.0.1", "localhost")]: return self.reply(403, {"error": "Loopback host required"})
            path = self.path.split("?")[0]
            if self.server.is_content:
                if hasattr(model,"read_document") and path.startswith(("/bytes/","/bzz/")):
                    ref=path.split('/')[2]
                    data=model.read_document(ref)
                    if data is not None: return self.reply(200,data,"text/plain")
                if path == "/bytes/" + model.meta[2:]: return self.reply(200, model.metadata)
                if path == "/bytes/" + model.content[2:]: return self.reply(200, b"Synthetic field note. This is plain text, not an image.", "text/plain")
                return self.reply(404, {})
            if path == "/fixture/viewport":
                return self.reply(200,viewport_html(self.path),"text/html")
            if path == "/fixture-text.css":return self.reply(200,b":root { font-size: 200%; }","text/css")
            if path == "/fixture/profile.json":
                if hasattr(model,"profile_reads"): model.profile_reads+=1
                return self.reply(200, model.profile("http://" + self.headers["Host"], content_origin))
            if path.startswith("/bytes/"):
                ref=path.removeprefix("/bytes/")
                data = model.read_document(ref) if hasattr(model,"read_document") else model.documents.get(ref)
                return self.reply(200, data, "application/octet-stream") if data is not None else self.reply(404, {})
            if path == "/fixture/events":
                with model.lock:
                    events = model.events[:]
                    model.events.clear()
                return self.reply(200, events)
            if path == "/fixture/status":
                with model.lock: return self.reply(200, model.status())
            if path == "/fixture-wallet.js": return self.reply(200, WALLET, "text/javascript")
            if path == "/fixture-events.js" and model.event_polling: return self.reply(200, b'window.__syntheticFixtureEvents = true;', "text/javascript")
            if path == "/fixture-entry.js": return self.reply(200, ENTRY, "text/javascript")
            name = "index.html" if path == "/" else path[1:]
            if name not in manifest: return self.reply(404, {})
            data = (model.assets / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != manifest[name]: return self.reply(500, {"error": "Asset changed; restart fixture after rebuild"})
            if name == "index.html":
                try: data = fixture_html(data, model.event_polling)
                except ValueError: return self.reply(500, {"error": "Test entry bootstrap mismatch; application not served"})
                if parse_qs(urlsplit(self.path).query).get("text")==["200"]:
                    data=data.replace(b"</head>",b'<link rel="stylesheet" href="/fixture-text.css"></head>')
            return self.reply(200, data, "application/wasm" if name.endswith(".wasm") else "text/javascript" if name.endswith(".js") else mimetypes.guess_type(name)[0] or "text/plain")

        def do_POST(self):
            if self.server.is_content: return self.reply(405, {})
            if self.headers.get("Host") not in [self.server.expected_host, self.server.expected_host.replace("127.0.0.1", "localhost")] or self.headers.get("Origin") not in [None, app_origin, app_origin.replace("127.0.0.1", "localhost")]: return self.reply(403, {})
            length = int(self.headers.get("Content-Length", 0))
            limit=256*1024 if self.path=="/bytes" and hasattr(model,"upload") else 65536
            if not ((0 if self.path=="/bytes" and hasattr(model,"upload") else 1) <= length <= limit): return self.reply(413, {})
            body = {}
            try:
                if self.path == "/bytes" and hasattr(model, "upload"):
                    with model.lock: result = model.upload(self.rfile.read(length),dict(self.headers))
                    return self.reply(201, result)
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict): raise ValueError("JSON object required")
                if self.path == "/fixture/wallet": return self.reply(200, {"result": model.handle_wallet(body["method"], body.get("params", []))})
                with model.lock:
                    if self.path == "/fixture/control":
                        return self.reply(200, model.control(body))
                    if self.path == "/fixture/rpc": return self.reply(200, {"jsonrpc": "2.0", "id": body["id"], "result": model.rpc(body["method"], body.get("params", []))})
                return self.reply(404, {})
            except (ValueError, KeyError, TypeError, IndexError, AttributeError) as error:
                request_id = body.get("id") if isinstance(body, dict) else None
                return self.reply(200, {"jsonrpc": "2.0", "id": request_id, "error": {"code": getattr(error,"code",-32000), "message": "Synthetic request rejected"}})

        def do_OPTIONS(self):
            origin=self.headers.get("Origin")
            hosts={self.server.expected_host,self.server.expected_host.replace("127.0.0.1","localhost"),self.server.expected_host.replace("localhost","127.0.0.1")}
            if self.headers.get("Host") not in hosts or origin not in [app_origin,app_origin.replace("127.0.0.1","localhost")]: return self.reply(403,{})
            allowed={"content-type","accept","authorization","swarm-postage-batch-id","swarm-encrypt","swarm-redundancy-level","swarm-act","swarm-deferred-upload"}
            requested={h.strip().lower() for h in self.headers.get("Access-Control-Request-Headers","").split(',') if h.strip()}
            if not requested<=allowed or self.headers.get("Access-Control-Request-Method") not in ["GET","POST"]: return self.reply(403,{})
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin",origin)
            self.send_header("Access-Control-Allow-Methods","GET, POST")
            self.send_header("Access-Control-Allow-Headers",", ".join(sorted(allowed)))
            self.end_headers()

    app = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    app_origin = f"http://127.0.0.1:{app.server_port}"
    app.expected_host = f"127.0.0.1:{app.server_port}"
    app.is_content = False
    content = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    content_origin = f"http://localhost:{content.server_port}"
    content.expected_host = f"localhost:{content.server_port}"
    content.is_content = True
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "profile.json").write_text(json.dumps(model.profile(app_origin, content_origin), indent=2))
    session = {"kind": "moderator-human-ui-fixture", "url": app_origin, "contentOrigin": content_origin, "profile": str((args.output / "profile.json").resolve()), "control": app_origin + "/fixture/control", "status": app_origin + "/fixture/status", "realTransactions": False, "assets": manifest, "htmlTestBootstrap": True, "historyScope": "Prepared UI checkpoints, not a coherent continuous blockchain history. Expired checkpoint eth_call pins are refused."}
    session["kind"] = getattr(model, "kind", session["kind"])
    (args.output / "session.json").write_text(json.dumps(session, indent=2))
    print(json.dumps(session), flush=True)
    threading.Thread(target=content.serve_forever, daemon=True).start()
    try: app.serve_forever()
    except KeyboardInterrupt: pass
    finally: app.server_close(); content.shutdown(); content.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=ROOT / "dist" / "moderator")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0, help="Loopback port; 0 allocates a fresh port")
    serve(parser.parse_args())
