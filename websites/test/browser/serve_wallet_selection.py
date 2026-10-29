"""Two independent synthetic wallets for the actual built signing interfaces."""
import argparse, threading
from pathlib import Path
import serve_moderator as base
from serve_publisher import PublisherModel

class SelectionModelMixin:

    def __init__(self, assets):
        super().__init__(assets)
        self.event_polling = True
        self.selection_calls = []
        self.acks = []
        self.sequence = 0
        self.hold = False
        self.waiting = threading.Event()
        self.release_selection = threading.Event()
        self.release_selection.set()
        self.accounts = {'alpha': '0x' + '50' * 20, 'beta': '0x' + '60' * 20}
        if getattr(self, 'same_account', False):
            self.accounts['beta'] = self.accounts['alpha']

    def control(self, body):
        command = body.get('command')
        if command == 'selection-event':
            self.sequence += 1
            event = {**body['event'], 'seq': self.sequence}
            self.events.append(event)
            return {'queued': self.sequence}
        if command == 'hold-selection-send':
            self.hold = True
            self.release_selection.clear()
            return {'held': True}
        if command == 'release-selection-send':
            self.hold = False
            self.release_selection.set()
            return {'held': False}
        return super().control(body)

    def handle_wallet(self, method, params):
        if method == 'fixture_ack':
            with self.lock:
                self.acks.append(params[0])
            return True
        who = params[0]
        if who not in self.accounts:
            raise ValueError('Unknown synthetic provider')
        if method == 'eth_sendTransaction' and self.hold:
            self.waiting.set()
            try:
                if not self.release_selection.wait(120):
                    raise ValueError('Synthetic wait expired without sending')
            finally:
                self.waiting.clear()
        with self.lock:
            self.selection_calls.append({'provider': who, 'method': method})
            if method in ['eth_accounts', 'eth_requestAccounts']:
                return [self.accounts[who]]
            if method == 'eth_chainId':
                return '0x27d8'
            if method != 'eth_sendTransaction':
                raise ValueError('Unsupported wallet method')
            tx = params[1]
            if tx['from'].lower() != self.accounts[who] or tx['chainId'] != '0x27d8' or tx['value'] != '0x0':
                raise ValueError('Wrong original wallet intent')
            if self.role == 'moderator':
                expected = base.digest(b'approve(address,uint256)')[:10] + self.addresses['stakes'][2:].zfill(64) + f'{10:064x}'
                if tx['to'].lower() != self.addresses['token'] or tx['data'] != expected:
                    raise ValueError('Unexpected stake request')
                self.refresh()
                h = base.digest(f'selection/{len(self.sends)}'.encode())
                self.sends.append({'provider': who, 'hash': h, 'action': 'approveStake'})
                self.receipts[h] = {'transactionHash': h, 'blockNumber': self.latest['number'], 'blockHash': self.latest['hash'], 'status': '0x1'}
                return h
            expected = base.digest(b'approve(address,uint256)')[:10] + self.addresses['moderation'][2:].zfill(64) + f'{self.minimum:064x}'
            if tx['to'].lower() != self.addresses['token'] or tx['data'] != expected:
                raise ValueError('Unexpected publisher approval')
            h = base.digest(f'publisher-selection/{len(self.sends)}'.encode())
            nonce = self.next_nonce
            self.next_nonce += 1
            self.transactions[h] = {'hash': h, 'chainId': '0x27d8', 'from': tx['from'], 'to': tx['to'], 'input': tx['data'], 'value': '0x0', 'nonce': hex(nonce), 'blockNumber': None, 'blockHash': None}
            self.sends.append({'provider': who, 'hash': h, 'nonce': hex(nonce), 'to': tx['to'], 'data': tx['data']})
            return h

    def rpc(self, method, params):
        value = super().rpc(method, params)
        if self.role == 'moderator' and method == 'eth_call':
            data = params[0]['data']
            if data.startswith(base.digest(b'infoOf(address)')[:10]):
                return base.abi(0, 0, 0, 0)
            if data.startswith(base.digest(b'allowance(address,address)')[:10]):
                return base.abi(0)
        return value

    def status(self):
        return {**super().status(), 'selectionCalls': self.selection_calls, 'acks': self.acks, 'sendHeld': self.hold, 'sendWaiting': self.waiting.is_set()}
if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--role', choices=['moderator', 'publisher'], default='moderator')
    p.add_argument('--mode', choices=['multi', 'single', 'announced-only', 'legacy', 'none'], default='multi')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', type=int, default=0)
    p.add_argument('--same-account', action='store_true')
    p.add_argument('--authorization-event', action='store_true')
    args = p.parse_args()
    args.assets = base.ROOT / 'dist' / args.role
    base.WALLET = Path(__file__).with_name('fixture-wallet-selection.js').read_bytes().replace(b'__MODE__', args.mode.encode()).replace(b'__AUTH_EVENT__', b'true' if args.authorization_event else b'false')
    Parent = PublisherModel if args.role == 'publisher' else base.Model
    Model = type('SelectionModel', (SelectionModelMixin, Parent), {'role': args.role, 'same_account': args.same_account})
    base.serve(args, Model)
