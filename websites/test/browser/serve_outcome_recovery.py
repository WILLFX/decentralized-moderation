"""Keyless local observer for original-hash recovery controls; not an EVM."""
import argparse
from pathlib import Path
import serve_moderator as base
from serve_moderator_requests import RequestsModel

READ = base.digest(b'outcomeRecoveryOf(uint256)')[:10]
CALLS = {base.digest(s.encode())[:10]: s for s in [
    'draw(uint256)', 'cacheOutcome(uint256)', 'expireOutcome(uint256,uint8,uint40)']}

class RecoveryModel(RequestsModel):
    kind = 'original-outcome-recovery-ui-fixture'
    def __init__(self, assets):
        super().__init__(assets)
        self.mod_active = True
        self.phase = 3
        self.round = 1
        self.target = 100
        self.cached = False
        self.expired = False
        self.capability = 'bound'
        self.refund = 0
        self.mode = 'reveal'

    def info(self, case, finalized=False):
        raw = super().info(case, finalized)
        values = [int(raw[i:i+64],16) for i in range(2,len(raw),64)]
        values[7:10] = [self.phase,self.round,self.clock-10]
        values[13] = self.target
        values[17:22] = [3,3,7,6,1 if self.round else 0]
        return base.abi(*values)

    def control(self, body):
        if body.get('command') == 'recovery-checkpoint':
            name = body['checkpoint']
            ages = {'recoverable':257,'last':8191,'expired':8192,'cached':20000,'initial-expired':8192}
            if name not in ages: raise ValueError('Unknown checkpoint')
            self.phase = 3; self.expired = False; self.refund = 0
            self.round = 0 if name == 'initial-expired' else 1
            self.cached = name == 'cached'
            self.height = self.target + ages[name] - 3
            self.refresh()
            return self.status()
        if body.get('command') == 'recovery-capability':
            self.capability = body['capability']
            if self.capability not in ['bound','error','unknown','malformed']: raise ValueError('Unknown capability')
            return self.status()
        return super().control(body)

    def rpc(self, method, params):
        if method == 'eth_call' and params[0]['data'].startswith(READ):
            base.Model.rpc(self, method, [{**params[0],'data':base.digest(b'guidelinesVersion()')[:10]},params[1]])
            if self.capability == 'error': raise ValueError('Unavailable capability')
            if self.capability == 'malformed': return '0x1'
            return base.abi(2 if self.capability == 'unknown' else 1,
                base.digest(b'original target') if self.cached else 0,self.target+8191,int(self.expired))
        if method == 'eth_call' and params[0]['data'].startswith(base.digest(b'refundOwed(uint256)')[:10]):
            base.Model.rpc(self,method,params)
            return base.abi(self.refund)
        return super().rpc(method,params)

    def handle_wallet(self, method, params):
        if method != 'eth_sendTransaction': return super().handle_wallet(method,params)
        provider, tx = params
        signature = CALLS.get(tx['data'][:10])
        expected = 202 if signature == 'expireOutcome(uint256,uint8,uint40)' else 74
        if signature is None or len(tx['data']) != expected or tx.get('nonce') != hex(self.next_nonce):
            raise ValueError('Wrong intent or nonce')
        if provider != 'alpha' or tx['from'].lower() != self.accounts['alpha'] or tx['to'].lower() != self.addresses['moderation'] or tx['chainId'] != '0x27d8' or tx['value'] != '0x0':
            raise ValueError('Wrong synthetic envelope')
        words = [int(tx['data'][i:i+64],16) for i in range(10,len(tx['data']),64)]
        case = words[0]; self.info(case)
        usable = self.cached or self.target < self.height <= self.target+8191
        accepted = self.phase == 3 and (usable if signature != 'expireOutcome(uint256,uint8,uint40)' else
            not self.cached and self.height > self.target+8191 and words[1:] == [self.round,self.target])
        if accepted:
            if signature == 'cacheOutcome(uint256)': self.cached = True
            elif signature == 'draw(uint256)': self.cached = True; self.phase = 4
            else: self.expired = True; self.phase = 6 if self.round == 0 else 5; self.refund = 100 if self.round == 0 else 0
        self.refresh()
        h = base.digest(('recovery/send/'+str(len(self.sends))).encode())
        self.transactions[h] = {'hash':h,'from':tx['from'],'to':tx['to'],'input':tx['data'],'value':tx['value'],'nonce':tx['nonce'],'blockNumber':self.latest['number'],'blockHash':self.latest['hash']}
        self.receipts[h] = {'transactionHash':h,'blockNumber':self.latest['number'],'blockHash':self.latest['hash'],'status':'0x1' if accepted else '0x0'}
        self.sends.append({'action':signature,'caseId':case,'accepted':accepted,'hash':h})
        self.next_nonce += 1
        if self.lost_response:
            self.lost_response = False
            raise ValueError('Synthetic response lost after inclusion')
        return h

    def status(self):
        return {**super().status(),'phase':self.phase,'round':self.round,'target':self.target,
                'cached':self.cached,'expired':self.expired,'observed':self.height,'capability':self.capability}

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--port',type=int,default=0)
    args=p.parse_args();args.assets=base.ROOT/'dist/moderator'
    bootstrap=Path(__file__).with_name('fixture-wallet-selection.js').read_text(encoding='utf8').replace('__MODE__','single').replace('__AUTH_EVENT__','false')
    base.WALLET=bootstrap.encode('utf8')
    base.serve(args,RecoveryModel)
