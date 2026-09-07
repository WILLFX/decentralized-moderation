#!/usr/bin/env python3
"""Mutation campaign for src/v3/StakeRegistry.sol.

For each mutation: remove one invariant's enforcement from the source, run the
v3 suite, and record which tests fail. A mutation that kills NOTHING is a
finding about the test suite, not a passing grade.
"""
import subprocess, sys, re, os

FORGE = os.environ.get("FORGE", "forge")

SRC = "src/v3/StakeRegistry.sol"
ORIG = open(SRC).read()

# (id, invariant, description, old, new)
MUTATIONS = [
 ("M1","I1a","challenge branch skips the solvency test",
  "        } else if (kind == KIND_CHALLENGE) {\n            if (!mayChallenge(a, amount)) revert Insolvent();",
  "        } else if (kind == KIND_CHALLENGE) {"),

 ("M2","I1a","solvency tested BEFORE the addition (amount excluded)",
  "            if (!mayCommit(a, amount)) revert Insolvent();",
  "            if (!mayCommit(a, 0)) revert Insolvent();"),

 ("M3","I1b","debit may exceed the claim",
  "        if (amount > cl.amount) revert ExceedsClaim();\n","")  ,

 ("M4","I1/5.4","debit clamps instead of reverting",
  "        if (uint256(m.bond) < amount) revert BondUnderflow();",
  "        if (uint256(m.bond) < amount) amount = m.bond;"),

 ("M5","I13","withdraw ignores outstanding liabilities",
  "        if (m.liabilities != 0) revert OutstandingLiabilities();\n",""),

 ("M6","I13","withdraw gates on openVoteCount instead of liabilities",
  "        if (m.liabilities != 0) revert OutstandingLiabilities();",
  "        if (m.openVoteCount != 0) revert OutstandingLiabilities();"),

 ("M7","I16","withdraw leaves exitRequestedAt set",
  "        m.exitRequestedAt = 0; // §2.3 — or NONE and EXITING both hold (I16)\n",""),

 ("M8","I16","stateOf checks PENDING before EXITING (the §2.2 table order)",
  "        if (m.exitRequestedAt != 0) return State.EXITING;\n        if (block.timestamp < m.maturesAt) return State.PENDING;",
  "        if (block.timestamp < m.maturesAt) return State.PENDING;\n        if (m.exitRequestedAt != 0) return State.EXITING;"),

 ("M9","I21","debited value never reaches the reserve",
  "        maintenanceReserve += amount;\n\n        emit Debited(a, caseId, kind, amount);",
  "\n        emit Debited(a, caseId, kind, amount);"),

 ("M10","I21","debit does not decrement totalBond",
  "        totalBond -= amount;\n        maintenanceReserve += amount;",
  "        maintenanceReserve += amount;"),

 ("M11","I23","release does not subtract from liabilities",
  "        m.liabilities -= uint128(amount);\n        if (kind == KIND_VOTE) m.openVoteCount -= 1;",
  "        if (kind == KIND_VOTE) m.openVoteCount -= 1;"),

 ("M12","I23","liabilitiesMatch accepts a duplicate enumeration",
  "                if (caseIds[i] == caseIds[j] && kinds[i] == kinds[j]) revert BadEnumeration();\n",""),

 ("M13","I23","liabilitiesMatch accepts an incomplete enumeration",
  "        if (n != openClaimsOf(a)) revert BadEnumeration();\n",""),

 ("M14","I32b","any logic may discharge any claim",
  "        if (cl.logic != msg.sender) revert NotClaimOwner();\n        _release(a, caseId, kind, k, cl);",
  "        _release(a, caseId, kind, k, cl);"),

 ("M15","I32b","any logic may debit any claim",
  "        if (cl.logic != msg.sender) revert NotClaimOwner();\n        if (amount > cl.amount) revert ExceedsClaim();",
  "        if (amount > cl.amount) revert ExceedsClaim();"),

 ("M16","I32a","release zeroes liabilities instead of subtracting the claim",
  "        m.liabilities -= uint128(amount);",
  "        m.liabilities = 0;"),

 ("M17","caps","MAY_CREATE not required to open a claim",
  "        if (caps[msg.sender] & MAY_CREATE == 0) revert NotCapable();\n",""),

 ("M18","caps","MAY_DISCHARGE not required to discharge",
  "        if (caps[msg.sender] & MAY_DISCHARGE == 0) revert NotCapable();\n",""),

 ("M19","caps","MAY_DISCHARGE revocable while claims are open",
  "        if (caps[p.logic] & MAY_DISCHARGE != 0 && p.capBits & MAY_DISCHARGE == 0) {\n            if (openClaims[p.logic] != 0) revert LogicHoldsClaims();\n        }\n",""),

 ("M20","condemn","dischargeCondemned restricted to governance",
  "    function dischargeCondemned(address a, uint256 caseId, uint8 kind) external {",
  "    function dischargeCondemned(address a, uint256 caseId, uint8 kind) external onlyGovernance {"),

 ("M21","condemn","dischargeCondemned works on a healthy logic",
  "        if (!condemned[cl.logic]) revert NotCondemned();\n",""),

 ("M22","condemn","condemnation strips caps (the force-discharge behaviour)",
  "        condemned[logic] = true;",
  "        condemned[logic] = true;\n        caps[logic] = 0;"),

 ("M23","condemn","pending condemnation may be swapped under the timelock",
  "        if (!p.exists || p.logic != logic) revert NoPendingProposal();",
  "        if (!p.exists) revert NoPendingProposal();"),

 ("M24","track","decay factor floor removed",
  "        if (decayFactor < minTrackDecay || decayFactor >= WAD) revert BadTrackDecay();\n",""),

 ("M25","2.1","Claim.amount widened past one slot",
  "    struct Claim {\n        uint96 amount;\n        address logic;\n    }",
  "    struct Claim {\n        uint128 amount;\n        address logic;\n    }"),
 # --- §5.6.1: the maintenance exit (M2.8) --------------------------------
 ("M26", "§5.6.1/I21", "deposit increments without pulling the tokens",
  "        address(token).safeTransferFrom(msg.sender, address(this), amount);\n        maintenanceReserve += amount;\n        emit MaintenanceDeposited",
  "        maintenanceReserve += amount;\n        emit MaintenanceDeposited"),

 ("M27", "§5.6.1", "deposit pulls without incrementing",
  "        address(token).safeTransferFrom(msg.sender, address(this), amount);\n        maintenanceReserve += amount;\n        emit MaintenanceDeposited",
  "        address(token).safeTransferFrom(msg.sender, address(this), amount);\n        emit MaintenanceDeposited"),

 ("M28", "§5.6.1", "withdrawal cap removed entirely",
  "        if (w.amount > maintenanceReserve) revert ExceedsReserve();\n", ""),

 ("M29", "§5.6.1", "withdrawal cap widened to balanceBuckets() — reaches stake and bond",
  "        if (w.amount > maintenanceReserve) revert ExceedsReserve();",
  "        if (w.amount > balanceBuckets()) revert ExceedsReserve();"),

 ("M30", "§5.6.1", "cap checked at PROPOSE instead of at execute",
  "        if (amount == 0) revert AmountZero();\n        uint256 eta = block.timestamp + timelockDelay;\n        pendingWithdrawal",
  "        if (amount == 0) revert AmountZero();\n        if (amount > maintenanceReserve) revert ExceedsReserve();\n        uint256 eta = block.timestamp + timelockDelay;\n        pendingWithdrawal"),

 ("M31", "§5.6.1", "withdrawal timelock comparison inverted",
  "        if (block.timestamp < w.eta) revert TimelockNotElapsed();",
  "        if (block.timestamp > w.eta) revert TimelockNotElapsed();"),

 ("M32", "§5.6.1", "withdrawal does not decrement the reserve",
  "        maintenanceReserve -= w.amount;\n        delete pendingWithdrawal;",
  "        delete pendingWithdrawal;"),

 ("M33", "§5.6.1", "the exit is permissionless",
  "    function executeMaintenanceWithdrawal() external onlyGovernance {",
  "    function executeMaintenanceWithdrawal() external {"),
]


