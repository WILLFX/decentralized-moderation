#!/usr/bin/env python3
"""Mutation campaign for src/v3/RulesetGovernor.sol.

For each mutation: remove one property's enforcement from the source, run the
v3 suite, and record which tests fail. A mutation that kills NOTHING is a
finding about the test suite, not a passing grade.

INVALID means the mutant did not compile, so it never ran. It is NOT a kill.
See README — this harness family has scored compile failures as kills twice,
both times on a mutation that introduced a state read into a `pure` function.
`paramsHash` and `_validateParams` are both `pure` here, so the trap is live.
"""
import subprocess, sys, re, os

FORGE = os.environ.get("FORGE", "forge")
SRC = "src/v3/RulesetGovernor.sol"
ORIG = open(SRC).read()

# (id, property, description, old, new)
MUTATIONS = [
 # --- the timelock, which is the whole point of the contract -----------------
 ("M1", "timelock", "executeParams ignores the eta",
  "        if (block.timestamp < pp.eta) revert TimelockNotElapsed();\n        if (keccak256(abi.encode(p)) != pp.hash) revert ProposalMismatch();",
  "        if (keccak256(abi.encode(p)) != pp.hash) revert ProposalMismatch();"),

 ("M2", "timelock", "the params eta comparison is inverted",
  "        if (block.timestamp < pp.eta) revert TimelockNotElapsed();",
  "        if (block.timestamp > pp.eta) revert TimelockNotElapsed();"),

 ("M3", "timelock", "executeGuidelines ignores the eta",
  "        if (block.timestamp < pg.eta) revert TimelockNotElapsed();\n",
  ""),

 ("M4", "timelock", "the delay is zero - a proposal is executable in its own block",
  "        uint40 eta = uint40(block.timestamp + timelockDelay);\n        pendingParams = Pending({hash: h, eta: eta, exists: true});",
  "        uint40 eta = uint40(block.timestamp);\n        pendingParams = Pending({hash: h, eta: eta, exists: true});"),

 ("M5", "timelock", "a replacement INHERITS the elapsed time instead of resetting it",
  "        uint40 eta = uint40(block.timestamp + timelockDelay);\n        pendingParams = Pending({hash: h, eta: eta, exists: true});\n        emit ParamsProposed(h, eta, p);",
  "        uint40 eta = pendingParams.exists ? pendingParams.eta : uint40(block.timestamp + timelockDelay);\n        pendingParams = Pending({hash: h, eta: eta, exists: true});\n        emit ParamsProposed(h, eta, p);"),

 # --- §3: execute names what it executes ------------------------------------
 ("M6", "§3/swap", "executeParams accepts parameters that are not the pending ones",
  "        if (keccak256(abi.encode(p)) != pp.hash) revert ProposalMismatch();\n",
  ""),

 ("M7", "§3/swap", "executeGuidelines accepts a hash that is not the pending one",
  "        if (hash != pg.hash) revert ProposalMismatch();\n",
  ""),

 ("M8", "§3", "the pending record survives a successful execute - replayable",
  "        delete pendingParams;\n        version = moderation.applyParams(p);",
  "        version = moderation.applyParams(p);"),

 ("M9", "§3", "the pending guidelines record survives execute",
  "        delete pendingGuidelines;\n        emit GuidelinesExecuted",
  "        emit GuidelinesExecuted"),

 ("M10", "§3", "executeParams runs with nothing pending",
  "        if (!pp.exists) revert NoPendingProposal();\n        if (block.timestamp < pp.eta)",
  "        if (block.timestamp < pp.eta)"),

 # --- binding (M2.6-F3) ------------------------------------------------------
 ("M11", "F3", "bind does not check that the binding is mutual",
  "        if (m.governor() != address(this)) revert BindingNotMutual();\n",
  ""),

 ("M12", "F3", "bind is not one-way",
  "        if (address(moderation) != address(0)) revert AlreadyBound();\n",
  ""),

 ("M13", "F3", "executeParams proceeds while unbound",
  "        if (address(moderation) == address(0)) revert NotBound();\n",
  ""),

 ("M14", "F3", "bind accepts the zero address",
  "        if (address(m) == address(0)) revert ZeroAddress();\n",
  ""),

 # --- §4.1 guidelines --------------------------------------------------------
 ("M15", "§4.1", "guidelinesVersion is assigned rather than incremented",
  "        version = ++guidelinesVersion;",
  "        version = guidelinesVersion = 1;"),

 ("M16", "§4.1", "the version is post-incremented, so the first publication is version 0",
  "        version = ++guidelinesVersion;",
  "        version = guidelinesVersion++;"),

 ("M17", "§4.1", "the text hash is not recorded against the version",
  "        guidelinesHashOf[version] = hash;\n",
  ""),

 ("M18", "§4.1", "the effective block is not recorded",
  "        guidelinesBlockOf[version] = uint40(block.number);\n",
  ""),

 ("M19", "§4.1", "the event omits the version",
  "        emit GuidelinesExecuted(version, hash, block.number);",
  "        emit GuidelinesExecuted(0, hash, block.number);"),

 ("M20", "§4.1", "the event omits the hash",
  "        emit GuidelinesExecuted(version, hash, block.number);",
  "        emit GuidelinesExecuted(version, bytes32(0), block.number);"),

 ("M21", "§4.1", "the event carries the wrong block",
  "        emit GuidelinesExecuted(version, hash, block.number);",
  "        emit GuidelinesExecuted(version, hash, 0);"),

 ("M22", "§4.1", "a zero guidelines hash is accepted",
  "        if (hash == bytes32(0)) revert ZeroHash();\n",
  ""),

 ("M23", "§4.1", "guidelinesVersionAt returns the LATEST rather than the one in force",
  "            if (guidelinesBlockOf[v] <= blockNumber) return v;",
  "            if (guidelinesBlockOf[v] >= blockNumber) return v;"),

 ("M24", "§4.1", "guidelinesVersionAt is off by one at the effective block",
  "            if (guidelinesBlockOf[v] <= blockNumber) return v;",
  "            if (guidelinesBlockOf[v] < blockNumber) return v;"),

 # --- validation -------------------------------------------------------------
 # `_validateParams` is `pure`. A mutation that reads chain state here must relax
 # the mutability too or it does not compile and never runs (README, INVALID).
 ("M25", "§10", "the seed-horizon bound is not checked at propose time",
  "        if (cb > uint256(p.seedLag) + uint256(p.blockhashHorizon)) revert CommitWindowExceedsSeedHorizon();\n",
  ""),

 ("M26", "§10", "the seed-horizon bound puts seedLag on the wrong side",
  "        if (cb > uint256(p.seedLag) + uint256(p.blockhashHorizon)) revert CommitWindowExceedsSeedHorizon();",
  "        if (cb > uint256(p.blockhashHorizon) - uint256(p.seedLag)) revert CommitWindowExceedsSeedHorizon();"),

 ("M27", "validation", "the commit-window block count floors instead of ceiling",
  "        uint256 cb = (uint256(p.commitWindow) + p.blockTime - 1) / p.blockTime;",
  "        uint256 cb = uint256(p.commitWindow) / p.blockTime;"),

 ("M28", "validation", "a zero blockTime is accepted",
  "        if (p.blockTime == 0 || p.commitWindow == 0 || p.revealWindow == 0 || p.challengeWindow == 0) {\n            revert BadParams();\n        }\n",
  ""),

 ("M29", "validation", "the four fee shares may reach or exceed 100%",
  "        if (uint256(p.drawBountyBps) + p.claimBountyBps + p.reserveBps + p.maintenanceBps >= 10_000) {\n            revert BadParams();\n        }\n",
  ""),

 ("M30", "validation", "trackDecay may be 1.0 (no decay) or zero",
  "        if (p.trackDecay == 0 || p.trackDecay >= 1e18) revert BadParams();\n",
  ""),

 ("M31", "validation", "validation is skipped at propose",
  "        _validateParams(p);\n",
  ""),

 # --- governance -------------------------------------------------------------
 ("M32", "gov", "proposeParams is permissionless",
  "    function proposeParams(Moderation.Params calldata p) external onlyGovernance {",
  "    function proposeParams(Moderation.Params calldata p) external {"),

 ("M33", "gov", "executeParams is permissionless",
  "    function executeParams(Moderation.Params calldata p) external onlyGovernance returns (uint32 version) {",
  "    function executeParams(Moderation.Params calldata p) external returns (uint32 version) {"),

 ("M34", "gov", "cancelParams is permissionless",
  "    function cancelParams() external onlyGovernance {",
  "    function cancelParams() external {"),

 ("M35", "gov", "executeGuidelines is permissionless",
  "    function executeGuidelines(bytes32 hash) external onlyGovernance returns (uint32 version) {",
  "    function executeGuidelines(bytes32 hash) external returns (uint32 version) {"),

 ("M36", "gov", "bindModeration is permissionless",
  "    function bindModeration(Moderation m) external onlyGovernance {",
  "    function bindModeration(Moderation m) external {"),

 ("M37", "gov", "governance transfer is one-step",
  "        pendingGovernance = next;\n        emit GovernanceProposed(next);",
  "        governance = next;\n        emit GovernanceProposed(next);"),

 ("M38", "gov", "anyone may accept a pending governance transfer",
  "        if (msg.sender != pendingGovernance) revert NotGovernance();\n",
  ""),

 ("M39", "gov", "the nomination is not cleared on accept",
  "        governance = msg.sender;\n        pendingGovernance = address(0);",
  "        governance = msg.sender;"),

 ("M40", "gov", "governance may be nominated to the zero address",
  "        if (next == address(0)) revert ZeroAddress();\n        pendingGovernance = next;",
  "        pendingGovernance = next;"),

 ("M41", "gov", "the constructor accepts zero governance",
  "        if (_governance == address(0)) revert ZeroAddress();\n",
  ""),

 # --- the hash commitment ----------------------------------------------------
 ("M42", "§3", "the pending hash is not derived from the parameters",
  "        bytes32 h = keccak256(abi.encode(p));",
  "        bytes32 h = keccak256(abi.encode(block.number));"),
]


def run():
    r = subprocess.run([FORGE, "test", "--match-path", "test/v3/*"],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "Compiler run failed" in out or "Error (" in out:
        return None  # the mutation never ran — not a kill
    return sorted(set(re.findall(r"\[FAIL[^\]]*\]\s+(\w+)\(", out)))


# MUTANTS=M7,M12 runs only those, for re-checking a single mutation.
ONLY = set(filter(None, os.environ.get("MUTANTS", "").split(",")))

results = []
for mid, inv, desc, old, new in MUTATIONS:
    if ONLY and mid not in ONLY:
        continue
    if ORIG.count(old) != 1:
        print(f"{mid}: ANCHOR {ORIG.count(old)}x -- {desc}", flush=True)
        results.append((mid, inv, desc, "ANCHOR", []))
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
    print("\nSURVIVORS — reported, not tuned away:", flush=True)
    for mid, inv, desc, status, _ in survived:
        print(f"  {mid} [{inv}] {status}: {desc}", flush=True)
