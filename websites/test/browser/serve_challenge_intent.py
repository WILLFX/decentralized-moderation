"""Keyless loopback checks for bound challenges and exact request recovery."""
import argparse
from pathlib import Path
from serve_moderator_requests import RequestsModel
import serve_moderator as base

SIGNATURE = 'challenge(uint256,uint8,uint8)'
CAPABILITY = base.digest(b'challengeIntentVersion()')[:10]
SELECTOR = base.digest(SIGNATURE.encode())[:10]


class ChallengeModel(RequestsModel):
    kind = 'bound-challenge-ui-fixture'
    capability = 'bound'

    def __init__(self, assets):
        super().__init__(assets)
        self.mod_active = True
        self.challenge_round = 0
        self.preliminary = 1
        self.challenge_phase = 4
        self.challenge_deadline = self.clock + 3600

    def info(self, case, finalized=False):
        raw = super().info(case, finalized)
        values = [int(raw[i:i+64], 16) for i in range(2, len(raw), 64)]
        values[7:10] = [self.challenge_phase, self.challenge_round, self.challenge_deadline]
        values[17:21] = [3, 3, 3, 3]
        values[21] = self.preliminary
        values[23] = int(bool(self.votes))
        return base.abi(*values)

    def control(self, body):
        if body.get('command') == 'advance-challenge-review':
            self.challenge_round = int(body.get('round', 1))
            self.preliminary = int(body.get('outcome', 2))
            self.challenge_phase = 4
            self.refresh()
            self.challenge_deadline = self.clock + 3600
            return {'round': self.challenge_round, 'preliminary': self.preliminary}
        return super().control(body)

    def rpc(self, method, params):
        if method == 'eth_call' and params[0]['data'] == CAPABILITY:
            if params[0]['to'].lower() != self.addresses['moderation']:
                raise ValueError('Wrong capability target')
            # Reuse the strict canonical-checkpoint/target observer before returning a hint.
            base.Model.rpc(self, method, [{**params[0], 'data': base.digest(b'guidelinesVersion()')[:10]}, params[1]])
            if self.capability == 'legacy':
                raise ValueError('Legacy deployment has no capability method')
            return '0x1' if self.capability == 'malformed' else base.abi(2 if self.capability == 'unknown' else 1)
        return super().rpc(method, params)

    def handle_wallet(self, method, params):
        if method != 'eth_sendTransaction':
            return super().handle_wallet(method, params)
        provider, tx = params
        if not tx['data'].startswith(SELECTOR):
            raise ValueError('This fixture accepts only the bound challenge selector')
        if len(tx['data']) != 202 or tx.get('nonce') != hex(self.next_nonce):
            raise ValueError('Wrong ABI size or journaled nonce')
        if provider != 'alpha' or tx['from'].lower() != self.accounts['alpha'] or tx['to'].lower() != self.addresses['moderation'] or tx['chainId'] != '0x27d8' or tx['value'] != '0x0':
            raise ValueError('Wrong synthetic envelope')
        if self.reject_next:
            self.reject_next = False
            class Rejected(ValueError):
                code = 4001
            raise Rejected('Synthetic user rejection')
        if self.hold:
            self.waiting.set()
            try:
                if not self.release_selection.wait(120):
                    raise ValueError('Synthetic held request expired; no send')
            finally:
                self.waiting.clear()
        with self.lock:
            words = [int(tx['data'][i:i+64], 16) for i in range(10, len(tx['data']), 64)]
            case, expected_round, expected_outcome = words
            self.info(case)
            accepted = (self.capability == 'bound' and self.challenge_phase == 4
                        and self.clock < self.challenge_deadline and self.challenge_round < 2
                        and case not in self.votes and expected_round == self.challenge_round
                        and expected_outcome in [1, 2] and expected_outcome == self.preliminary)
            self.refresh()
            h = base.digest(('bound-challenge/' + str(len(self.sends))).encode())
            self.transactions[h] = {'hash': h, 'from': tx['from'], 'to': tx['to'], 'input': tx['data'], 'value': tx['value'], 'nonce': tx['nonce'], 'blockNumber': self.latest['number'], 'blockHash': self.latest['hash']}
            self.receipts[h] = {'transactionHash': h, 'blockNumber': self.latest['number'], 'blockHash': self.latest['hash'], 'status': '0x1' if accepted else '0x0'}
            self.sends.append({'action': SIGNATURE, 'caseId': case, 'round': expected_round, 'preliminary': expected_outcome, 'accepted': accepted, 'hash': h})
            self.selection_calls.append({'provider': provider, 'method': method})
            self.next_nonce += 1
            if accepted:
                self.votes[case] = [1, 0, expected_round, 2 if expected_outcome == 1 else 1, 0]
                self.challenge_round += 1
                self.challenge_phase = 1
            if self.lost_response:
                self.lost_response = False
                raise ValueError('Synthetic response lost after inclusion')
            return h

    def status(self):
        return {**super().status(), 'capability': self.capability, 'challengeRound': self.challenge_round, 'preliminary': self.preliminary, 'phase': self.challenge_phase}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', type=int, default=0)
    p.add_argument('--capability', choices=['bound', 'legacy', 'unknown', 'malformed'], default='bound')
    args = p.parse_args()
    args.assets = base.ROOT / 'dist' / 'moderator'
    bootstrap = Path(__file__).with_name('fixture-wallet-selection.js').read_text(encoding='utf8').replace('__MODE__', 'single').replace('__AUTH_EVENT__', 'false')
    bootstrap = bootstrap.replace('defaultId,listeners:counts', "defaultId,listeners:counts,requests:Object.fromEntries(Object.entries(localStorage).filter(([k])=>k.startsWith('moderator-requests-v1:')))")
    base.WALLET = bootstrap.encode('utf8')
    Model = type('SelectedChallengeModel', (ChallengeModel,), {'capability': args.capability})
    base.serve(args, Model)
