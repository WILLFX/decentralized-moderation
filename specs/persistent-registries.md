# Persistent registries and moderation versions

This contract interface adds replacement authorization to the existing
[moderation rules](protocol.md). The current Chiado release uses this registry family.
Earlier fixed-link deployments retain their own balances, cases and listings.
Their state is not moved into the new family.

## Authority and activation

`ModerationAuthority` identifies one authorization account, a positive notice
period, token and stake amount. Supply the account and
notice period explicitly. The intended public operator is a multisignature wallet;
the contract accepts an account address and does not verify its signer policy.
Each independently operated registry family has its own authority.

The authorizer binds the two registries once. It then proposes an exact moderation
address, runtime code hash and declared configuration fingerprint. A pending
proposal must be cancelled before another can replace it. After the notice period, anyone may activate that exact proposal.
Activation rechecks the code and connections. The first version has the same notice
requirement as a replacement. An activated version cannot be activated again.

Both registries consult the same authority. Activation changes one active opener;
it does not execute two independent registry-link updates. The authorizer cannot
edit a case, directly write a listing, clear an obligation, move custody funds or
revoke an earlier version's completion rights. No emergency suspension is included.

Approval remains a trust decision. Code hashes identify reviewed runtimes, not
their correctness. Approved logic must be immutable code, not a mutable proxy.
The link and fingerprint checks do not prove this property for arbitrary code.
Authorizing malicious code can still damage the shared registry family.

## Case-scoped permissions

Only the active version may register a new listing or removal case. Registration
and the submission fee transfer occur in one reverting transaction. Each case is
identified by its moderation address and local case ID; external references also
identify the chain and registry family.

Every approved version retains authority to finish its registered cases, without
an automatic retirement date. This includes later commitments, both challenge
rounds, reveals, phase advancement, original-hash recovery, expiry, finalization,
settlement and refunds. A challenge is part of its existing case, not a new case.

Stake obligations use `(moderation, caseId, voter)`. An obligation can open once
and settle once. Settling one version's vote cannot discharge another version's
vote. The existing custody balance, additive freezes and total outstanding-vote
count are shared; withdrawal still requires no outstanding votes and no freeze.
The scoped settlement method reads the terminal case and recorded vote from the
originating version. It applies that version's fixed freeze duration.

`Moderation` implements the state machine and calls the authority and registries
directly for opening, obligations, terminal index effects and completion. Voting,
eligibility, reveal, challenge-intent and settlement rules remain unchanged.
Each proposal pins the version's declared token, timing, freeze duration, seed lag,
fee minimum, reveal minimum and guidelines identity through its configuration
fingerprint. Activation rechecks that fingerprint and retains it per version.
This checks the reviewed settings, not arbitrary code behavior. A replacement
cannot change the settings of an earlier case. Shared custody retains its token
and fixed stake amount. This implementation reuses the existing moderation rules;
replacement authorization is not an automatic change to those rules.

Case fees stay in the originating moderation contract. It pays its own rewards
and refunds under the existing rules. No accumulated reward-credit ledger or
transfer of unfinished cases is introduced.

## Listings and removals

The persistent index reads a finalized registered case rather than accepting a
caller-supplied tally or topic list. It applies each case once. Approved listing
rows carry their originating moderation address, case ID and guidelines identity.
Removing a row retains that provenance; it does not delete the content or case.
As in the existing index, another approval of the same claim/topic can update its
current entry facts. Earlier case records remain readable at their origins.

`submitRemoval(address targetModeration, uint256 targetCaseId, uint256 fee)`
allows the active version to review an earlier version's listing. The two-argument
overload targets a listing in the same version. Both copy the target's exact
content, metadata and ordered topics. The authority maintains one open removal
per originating listing across all versions. Any terminal removal releases that
slot; only finalized approval marks the target removed.

## Configuration and client boundary

`contracts/script/Deploy.s.sol` prepares a new authority, two registries
and a moderation version from explicit configuration. It leaves them inactive.
The configured authorizer must call `bindRegistries`, then `propose`; anyone can
call `activate` after the delay. `propose` takes the candidate address, runtime
code hash and expected configuration fingerprint, available as `rulesHash()` on
the reviewed version. The script does not read a signing key or assume
the deploying account is the authorizer. Broadcasting is a separate operator action.

Profiles for persistent deployments include an explicit `deployment.persistent`
object with this shape:

```json
{
  "authority": {"address": "<authority address>", "codeHash": "<runtime hash>"},
  "versions": [{
    "moderation": {"address": "<case contract address>", "codeHash": "<runtime hash>"},
    "guidelines": {"version": 1, "hash": "<guidelines hash>"},
    "rulesHash": "<declared configuration fingerprint>",
    "guidelinesUrl": "https://your-service.example/guidelines-v1.md"
  }]
}
```

These placeholders describe fields, not a usable deployment. Supply actual pins
and a usable guidelines URL for each version. One profile supports up to sixteen
known versions within the existing 64 KiB profile bound. The selected top-level
`moderation`, `guidelines` and `guidelinesUrl` must match a listed version. All
versions share the profile's chain, registries, token and service connections.

Publisher and Moderator expose a Case contract choice in Source & wallet. A choice
uses only the reviewed profile's version list; it is not an automatic redirect to
an unpinned active address. Changing it clears current evidence and requires profile
acceptance and reconnection. Work and publication lists remain scoped to that
selected contract. Select the originating version to return to its work. The file
fingerprint still identifies the supplied profile bytes, including its version
list; choosing a listed version does not rewrite the supplied file.

Before new publication payments, Publisher checks `active()` at the canonical
read block. Existing receipts and refunds remain usable through their original
version. Public histories and encrypted votes retain their original contract
identities. Related unresolved requests remain guarded across known family
versions, and equal numeric case IDs do not combine refunds or vote secrets.

Reader resolves each persistent index row through `originOf`, authenticates that
version's runtime, authority registration and original guidelines identity, and
checks its LIST case and metadata. All related reads use the same canonical block
pin. Opening content repeats origin authentication and current membership at a
fresh block. An unknown version requires an updated trusted profile; the client
does not silently follow it. Single-version profiles retain their existing path.

Read `active`, `registration`, `openRemoval` and `removed` from the authority and
`originOf` from the persistent index. The inherited single-version `moderation`,
`openRemovalOf` and `removed` views are not authoritative cross-version state.
These source changes do not update the published websites or their release profiles.

This is a new registry family. Existing one-time links are not mutable and no
implicit migration, restaking or rewrite of old records is performed.

### Existing-work sources outside a registry family

A top-level profile field, `"purpose": "existingWork"`, limits the matching
client to existing work. Publisher refuses new fee approvals and submissions;
Moderator refuses stake approvals and fresh staking. Receipt recovery, existing
case actions, refunds and eligible withdrawals keep their normal checks. The
purpose does not alter deployment identity, saved request scope or private vote
identity. An omitted purpose retains standard operation; unknown values fail
profile parsing.

This client policy cannot disable old contracts or websites. Separate deployments
keep their own tokens, stakes, cases and index provenance. The
[Chiado existing-work profiles](../deployments/chiado/existing-work/README.md)
retain those original sources without adding them to a persistent authority.
