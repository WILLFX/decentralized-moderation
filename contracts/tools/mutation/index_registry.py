#!/usr/bin/env python3
"""Mutation campaign for src/v3/IndexRegistry.sol."""
import subprocess, sys, re, os

FORGE = os.environ.get("FORGE", "forge")
SRC = "src/v3/IndexRegistry.sol"
ORIG = open(SRC).read()

MUTATIONS = [
 ("M1","§8.2","the status enum begins at PLURALITY_APPROVE — NONE is not the zero slot",
  "    enum Status {\n        NONE,\n        PLURALITY_APPROVE,",
  "    enum Status {\n        PLURALITY_APPROVE,\n        NONE,"),
 ("M2","§8.2","Status.NONE accepted as a write",
  "        if (status == uint8(Status.NONE) || status > uint8(Status.REMOVED)) revert BadStatus();\n",""),
 ("M3","§8.2b/I29","the zero-topic guard removed from writeEntry",
  "        if (topicKey == bytes32(0)) revert ZeroTopicKey();\n        if (status == uint8(Status.NONE)",
  "        if (status == uint8(Status.NONE)"),
 ("M4","§8.2b/I29","the zero-topic guard removed from removeListing",
  "        if (topicKey == bytes32(0)) revert ZeroTopicKey();\n        entryKey = entryKeyOf(listClaimKey, topicKey);",
  "        entryKey = entryKeyOf(listClaimKey, topicKey);"),
 ("M5","§8.2b/I29","the position map stores the raw index (M2.6-F1 verbatim)",
  "            posPlusOne[topicKey][entryKey] = listing[topicKey].length; // index + 1",
  "            posPlusOne[topicKey][entryKey] = listing[topicKey].length - 1;"),
 ("M6","§8.2b","the moved element's position is not rewritten after swap-and-pop",
  "            arr[idx] = moved;\n            posPlusOne[topicKey][moved] = idx + 1;",
  "            arr[idx] = moved;"),
 # entryKeyOf is `pure`, so a mutation reading chain state has to relax the
 # mutability too or it does not compile and never runs. See README, INVALID.
 ("M7","§8.2b","the entry key is not content-derived (it varies per block)",
  "    function entryKeyOf(bytes32 claimKey, bytes32 topicKey) public pure returns (bytes32) {\n        return keccak256(abi.encode(claimKey, topicKey));",
  "    function entryKeyOf(bytes32 claimKey, bytes32 topicKey) public view returns (bytes32) {\n        return keccak256(abi.encode(claimKey, topicKey, block.number));"),
 ("M7b","§8.2b","the entry key ignores topicKey — two topics collide on one entry",
  "        return keccak256(abi.encode(claimKey, topicKey));",
  "        return keccak256(abi.encode(claimKey));"),
 ("M8","§8.1","removeListing deletes the entry instead of setting REMOVED",
  "        e.status = uint8(Status.REMOVED);\n        _syncListing(topicKey, entryKey, uint8(Status.REMOVED));",
  "        delete entries[entryKey];\n        _syncListing(topicKey, entryKey, uint8(Status.NONE));"),
 ("M9","§8.1","removeListing sets REMOVED but leaves it listed",
  "        e.status = uint8(Status.REMOVED);\n        _syncListing(topicKey, entryKey, uint8(Status.REMOVED));",
  "        e.status = uint8(Status.REMOVED);"),
 ("M10","§8.1","removeListing accepts an entry that does not exist",
  "        if (e.status == uint8(Status.NONE)) revert NoSuchEntry();\n\n        e.status = uint8(Status.REMOVED);",
  "        e.status = uint8(Status.REMOVED);"),
 ("M11","§8.1","listing membership no longer tracks APPROVED",
  "        bool shouldBeListed = (status == uint8(Status.APPROVED));",
  "        bool shouldBeListed = (status != uint8(Status.NONE));"),
 ("M12","§8.1","a repeated APPROVED write double-lists",
  "            if (p != 0) return; // already listed\n",""),
 ("M13","§8.3","openQuestions is a boolean rather than a counter",
  "        e.openQuestions += 1;","        e.openQuestions = 1;"),
 ("M14","§8.3","closing a question clears the counter outright",
  "        e.openQuestions -= 1;","        e.openQuestions = 0;"),
 ("M15","§8.3","SUPER_SAFE drops the strict conjunct",
  "        return e.strict && e.openQuestions == 0;","        return e.openQuestions == 0;"),
 ("M16","§8.3","SUPER_SAFE drops the openQuestions conjunct",
  "        return e.strict && e.openQuestions == 0;","        return e.strict;"),
 ("M17","§8.3","closeQuestion underflows rather than reverting",
  "        if (e.openQuestions == 0) revert NoQuestionOpen();\n",""),
 ("M18","§8.3","strict is not rewritten by a later terminal",
  "        e.strict = strict;\n","        if (strict) e.strict = true;\n"),
 ("M19","caps","writeEntry is permissionless",
  "        external\n        onlyWriter\n        returns (bytes32 entryKey)",
  "        external\n        returns (bytes32 entryKey)"),
 ("M20","caps","removeListing is permissionless",
  "    function removeListing(bytes32 listClaimKey, bytes32 topicKey) external onlyWriter returns (bytes32 entryKey) {",
  "    function removeListing(bytes32 listClaimKey, bytes32 topicKey) external returns (bytes32 entryKey) {"),
 ("M21","caps","openQuestion is permissionless",
  "    function openQuestion(bytes32 claimKey, bytes32 topicKey) external onlyWriter {",
  "    function openQuestion(bytes32 claimKey, bytes32 topicKey) external {"),
 ("M22","caps","closeQuestion is permissionless",
  "    function closeQuestion(bytes32 claimKey, bytes32 topicKey) external onlyWriter {",
  "    function closeQuestion(bytes32 claimKey, bytes32 topicKey) external {"),
 ("M23","caps","the writer timelock comparison is inverted",
  "        if (block.timestamp < w.eta) revert TimelockNotElapsed();",
  "        if (block.timestamp > w.eta) revert TimelockNotElapsed();"),
 ("M24","caps","executeWriter is permissionless",
  "    function executeWriter() external onlyGovernance {",
  "    function executeWriter() external {"),
 ("M25","§4","listedPage ignores `limit` and walks the whole topic",
  "        uint256 end = offset + limit;\n        if (end > n) end = n;",
  "        uint256 end = n;\n        limit;"),
 ("M26","§4","listedPage reverts past the end instead of returning empty",
  "        if (offset >= n) return new bytes32[](0);",
  "        if (offset >= n) revert BadPage();"),
]

