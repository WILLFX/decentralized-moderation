#!/usr/bin/env python3
"""Mutation campaign for src/v3/Moderation.sol.

The acceptance bar: for each invariant, a test that FAILS if the invariant is
removed. Each mutation deletes one property from the source; the suite must go
red. A survivor is a missing test, reported rather than tuned away.
"""
import subprocess, sys, re, os

FORGE = os.environ.get("FORGE", "forge")

SRC = "src/v3/Moderation.sol"
ORIG = open(SRC).read()

MUTATIONS = [
 # --- the verdict arithmetic (§4.5) --------------------------------------
 ("M1", "I12/§4.5", "A/N instead of the add-one estimator â",
  "        uint256 den = uint256(c.pooledApprove) + c.pooledReject + 2; // N + 2, >= 2 ALWAYS\n        uint256 num = uint256(c.pooledApprove) + 1; // A + 1",
  "        uint256 den = uint256(c.pooledApprove) + c.pooledReject; // A/N\n        uint256 num = uint256(c.pooledApprove);"),

 ("M2", "I22/§4.5", "modulo comparison instead of cross-multiplied",
  "            if (u * den < num << 128) tickets += 1;",
  "            if (u % den < num) tickets += 1;"),

 ("M3", "§4.5", "two tickets instead of three",
  "        for (uint256 i; i < 3; ++i) {",
  "        for (uint256 i; i < 2; ++i) {"),

 ("M4", "§4.5", "majority threshold moved to 1 of 3",
  "        verdict = tickets >= 2 ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);",
  "        verdict = tickets >= 1 ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);"),

 ("M5", "§4.5", "the three uniforms share one index (no independence)",
  "                uint256(keccak256(abi.encode(OUTCOME_DOMAIN, block.chainid, address(this), caseId, i, entropy)))",
  "                uint256(keccak256(abi.encode(OUTCOME_DOMAIN, block.chainid, address(this), caseId, uint256(0), entropy)))"),

 ("M6", "§4.5/§8.5", "re-read blockhash instead of the stored entropy",
  "        if (c.outcomeEntropy != bytes32(0)) {\n            _finalize(caseId, c.outcomeEntropy);\n            return;\n        }\n",
  ""),

 ("M7", "§4.5", "the N>0 guard the spec used to ask for — a revert inside DRAW",
  "        uint256 sb = c.outcomeSeedBlock;",
  "        if (uint256(c.pooledApprove) + c.pooledReject == 0) revert WrongPhase();\n        uint256 sb = c.outcomeSeedBlock;"),

 ("M8", "§8.3", "unanimousDraw set on a 2/1 draw",
  "        c.unanimousDraw = (tickets == 0 || tickets == 3);",
  "        c.unanimousDraw = (tickets >= 2);"),

 # --- the guards (§4.3, I18, I29) ----------------------------------------
 ("M9", "I29/§3.1", "eligibility head guard replaced by a hash observation",
  "        if (block.number <= sb) revert SeedNotYet();\n        if (block.number > sb + p.blockhashHorizon) revert SeedExpired();\n\n        bytes32 seed = blockhash(sb);",
  "        bytes32 seed = blockhash(sb);\n        if (seed == bytes32(0)) revert SeedNotYet();"),

 ("M10", "I29/§3.1", "eligibility tail guard removed",
  "        if (block.number > sb + p.blockhashHorizon) revert SeedExpired();\n", ""),

 ("M11", "I29/§7.3", "draw guard replaced by a hash observation",
  "        if (block.number > sb + p.blockhashHorizon) {\n            _payBounty(caseId, false, msg.sender);\n            _toUnresolved(caseId, Reason.NO_RANDOMNESS);\n            return;\n        }\n        if (block.number <= sb) revert SeedNotYet();",
  "        if (blockhash(sb) == bytes32(0)) {\n            _payBounty(caseId, false, msg.sender);\n            _toUnresolved(caseId, Reason.NO_RANDOMNESS);\n            return;\n        }"),

 ("M12", "§4.8b", "a quorum gate restored at round-0 commit close",
  "        if (c.round == 0 && c.commitsThisRound == 0) {",
  "        if (c.round == 0 && c.commitsThisRound < 16) {"),

 ("M13", "§4.9", "a quorum gate added to round 1",
  "        if (c.round == 0 && c.commitsThisRound == 0) {\n            _toUnresolved(caseId, Reason.NO_TURNOUT);\n            return;\n        }",
  "        if (c.commitsThisRound == 0) {\n            _toUnresolved(caseId, Reason.NO_TURNOUT);\n            return;\n        }"),

 ("M14", "§4.4", "reveal closes early once everyone has revealed",
  "        if (c.phase != uint8(Phase.REVEAL)) revert WrongPhase();\n        if (block.number < c.phaseDeadline) revert DeadlineNotReached();",
  "        if (c.phase != uint8(Phase.REVEAL)) revert WrongPhase();\n        if (block.number < c.phaseDeadline && c.revealsThisRound < c.commitsThisRound) revert DeadlineNotReached();"),

 ("M15", "§4.4", "tally closes early when unchallenged",
  "        if (c.phase != uint8(Phase.TALLY)) revert WrongPhase();\n        if (block.number < c.phaseDeadline) revert DeadlineNotReached();\n\n        if (c.challenger == address(0)) {",
  "        if (c.phase != uint8(Phase.TALLY)) revert WrongPhase();\n        if (block.number < c.phaseDeadline && c.challenger != address(0)) revert DeadlineNotReached();\n\n        if (c.challenger == address(0)) {"),

 ("M16", "§4.3", "commit accepted at or past the deadline",
  "        if (block.number >= c.phaseDeadline) revert DeadlinePassed();\n        if (commitments[caseId][msg.sender] != bytes32(0)) revert AlreadyCommitted();",
  "        if (commitments[caseId][msg.sender] != bytes32(0)) revert AlreadyCommitted();"),

 # --- I3, I17, I19 -------------------------------------------------------
 ("M17", "I3/§3.4", "the allowance is consumed by reveal, not by commit",
  "        if (commitments[caseId][msg.sender] != bytes32(0)) revert AlreadyCommitted();",
  "        if (revealedVote[caseId][msg.sender] != 0) revert AlreadyCommitted();"),

 ("M18", "I17", "a second challenge overwrites the first",
  "        if (c.challenger != address(0)) revert AlreadyChallenged();\n", ""),

 ("M19", "I19/§4.3", "revealsThisRound not reset at TALLY -> COMMIT",
  "        c.revealsThisRound = 0; // I19 — the field this rule exists for\n", ""),

 ("M20", "I19/§4.1", "the pooled tally reset when round 1 opens",
  "        c.commitsThisRound = 0;\n        c.revealsThisRound = 0; // I19 — the field this rule exists for",
  "        c.commitsThisRound = 0;\n        c.revealsThisRound = 0;\n        c.pooledApprove = 0;\n        c.pooledReject = 0;"),

 ("M21", "I19/§4.3", "terminal left unwritten on the NO_TURNOUT row",
  "        c.terminal = uint8(Terminal.UNRESOLVED);\n        c.unresolvedReason = uint8(r);",
  "        c.unresolvedReason = uint8(r);"),

 # --- the settlement obligations table (§4.8, I25, I30) ------------------
 ("M22", "I25", "the non-reveal debit quantified over terminals, not over the phase",
  "            if (drewVerdict || r != Reason.NO_TURNOUT) {",
  "            if (true) {"),

 ("M23", "I25", "the non-reveal debit removed",
  "                stakeReg.debit(m, caseId, KIND_VOTE, p.revealBond);\n", ""),

 ("M24", "I30", "the incoherence debit fires against the plurality on every terminal",
  "        } else if (r == Reason.NO_RANDOMNESS) {",
  "        } else if (true) {"),

 ("M25", "I30", "NO_RANDOMNESS pays a share (payment without a verdict)",
  "            if (v != c.plurality) {\n                stakeReg.debit(m, caseId, KIND_VOTE, p.penaltyDebit);\n            }",
  "            if (v == c.plurality) {\n                stakeReg.recordParticipation(m, caseId, 1, p.trackDecay);\n            }"),

 ("M26", "I20/I32", "a settlement branch skips the discharge",
  "        stakeReg.discharge(m, caseId, KIND_VOTE);\n        emit VoteClaimSettled(caseId, m);",
  "        if (v != 0) stakeReg.discharge(m, caseId, KIND_VOTE);\n        emit VoteClaimSettled(caseId, m);"),

 ("M27", "§4.6", "the CHALLENGE_BOND debit made conditional on the verdict",
  "        stakeReg.debit(ch, caseId, KIND_CHALLENGE, p.challengeBond);",
  "        if (c.terminal == uint8(Terminal.REJECTED)) stakeReg.debit(ch, caseId, KIND_CHALLENGE, p.challengeBond);"),

 ("M28", "I27", "settlement reads the LIVE parameter block",
  "        Params storage p = _p(caseId);\n        uint8 v = revealedVote[caseId][m];",
  "        Params storage p = paramBlocks[paramsVersion];\n        uint8 v = revealedVote[caseId][m];"),

 # --- §5.3 payment -------------------------------------------------------
 ("M29", "§5.3", "reveals1 bound to revealsThisRound",
  "        uint256 reveals1 = (uint256(c.pooledApprove) + c.pooledReject) - reveals0;",
  "        uint256 reveals1 = c.revealsThisRound;"),

 ("M30", "§4.1", "pot grows by the reserve when round 1 opens",
  "        c.round = 1;\n        c.commitsThisRound = 0;",
  "        c.round = 1;\n        c.pot += c.challengeReserve;\n        c.commitsThisRound = 0;"),

 ("M31", "§5.3", "the division remainder paid to the last claimant",
  "        return (uint256(c.pot) + _activated(caseId)) / W;",
  "        return _ceilDiv(uint256(c.pot) + _activated(caseId), W);"),

 # --- §8.1 / I15 index ---------------------------------------------------
 ("M32", "I15/§8.1", "the UNRESOLVED index write moved out of the terminal",
  "        _settleBounties(caseId);\n        _writeIndex(caseId, IndexStatus.UNRESOLVED);\n", "        _settleBounties(caseId);\n"),

 ("M33", "I15/§8.1", "the FINALIZED index write removed",
  "        _writeIndex(caseId, verdict == uint8(Outcome.APPROVE) ? IndexStatus.APPROVED : IndexStatus.REJECTED);\n", ""),

 ("M34", "§8.2", "the interim plurality write removed",
  "        _writeIndex(caseId, c.plurality == uint8(Outcome.APPROVE) ? IndexStatus.PLURALITY_APPROVE : IndexStatus.PLURALITY_REJECT);\n", ""),

 # --- §4.2 plurality -----------------------------------------------------
 ("M35", "§4.2", "a tie breaks to Approve",
  "        c.plurality = c.pooledApprove > c.pooledReject ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);",
  "        c.plurality = c.pooledApprove >= c.pooledReject ? uint8(Outcome.APPROVE) : uint8(Outcome.REJECT);"),

 # --- §7.2 the schedule --------------------------------------------------
 ("M36", "I7/§7.2", "the round-1 windows dropped from the outcome schedule",
  "            block.number + uint256(commitBlocks) + revealBlocks // round 0\n                + challengeBlocks + uint256(commitBlocks) + revealBlocks // round 1, ALWAYS\n                + p.seedLag",
  "            block.number + uint256(commitBlocks) + revealBlocks + challengeBlocks + p.seedLag"),

 ("M37", "§3.5b/I7", "challenge() arms the round-1 eligibility seed",
  "        c.challenger = msg.sender;\n        stakeReg.createChallengeClaim(msg.sender, caseId, p.challengeBond);",
  "        c.challenger = msg.sender;\n        c.eligSeedBlock = uint40(block.number + p.seedLag);\n        stakeReg.createChallengeClaim(msg.sender, caseId, p.challengeBond);"),

 # --- §8.4 keys ----------------------------------------------------------
 ("M38", "I26/§8.4", "NO_RANDOMNESS releases the claim key",
  "            // NO_RANDOMNESS is TALLIED, so I26 binds: no reachable terminal\n            // releases the key. It carries REJECTED's reservation BY REFERENCE.\n            reservationOf[key] = Reservation.PERMANENT;",
  "            reservationOf[key] = Reservation.FREE;"),

 ("M39", "§8.4", "NO_TURNOUT reserves the key",
  "            reservationOf[key] = Reservation.FREE;\n        } else if (r == Reason.NO_REVEALS) {",
  "            reservationOf[key] = Reservation.PERMANENT;\n        } else if (r == Reason.NO_REVEALS) {"),

 ("M40", "§8.4", "NO_REVEALS refunds the pot instead of carrying it",
  "            carriedPot[key] = c.pot;\n            refundOwed[caseId] -= c.pot;", "            carriedPot[key] = 0;"),

 ("M41", "§8.4", "policyVersion folded into the claim key",
  '        public\n        pure\n        returns (bytes32)\n    {\n        return keccak256(abi.encode("LIST", contentHash, metaHash, topics));',
  '        public\n        view\n        returns (bytes32)\n    {\n        return keccak256(abi.encode("LIST", contentHash, metaHash, topics, paramsVersion));'),

 # --- §10 / I31 ----------------------------------------------------------
 ("M42", "I31/§10", "the BLOCK_TIME bound not enforced",
  "        if (cb > uint256(p.seedLag) + uint256(p.blockhashHorizon)) revert CommitWindowExceedsSeedHorizon();\n", ""),

 ("M45", "I26/§8.5", "a re-review's NO_TURNOUT releases a previously tallied key",
  "        bool tallied = (uint256(c.pooledApprove) + c.pooledReject) >= 1;\n        if (tallied) {\n            reservationOf[key] = Reservation.PERMANENT;\n        } else if (r == Reason.NO_TURNOUT) {",
  "        if (r == Reason.NO_TURNOUT) {"),

 ("M46", "§4.8", "DRAW_BOUNTY retained instead of refunded where DRAW is unreachable",
  "        refundOwed[caseId] += c.drawBounty;\n        c.drawBounty = 0;",
  "        maintenanceAccrued += c.drawBounty;\n        c.drawBounty = 0;"),

 ("M47", "§4.8/§10", "CLAIM_BOUNTY refunded too — the change §10 says must not ride along",
  "        maintenanceAccrued += c.claimBounty;\n        c.claimBounty = 0;",
  "        refundOwed[caseId] += c.claimBounty;\n        c.claimBounty = 0;"),

 ("M48", "§5.6.1", "the sweep zeroes the accumulator without forwarding it",
  "        maintenanceAccrued = 0;\n        address(token).safeApprove(address(stakeReg), amount);\n        stakeReg.depositMaintenance(amount);",
  "        maintenanceAccrued = 0;"),

 ("M49", "§5.6.1", "the sweep forwards without zeroing — a second sweep double-spends",
  "        maintenanceAccrued = 0;\n        address(token).safeApprove",
  "        address(token).safeApprove"),

 ("M50", "§8.3", "reopen opens no question against the entries it already wrote",
  "        questionOpen[caseId] = true;\n        uint256 nt = c.topicCount;\n        for (uint256 i; i < nt; ++i) {\n            index.openQuestion(c.claimKey, caseTopics[caseId][i]);\n        }\n\n",
  ""),

 ("M51", "§8.3", "the re-review's terminal never closes the question it opened",
  "        if (questionOpen[caseId] && s != IndexStatus.PLURALITY_APPROVE && s != IndexStatus.PLURALITY_REJECT) {",
  "        if (false) {"),

 ("M52", "§8.3", "the interim TALLY write closes the question early",
  "        if (questionOpen[caseId] && s != IndexStatus.PLURALITY_APPROVE && s != IndexStatus.PLURALITY_REJECT) {",
  "        if (questionOpen[caseId]) {"),

 ("M53", "§8.3", "strict is written on every status, not only a drawn APPROVED",
  "        bool strict = (s == IndexStatus.APPROVED) && _strict(caseId);",
  "        bool strict = _strict(caseId);"),

 # --- §8.5 ---------------------------------------------------------------
 ("M43", "§8.5", "reopen permitted while claims are outstanding",
  "        if (openVoteClaims[caseId] != 0) revert ClaimsOutstanding();\n", ""),

 ("M44", "§8.5", "reopen resets the pooled tally",
  "        c.commitsThisRound = 0;\n        c.revealsThisRound = 0;\n        c.challenger = address(0);",
  "        c.commitsThisRound = 0;\n        c.revealsThisRound = 0;\n        c.pooledApprove = 0;\n        c.pooledReject = 0;\n        c.challenger = address(0);"),
]


