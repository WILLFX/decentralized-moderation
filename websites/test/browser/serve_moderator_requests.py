"""Keyless loopback observer for durable moderator requests, not a live chain."""
import argparse
from pathlib import Path
import serve_moderator as base
from serve_wallet_selection import SelectionModelMixin
from serve_moderator_timing import TimingModel


class RequestsModel(SelectionModelMixin, base.Model):
    role = 'moderator'

    def __init__(self, assets):
        super().__init__(assets)
        self.transactions = {}
        self.next_nonce = 9
        self.lost_response = False
        self.reject_next = False
        self.mod_active = False

    def control(self, body):
        command = body.get('command')
        if command == 'seed-commitment':
            case = int(body['case'])
            commitment = body['commitment']
            if not 1 <= case <= 18 or not isinstance(commitment, str) or len(commitment) != 66 or not commitment.startswith('0x'):
                raise ValueError('Invalid public synthetic commitment')
            self.votes[case] = [int(commitment, 16), 1, 0, 0, 0]
            return {'case': case, 'commitment': commitment}
        if command == 'moderator-active':
            self.mod_active = body['active']
            return {'active': self.mod_active}
        if command == 'lose-next-response':
            self.lost_response = True
            return {'prepared': True}
        if command == 'reject-next':
            self.reject_next = True
            return {'prepared': True}
        if command == 'advance-finality':
            self.refresh()
            return {'finalized': self.finalized}
        if command in ['speed-up', 'cancel']:
            original = self.sends[-1]['hash']
            h = base.digest((command + original).encode())
            self.refresh()
            self.transactions[h] = {**self.transactions[original], 'hash': h, 'blockNumber': self.latest['number'], 'blockHash': self.latest['hash']}
            if command == 'cancel':
                self.transactions[h].update({'to': self.transactions[h]['from'], 'input': '0x'})
            self.receipts[original] = None
            self.receipts[h] = {'transactionHash': h, 'blockNumber': self.latest['number'], 'blockHash': self.latest['hash'], 'status': '0x1'}
            return {'hash': h, 'original': original}
        if command == 'wrong-transaction':
            original = self.sends[-1]['hash']
            h = base.digest(b'wrong-candidate')
            self.transactions[h] = {**self.transactions[original], 'hash': h, 'nonce': '0x8'}
            self.receipts[h] = {**self.receipts[original], 'transactionHash': h}
            return {'hash': h}
        return super().control(body)

    def handle_wallet(self, method, params):
        # Exercise the original timing observer at the account-read boundary;
        # its output is still supplied by the selected synthetic provider.
        if isinstance(self, TimingModel) and method in ['eth_accounts', 'eth_requestAccounts', 'eth_chainId']:
            with self.lock:
                TimingModel.wallet(self, method, [])
        if method == 'eth_sendTransaction' and params[1].get('nonce') != hex(self.next_nonce):
            raise ValueError('Missing or different journaled nonce')
        if method == 'eth_sendTransaction' and self.reject_next:
            self.reject_next = False
            class Rejected(ValueError):
                code = 4001
            raise Rejected('Synthetic user rejection')
        if method == 'eth_sendTransaction' and params[1]['to'].lower() == self.addresses['moderation']:
            with self.lock:
                self.selection_calls.append({'provider': params[0], 'method': method})
                result = TimingModel.wallet(self, method, [params[1]]) if isinstance(self, TimingModel) else base.Model.wallet(self, method, [params[1]])
        else:
            result = super().handle_wallet(method, params)
        if method == 'eth_sendTransaction':
            with self.lock:
                tx = params[1]
                receipt = self.receipts[result]
                self.transactions[result] = {'hash': result, 'from': tx['from'], 'to': tx['to'], 'input': tx['data'], 'value': tx['value'], 'nonce': tx['nonce'], 'blockNumber': receipt['blockNumber'], 'blockHash': receipt['blockHash']}
                self.next_nonce += 1
                if self.lost_response:
                    self.lost_response = False
                    raise ValueError('Synthetic response lost after broadcast')
        return result

    def rpc(self, method, params):
        if method == 'eth_call' and params[0]['data'].startswith(base.digest(b'infoOf(address)')[:10]) and self.mod_active:
            base.Model.rpc(self, method, params)
            return base.abi(1, 0, 0, 0)
        if method == 'eth_blockNumber':
            return self.latest['number']
        if method == 'eth_getTransactionCount':
            return hex(self.next_nonce)
        if method == 'eth_getTransactionByHash':
            return self.transactions.get(params[0])
        return super().rpc(method, params)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--timing', action='store_true')
    parser.add_argument('--capture-recovery', action='store_true', help='Observe encrypted export blobs in keyless loopback tests only')
    args = parser.parse_args()
    args.assets = base.ROOT / 'dist' / 'moderator'
    bootstrap = Path(__file__).with_name('fixture-wallet-selection.js').read_text(encoding='utf8').replace('__MODE__', 'single').replace('__AUTH_EVENT__', 'false')
    bootstrap = bootstrap.replace('  const listeners = new Map();', """  let failRequestWrites = false;
  const originalSet = Storage.prototype.setItem;
  Storage.prototype.setItem = function(key, value) {
    if (failRequestWrites && key.startsWith('moderator-requests-v1:')) throw new Error('Synthetic storage failure');
    return originalSet.call(this, key, value);
  };
  const listeners = new Map();""")
    bootstrap = bootstrap.replace("        if (event.kind === 'late-beta')", "        if (event.kind === 'request-storage-fault') failRequestWrites = event.enabled;\n        if (event.kind === 'late-beta')")
    bootstrap = bootstrap.replace('defaultId,listeners:counts', "defaultId,listeners:counts,vaultFingerprint:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(localStorage.getItem('moderator-vote-vault-v1')||'')))).map(b=>b.toString(16).padStart(2,'0')).join(''),requests:Object.fromEntries(Object.entries(localStorage).filter(([k])=>k.startsWith('moderator-requests-v1:')))")
    if args.capture_recovery:
        # Observe only the already encrypted export from the normal UI action.
        # This option never exists in packaged website assets.
        bootstrap = bootstrap.replace('  const listeners = new Map();', """  const recoveryExports = [];
  const createObjectURL = URL.createObjectURL.bind(URL);
  URL.createObjectURL = function(blob) {
    if (blob.type === 'application/json') blob.text().then(text => {
      const e = JSON.parse(text);
      if (e.format === 'moderator-vote-vault' && e.cipher && !e.votes) recoveryExports.push(text);
    });
    return createObjectURL(blob);
  };
  const listeners = new Map();""")
        bootstrap = bootstrap.replace('defaultId,listeners:counts,', 'defaultId,listeners:counts,recoveryExports,')
    base.WALLET = bootstrap.encode('utf8')
    model = type('RequestsTimingModel', (RequestsModel, TimingModel), {}) if args.timing else RequestsModel
    base.serve(args, model)
