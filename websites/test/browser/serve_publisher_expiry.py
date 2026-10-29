"""Read-only publisher recovery checkpoints; synthetic wallet and chain only."""
import argparse
from pathlib import Path
from serve_publisher import PublisherModel
from serve_moderator import ROOT, abi, digest, serve
READ=digest(b'outcomeRecoveryOf(uint256)')[:10]
class PublisherExpiryModel(PublisherModel):
    kind='publisher-expiry-ui-fixture'
    def __init__(self,assets):
        super().__init__(assets)
        self.recovery_reads=[]
        self.checkpoint('recoverable')
    def checkpoint(self,name):
        ages={'recoverable':300,'boundary':8191,'expired':8192,'cached':20000,'unverified':20000,'initial-final':8192,'challenge-final':8192}
        if name not in ages: raise ValueError('Unknown expiry checkpoint')
        target=100
        self.height=target+ages[name]-3;self.refresh()
        self.cases[1]={'content':self.content,'meta':self.meta,'claim':digest(b'synthetic publication'),'topics':[self.topic],'submitter':self.account,'phase':6 if name=='initial-final' else 5 if name=='challenge-final' else 3,'deadline_a':self.clock-3000,'deadline_b':self.clock-2000,'reveal_deadline':self.clock-10,'finalized_at':self.clock if name.endswith('final') else 0,'verdict':1 if name=='challenge-final' else 0,'fee':self.minimum,'outcome_target':target,'round':1 if name in ['expired','challenge-final'] else 0,'checkpoint':name}
        self.refunds[1]=self.minimum if name=='initial-final' else 0
        self.capture()
    def case_info(self,c):
        raw=super().case_info(c);w=[int(raw[i:i+64],16) for i in range(2,len(raw),64)]
        w[8]=c['round'];w[13]=c['outcome_target'];w[17:21]=[3,3,4,2]
        if c['round']:w[21]=1
        return abi(*w)
    def rpc(self,method,params):
        if method=='eth_call' and params[0]['data'].startswith(READ):
            super().rpc(method,[{**params[0],'data':digest(b'guidelinesVersion()')[:10]},params[1]])
            c=self.snapshots[params[1]['blockHash']]['cases'][1]
            self.recovery_reads.append({'pin':params[1],'checkpoint':c['checkpoint']})
            if c['checkpoint']=='unverified': raise ValueError('Synthetic capability unavailable')
            return abi(1,digest(b'original draw hash') if c['checkpoint']=='cached' else 0,c['outcome_target']+8191,int(c['checkpoint'].endswith('final')))
        return super().rpc(method,params)
    def control(self,body):
        if body.get('command')=='expiry-checkpoint':self.checkpoint(body['checkpoint']);return {'checkpoint':body['checkpoint']}
        return super().control(body)
    def status(self):return {**super().status(),'recoveryReads':self.recovery_reads}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--assets',type=Path,default=ROOT/'dist/publisher');p.add_argument('--output',type=Path,required=True);p.add_argument('--port',type=int,default=0)
    serve(p.parse_args(),PublisherExpiryModel)