def run():
    r = subprocess.run([FORGE, "test", "--match-path", "test/v3/Moderation.t.sol"],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "Compiler run failed" in out:
        return None  # the mutation never ran — not a kill
    return sorted(set(re.findall(r"\[FAIL[^\]]*\]\s+(\w+)\(", out)))


results = []
for mid, inv, desc, old, new in MUTATIONS:
    if old not in ORIG:
        print(f"{mid}: PATTERN NOT FOUND", flush=True)
        results.append((mid, inv, desc, "PATTERN-MISS", []))
        continue
    open(SRC, "w").write(ORIG.replace(old, new, 1))
    failed = run()
    open(SRC, "w").write(ORIG)
    status = "INVALID" if failed is None else ("KILLED" if failed else "SURVIVED")
    failed = failed or []
    results.append((mid, inv, desc, status, failed))
    print(f"{mid} [{inv}] {status}: {desc}", flush=True)
    for f in failed[:3]:
        print(f"      caught by {f}", flush=True)

open(SRC, "w").write(ORIG)

print("\n" + "=" * 72, flush=True)
survived = [r for r in results if r[3] != "KILLED"]
print(f"{len(results)-len(survived)}/{len(results)} mutations killed", flush=True)
if survived:
    print("\nSURVIVORS — missing tests, reported not tuned away:", flush=True)
    for mid, inv, desc, status, _ in survived:
        print(f"  {mid} [{inv}] {status}: {desc}", flush=True)
