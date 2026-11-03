"""Existing-work UI checkpoints; synthetic accounts and RPC only."""
import argparse
from pathlib import Path
import serve_moderator as base
import serve_search as search
from serve_publisher_expiry import PublisherExpiryModel


class ExistingProfile:
    def profile(self, origin, content_origin):
        p=super().profile(origin,content_origin)
        p['purpose']='existingWork'
        p.pop('upload',None)
        return p


class PublisherModel(ExistingProfile,PublisherExpiryModel):
    def __init__(self,assets):
        super().__init__(assets)
        self.checkpoint('initial-final')

    def status(self):
        return {**super().status(), 'refunds': {str(k): str(v) for k, v in self.refunds.items()}}


class ReaderModel(ExistingProfile,search.SearchModel):
    pass


class ModeratorModel(ExistingProfile,base.Model):
    def __init__(self,assets):
        super().__init__(assets)
        self.staked=False
        self.frozen_until=0
        self.transactions={}
        self.next_nonce=9

    def rpc(self,method,params):
        if method=='eth_getTransactionCount':return hex(self.next_nonce)
        if method=='eth_getTransactionByHash':return self.transactions.get(params[0])
        if method=='eth_call':
            data=params[0]['data']
            if data[:10]==base.digest(b'infoOf(address)')[:10]:
                super().rpc(method,params)  # Retain the existing pin/target checks.
                return base.abi(int(self.staked),self.frozen_until,sum(not v[4] for v in self.votes.values()),0)
            if data[:10]==base.digest(b'allowance(address,address)')[:10]:
                super().rpc(method,params)
                return base.abi(0)
        return super().rpc(method,params)

    def control(self,body):
        command=body.get('command')
        if command=='stake-state':
            self.staked=bool(body['staked'])
            self.frozen_until=int(body.get('frozenUntil',0))
            self.refresh()
            return self.status()
        if command=='prepare-completion':
            self.staked=True
            self.mode='finalized'
            self.votes[1]=[1,1,0,1,0]
            self.refresh()
            return self.status()
        if command=='advance-finality':
            self.refresh()
            return self.status()
        return super().control(body)

    def wallet(self,method,params):
        if method!='eth_sendTransaction':return super().wallet(method,params)
        tx=params[0]
        if tx.get('nonce')!=hex(self.next_nonce):raise ValueError('Expected journaled nonce')
        if tx['to'].lower()==self.addresses['stakes']:
            if tx['data']!=base.digest(b'withdraw()')[:10] or not self.staked or self.frozen_until>self.clock or any(not v[4] for v in self.votes.values()):
                raise ValueError('Withdrawal unavailable')
            if tx['from'].lower()!=self.account or tx['chainId']!='0x27d8' or tx['value']!='0x0':
                raise ValueError('Wrong synthetic withdrawal context')
            self.staked=False
            self.refresh()
            h=base.digest(f'existing-work/withdraw/{len(self.sends)}'.encode())
            self.sends.append({'action':'withdraw()','hash':h})
            self.receipts[h]={'transactionHash':h,'blockNumber':self.latest['number'],'blockHash':self.latest['hash'],'status':'0x1'}
        else:
            h=super().wallet(method,params)
        receipt=self.receipts[h]
        self.transactions[h]={'hash':h,'from':tx['from'],'to':tx['to'],'input':tx['data'],
            'value':tx['value'],'nonce':tx['nonce'],'blockNumber':receipt['blockNumber'],'blockHash':receipt['blockHash']}
        self.next_nonce+=1
        return h

    def status(self):
        return {**super().status(),'staked':self.staked,'frozenUntil':self.frozen_until,'transactions':self.transactions}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--role',choices=['publisher','moderator','reader'],required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--port',type=int,default=0)
    args=p.parse_args()
    args.assets=base.ROOT/'dist'/('search' if args.role=='reader' else args.role)
    if args.role=='reader':search.serve(args,ReaderModel)
    else:base.serve(args,PublisherModel if args.role=='publisher' else ModeratorModel)
