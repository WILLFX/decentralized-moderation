"""Keyless version/profile checkpoints using the existing fixture servers."""
import argparse
import copy
from pathlib import Path
import serve_moderator as base
import serve_search as search
from serve_publisher import PublisherModel

AUTHORITY = '0x' + '90' * 20
NEXT = '0x' + '11' * 20
ZERO = '0x' + '00' * 20
SIGNATURES = {base.digest(s.encode())[:10]: s for s in [
    'authority()', 'active()', 'codeHashOf(address)', 'rulesHashOf(address)',
    'rulesHash()', 'registration(address,uint256)', 'originOf(bytes32)']}


class Versions:
    def __init__(self, assets):
        super().__init__(assets)
        self.previous = self.addresses['moderation']
        self.codes[AUTHORITY] = '0x6001600090'
        self.codes[NEXT] = '0x6001600011'
        self.active = NEXT if self.role != 'publisher' else self.previous
        self.approved = {self.previous, NEXT} if self.role != 'publisher' else {self.previous}
        self.version_reads = []
        self.bad_origin = False
        self.bad_guidelines = False
        self.bad_registration = False

    def rules(self, address):
        return base.digest(('fixture configuration/' + address).encode())

    def profile(self, origin, content_origin):
        p = super().profile(origin, content_origin)
        d = p['deployment']
        pin = lambda a: {'address': a, 'codeHash': base.digest(bytes.fromhex(self.codes[a][2:]))}
        if self.role == 'reader':
            d['moderation'] = pin(NEXT)
        if self.role == 'reader': d['guidelines']['version'] = 2
        d['persistent'] = {'authority': pin(AUTHORITY), 'versions': [
            {'moderation': pin(a), 'guidelines': copy.deepcopy(d['guidelines']),
             'rulesHash': self.rules(a), 'guidelinesUrl': p.get('guidelinesUrl', './MODERATION_GUIDELINES.md')}
            for a in [self.previous, NEXT]]}
        if self.role == 'reader': d['persistent']['versions'][0]['guidelines']['version'] = 1
        return p

    def status(self):
        return {**super().status(), 'activeVersion': self.active, 'versionReads': self.version_reads}

    def rpc(self, method, params):
        if method == 'eth_call':
            call, pin = params
            sig = SIGNATURES.get(call['data'][:10])
            if sig:
                if not isinstance(pin, dict) or pin.get('requireCanonical') is not True or pin.get('blockHash') not in [b['hash'] for b in self.blocks.values()]:
                    raise ValueError('Canonical fixture block required')
                target = call['to'].lower()
                if target not in self.codes:
                    raise ValueError('Unknown fixture target')
                words = [int(call['data'][i:i+64], 16) for i in range(10, len(call['data']), 64)]
                self.version_reads.append({'target': target, 'signature': sig, 'pin': dict(pin)})
                if sig == 'authority()': return base.abi(AUTHORITY)
                if sig == 'active()': return base.abi(self.active)
                if sig == 'rulesHash()': return base.abi(self.rules(target))
                if sig in ['codeHashOf(address)', 'rulesHashOf(address)']:
                    address = '0x' + f'{words[0]:040x}'
                    if address not in self.approved: return base.abi(0)
                    return base.abi(base.digest(bytes.fromhex(self.codes[address][2:])) if sig == 'codeHashOf(address)' else self.rules(address))
                if sig == 'registration(address,uint256)':
                    owner = '0x' + f'{words[0]:040x}'
                    id = words[1]
                    if self.role == 'reader': terminal = True
                    elif self.role == 'publisher': terminal = self.cases.get(id, {}).get('phase') in [5, 6]
                    else: terminal = self.mode == 'finalized'
                    removal=self.role=='moderator' and id==18
                    known=(1<=id<=len(self.items)) if self.role=='reader' else (id in self.cases) if self.role=='publisher' else (1<=id<=18)
                    return base.abi(int(owner in self.approved and known and not self.bad_registration), int(terminal), self.previous if removal else 0, 16 if removal else 0)
                if sig == 'originOf(bytes32)':
                    key = '0x' + f'{words[0]:064x}'
                    item = next(x for x in self.items if any(base.digest(bytes.fromhex(x['claim'][2:] + t[2:])) == key for t in x['topics']))
                    return base.abi('0x' + '77'*20 if self.bad_origin else self.previous,
                        item['id'], 2 if self.bad_guidelines else 1, base.digest(self.guidelines))
        return super().rpc(method, params)


class ReaderModel(Versions, search.SearchModel):
    role = 'reader'

    def rpc(self, method, params):
        if method == 'eth_call' and params[0]['data'][:10] == base.digest(b'guidelinesVersion()')[:10]:
            # Authenticate old v1 independently from selected v2 at the same pin.
            super().rpc(method, params)
            return base.abi(2 if params[0]['to'].lower() == NEXT else 1)
        if method == 'eth_call' and params[0]['to'].lower() == NEXT and params[0]['data'][:10] in [base.digest(b'caseInfo(uint256)')[:10], base.digest(b'topicsOf(uint256)')[:10]]:
            # Numeric case 1 on the new version describes a different item. A
            # client that follows the selected contract instead of origin fails.
            params = copy.deepcopy(params)
            if int(params[0]['data'][10:], 16) == 1:
                params[0]['data'] = params[0]['data'][:10] + f'{2:064x}'
        return super().rpc(method, params)

    def control(self, mode):
        if mode in ['unknown-origin', 'wrong-guidelines', 'unknown-case']:
            self.bad_origin = mode == 'unknown-origin'
            self.bad_guidelines = mode == 'wrong-guidelines'
            self.bad_registration = mode == 'unknown-case'
            return self.status()
        self.bad_origin = self.bad_guidelines = self.bad_registration = False
        return super().control(mode)


class PublishModel(Versions, PublisherModel):
    role = 'publisher'

    def control(self, body):
        if body.get('command') == 'activate-version':
            self.approved.add(NEXT)
            self.active = NEXT
            self.refresh()
            self.capture()
            return self.status()
        return super().control(body)

    def mine(self, original_hash, kind):
        tx=self.transactions[original_hash]
        target=tx['to'].lower()
        if target==self.addresses['token']:
            target='0x'+f"{int(tx['input'][10:74],16):040x}"
        previous=self.addresses['moderation']
        self.addresses['moderation']=target
        try:return super().mine(original_hash,kind)
        finally:self.addresses['moderation']=previous

    def wallet(self, method, params):
        if method != 'eth_sendTransaction': return super().wallet(method, params)
        tx = params[0]
        target = tx['to'].lower()
        if target == self.addresses['token']:
            target = '0x' + f"{int(tx['data'][10:74], 16):040x}"
        if target not in self.approved: raise ValueError('Unapproved fixture version')
        previous = self.addresses['moderation']
        self.addresses['moderation'] = target
        try: return super().wallet(method, params)
        finally: self.addresses['moderation'] = previous


class ModeratorModel(Versions, base.Model):
    role = 'moderator'


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--role', choices=['reader', 'publisher', 'moderator'], required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', type=int, default=0)
    args = p.parse_args()
    args.assets = base.ROOT / 'dist' / ('search' if args.role == 'reader' else args.role)
    if args.role == 'reader': search.serve(args, ReaderModel)
    else: base.serve(args, PublishModel if args.role == 'publisher' else ModeratorModel)