def run():
    r = subprocess.run([FORGE, "test", "--match-path", "test/v3/*"],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "Compiler run failed" in out or "Error (" in out:
        return None, None  # the mutation never ran — not a kill
    failed = re.findall(r"\[FAIL[^\]]*\]\s+(\w+)\(", out)
    m = re.search(r"(\d+) passed; (\d+) failed", out)
    return (m.groups() if m else None), failed


results = []
for mid, inv, desc, old, new in MUTATIONS:
    if old not in ORIG:
        print(f"{mid}: PATTERN NOT FOUND — mutation not applied", file=sys.stderr)
        results.append((mid, inv, desc, "PATTERN-MISS", []))
        continue
    open(SRC, "w").write(ORIG.replace(old, new, 1))
    counts, failed = run()
    open(SRC, "w").write(ORIG)
    status = "INVALID" if failed is None else ("KILLED" if failed else "SURVIVED")
    failed = failed or []
    results.append((mid, inv, desc, status, sorted(set(failed))))
    print(f"{mid} [{inv}] {status}: {desc}")
    for f in sorted(set(failed))[:4]:
        print(f"      caught by {f}")

open(SRC, "w").write(ORIG)

print("\n" + "=" * 72)
survived = [r for r in results if r[3] != "KILLED"]
print(f"{len(results)-len(survived)}/{len(results)} mutations killed")
if survived:
    print("\nSURVIVING MUTATIONS (findings, not passes):")
    for mid, inv, desc, status, _ in survived:
        print(f"  {mid} [{inv}] {status}: {desc}")