def run():
    r = subprocess.run([FORGE,"test","--match-path","test/v3/*"],capture_output=True,text=True)
    out = r.stdout + r.stderr
    if "Compiler run failed" in out or "Error (" in out:
        return None  # the mutation never ran — not a kill
    return sorted(set(re.findall(r"\[FAIL[^\]]*\]\s+(\w+)\(", out)))

# MUTANTS=M7,M7b runs only those, for re-checking a single mutation.
ONLY = set(filter(None, os.environ.get("MUTANTS", "").split(",")))

results=[]
for mid,inv,desc,old,new in MUTATIONS:
    if ONLY and mid not in ONLY: continue
    if ORIG.count(old)!=1:
        print(f"{mid}: ANCHOR {ORIG.count(old)}x -- {desc}",flush=True); results.append((mid,"ANCHOR",desc)); continue
    open(SRC,"w").write(ORIG.replace(old,new,1))
    failed=run(); open(SRC,"w").write(ORIG)
    st="INVALID" if failed is None else ("KILLED" if failed else "SURVIVED")
    failed = failed or []
    results.append((mid,st,desc))
    print(f"{mid} [{inv}] {st}: {desc}",flush=True)
    for f in failed[:2]: print(f"      caught by {f}",flush=True)
open(SRC,"w").write(ORIG)
surv=[r for r in results if r[1]!="KILLED"]
print(f"\n{len(results)-len(surv)}/{len(results)} mutations killed",flush=True)
if surv:
    print("\nSURVIVORS:",flush=True)
    for m,s,d in surv: print(f"  {m} {s}: {d}",flush=True)
