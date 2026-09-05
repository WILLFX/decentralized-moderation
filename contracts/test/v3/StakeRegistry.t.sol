// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice A logic contract, so I32's second clause has a real second caller.
/// @dev The registry authorizes ADDRESSES. Testing "logic B cannot touch logic A's
///      claim" with two EOAs would test the same code path but would not exercise
///      the shape the invariant is about — two independently authorized contracts
///      coexisting through a migration, which is the case §2.4 says the property
///      exists for.
contract MockLogic {
    StakeRegistry public immutable reg;

    constructor(StakeRegistry _reg) {
        reg = _reg;
    }

    function createVote(address m, uint256 caseId, uint256 lambda) external {
        reg.createVoteClaim(m, caseId, lambda);
    }

    function createChallenge(address m, uint256 caseId, uint256 cb) external {
        reg.createChallengeClaim(m, caseId, cb);
    }

    function debit(address m, uint256 caseId, uint8 kind, uint256 amount) external {
        reg.debit(m, caseId, kind, amount);
    }

    function discharge(address m, uint256 caseId, uint8 kind) external {
        reg.discharge(m, caseId, kind);
    }

    function reward(address m, uint256 amount) external {
        IERC20 t = reg.token();
        t.approve(address(reg), amount);
        reg.reward(m, amount);
    }

    function record(address m, uint256 caseId, uint256 units, uint256 decay) external {
        reg.recordParticipation(m, caseId, units, decay);
    }
}

/// @title StakeRegistry (v3) — invariant discrimination suite
/// @notice Every invariant this contract owns has a test here that FAILS if the
///         invariant is removed from the source, not merely one that passes while
///         the invariant happens to hold. Each is labelled with the mutation it was
///         verified against; the campaign is recorded in the commit message.
contract StakeRegistryV3Test is Test {
    StakeRegistry internal reg;
    MockBZZ internal token;

    MockLogic internal logicA;
    MockLogic internal logicB;

    address internal gov;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal stranger;

    // §1 working values. `BOND_MIN` has none (open, §10) — see the port report.
    uint256 internal constant UNIT = 1e16; // xBZZ is 16 decimals
    uint256 internal constant MIN_STAKE = 10 * UNIT;
    uint256 internal constant BOND_MIN = 5 * UNIT;
    uint256 internal constant MATURATION = 3 days;
    uint256 internal constant EXIT_COOLDOWN = 7 days;
    uint256 internal constant TIMELOCK = 2 days;
    uint256 internal constant MIN_TRACK_DECAY = 0.5e18;

    uint256 internal constant LAMBDA = 2 * UNIT;
    uint256 internal constant CHALLENGE_BOND = 3 * UNIT;

    uint8 internal VOTE;
    uint8 internal CHALLENGE;

    function setUp() public {
        gov = makeAddr("gov");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        stranger = makeAddr("stranger");

        token = new MockBZZ();
        vm.prank(gov);
        reg = new StakeRegistry(
            IERC20(address(token)), MIN_STAKE, BOND_MIN, MATURATION, EXIT_COOLDOWN, TIMELOCK, MIN_TRACK_DECAY
        );
        VOTE = reg.KIND_VOTE();
        CHALLENGE = reg.KIND_CHALLENGE();

        logicA = new MockLogic(reg);
        logicB = new MockLogic(reg);
        _authorize(address(logicA), reg.MAY_CREATE() | reg.MAY_DISCHARGE());
        _authorize(address(logicB), reg.MAY_CREATE() | reg.MAY_DISCHARGE());

        token.mint(address(logicA), 1_000 * UNIT);
        token.mint(address(logicB), 1_000 * UNIT);
    }

    // --- fixture helpers ------------------------------------------------------

    function _authorize(address logic, uint8 bits) internal {
        vm.prank(gov);
        reg.proposeCaps(logic, bits);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        reg.executeCaps();
    }

    /// @dev Stakes `who` with `extraBond` on top of `BOND_MIN` and matures them.
    function _mature(address who, uint256 extraBond) internal {
        uint256 bond = BOND_MIN + extraBond;
        token.mint(who, MIN_STAKE + bond);
        vm.startPrank(who);
        token.approve(address(reg), type(uint256).max);
        reg.stake(bond);
        vm.stopPrank();
        vm.warp(block.timestamp + MATURATION);
    }

    function _bondsOf(address[] memory who) internal view returns (uint256 total) {
        for (uint256 i; i < who.length; ++i) total += reg.bondOf(who[i]);
    }

    // =========================================================================
    // I16 — the §2.2 state predicates are mutually exclusive
    // =========================================================================

    /// @dev The predicates are evaluated HERE, from §2.2's table, rather than
    ///      through `stateOf`. `stateOf` is an if-else chain and so is exclusive by
    ///      construction — asserting on it could never catch a non-exclusive
    ///      predicate set, which is exactly the class of non-discriminating test
    ///      this suite exists to avoid.
    function _rawPredicates(address a) internal view returns (bool[4] memory p) {
        (uint256 stk,,,,, uint256 maturesAt, uint256 exitAt,) = reg.moderatorInfo(a);
        p[0] = stk == 0; // NONE
        p[1] = stk > 0 && exitAt == 0 && block.timestamp < maturesAt; // PENDING
        p[2] = stk > 0 && exitAt == 0 && block.timestamp >= maturesAt; // ACTIVE
        p[3] = stk > 0 && exitAt != 0; // EXITING
    }

    function _assertExactlyOneState(address a, string memory whenLabel) internal view {
        bool[4] memory p = _rawPredicates(a);
        uint256 n;
        for (uint256 i; i < 4; ++i) if (p[i]) n++;
        assertEq(n, 1, whenLabel);
    }

    /// MUTATION: delete `m.exitRequestedAt = 0;` from `withdraw`.
    /// MUTATION: drop the `exitAt == 0` conjunct from PENDING.
    function test_I16_exactlyOneStateHoldsThroughEveryTransition() public {
        _assertExactlyOneState(alice, "NONE");

        // NONE -> PENDING
        token.mint(alice, MIN_STAKE + BOND_MIN);
        vm.startPrank(alice);
        token.approve(address(reg), type(uint256).max);
        reg.stake(BOND_MIN);
        vm.stopPrank();
        _assertExactlyOneState(alice, "PENDING");
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.PENDING);

        // PENDING -> EXITING. §2.3 requires this path to exist, and it is what
        // makes §2.2's literal PENDING predicate overlap EXITING.
        vm.prank(alice);
        reg.requestExit();
        _assertExactlyOneState(alice, "EXITING from PENDING");
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.EXITING);

        // EXITING -> NONE
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        reg.withdraw();
        _assertExactlyOneState(alice, "NONE after withdraw");
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.NONE);

        // And a re-staking identity does not land back in EXITING (§2.3).
        vm.startPrank(alice);
        reg.stake(BOND_MIN);
        vm.stopPrank();
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.PENDING);
        _assertExactlyOneState(alice, "PENDING after re-stake");

        // ACTIVE
        vm.warp(block.timestamp + MATURATION);
        _assertExactlyOneState(alice, "ACTIVE");
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.ACTIVE);
    }

    /// @notice §2.2's table AS WRITTEN is not mutually exclusive, and this pins it.
    /// @dev PENDING is `stake > 0 && now < maturesAt` with no `exitRequestedAt`
    ///      conjunct, while ACTIVE has one. A PENDING moderator who requests exit
    ///      then satisfies both PENDING and EXITING. The implementation adds the
    ///      conjunct; this test fails if someone "corrects" it back to the table.
    function test_I16_specTablePendingPredicateWouldOverlapExiting() public {
        token.mint(alice, MIN_STAKE + BOND_MIN);
        vm.startPrank(alice);
        token.approve(address(reg), type(uint256).max);
        reg.stake(BOND_MIN);
        reg.requestExit();
        vm.stopPrank();

        (uint256 stk,,,,, uint256 maturesAt, uint256 exitAt,) = reg.moderatorInfo(alice);
        bool pendingAsSpecWritesIt = stk > 0 && block.timestamp < maturesAt;
        bool exitingAsSpecWritesIt = exitAt != 0;
        assertTrue(pendingAsSpecWritesIt && exitingAsSpecWritesIt, "the overlap is reachable");

        // The implementation resolves it, and must keep resolving it.
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.EXITING);
        _assertExactlyOneState(alice, "implementation is exclusive where the table is not");
    }

    // =========================================================================
    // I1, first clause — every removable value is a term in liabilities()
    // =========================================================================

    /// MUTATION: in `_create`, route KIND_CHALLENGE through `mayCommit`-without-
    ///           liabilities, or drop the challenge branch's solvency check.
    /// @dev This is the historical break, restated: the commit test was written
    ///      against `openVoteCount` alone and `CHALLENGE_BOND` is not attached to a
    ///      vote, so it appeared in neither test. A moderator at `BOND_MIN + 3λ`
    ///      with three open votes could still register a challenge and land at
    ///      `BOND_MIN - CHALLENGE_BOND`.
    function test_I1_challengeBondIsATermInLiabilities() public {
        _mature(alice, 3 * LAMBDA); // bond == BOND_MIN + 3λ exactly

        for (uint256 i; i < 3; ++i) logicA.createVote(alice, i, LAMBDA);
        assertEq(reg.liabilitiesOf(alice), 3 * LAMBDA);

        // Every unit above BOND_MIN is now covered. A challenge is a claim on the
        // same bond, so it must be refused.
        assertFalse(reg.mayChallenge(alice, CHALLENGE_BOND));
        vm.expectRevert(StakeRegistry.Insolvent.selector);
        logicA.createChallenge(alice, 99, CHALLENGE_BOND);

        // Post enough to cover it, and it is admitted — the limit moves with the
        // bond, it is not a fixed allowance (§2.4: a price, not a reservation).
        token.mint(alice, CHALLENGE_BOND);
        vm.prank(alice);
        reg.postBond(CHALLENGE_BOND);
        logicA.createChallenge(alice, 99, CHALLENGE_BOND);
        assertEq(reg.liabilitiesOf(alice), 3 * LAMBDA + CHALLENGE_BOND);
    }

    /// MUTATION: in `_create`, take the solvency test BEFORE adding the claim.
    function test_I1_solvencyHoldsAfterEveryAddition() public {
        _mature(alice, 2 * LAMBDA);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA);
        assertGe(reg.bondOf(alice), BOND_MIN + reg.liabilitiesOf(alice));

        vm.expectRevert(StakeRegistry.Insolvent.selector);
        logicA.createVote(alice, 3, LAMBDA);
        assertGe(reg.bondOf(alice), BOND_MIN + reg.liabilitiesOf(alice));
    }

    // =========================================================================
    // I1, second clause — no debit exceeds the claim it is drawn against
    // =========================================================================

    /// MUTATION: delete `if (amount > cl.amount) revert ExceedsClaim();`
    /// @dev This is the clause that survives a second logic contract: it is
    ///      enforced at the call site rather than argued from `liabilities()` being
    ///      complete. Alice's bond here is far larger than the claim, so the
    ///      arithmetic argument would permit the debit; only the claim bound stops
    ///      it.
    function test_I1_debitCannotExceedTheClaim() public {
        _mature(alice, 100 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        assertGt(reg.bondOf(alice), LAMBDA + 1, "bond alone would permit the overdraw");

        vm.expectRevert(StakeRegistry.ExceedsClaim.selector);
        logicA.debit(alice, 1, VOTE, LAMBDA + 1);

        // Exactly the claim is permitted.
        uint256 before = reg.bondOf(alice);
        logicA.debit(alice, 1, VOTE, LAMBDA);
        assertEq(reg.bondOf(alice), before - LAMBDA);
    }

    /// MUTATION: replace the `BondUnderflow` revert with a clamp
    ///           (`amount = amount > m.bond ? m.bond : amount`).
    /// @dev §5.4: a debit that would underflow means I1 has already failed.
    ///      Reaching this state needs a corrupt claim, so the test builds one the
    ///      only way an attacker could — it is here to pin the revert-not-clamp
    ///      rule, which a clamp would silently satisfy.
    function test_I1_debitRevertsRatherThanClamping() public {
        _mature(alice, 100 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        // Drain the bond below the claim by direct storage write, standing in for
        // the broken-invariant state §5.4 describes.
        uint256 bondSlot = uint256(keccak256(abi.encode(alice, uint256(2)))); // `forge inspect ... storage`
        bytes32 packed = vm.load(address(reg), bytes32(bondSlot));
        // slot 0 of Moderator: [stake:128][bond:128]
        bytes32 zeroedBond = bytes32(uint256(packed) & ((1 << 128) - 1));
        vm.store(address(reg), bytes32(bondSlot), zeroedBond);
        assertEq(reg.bondOf(alice), 0, "fixture: bond zeroed");

        vm.expectRevert(StakeRegistry.BondUnderflow.selector);
        logicA.debit(alice, 1, VOTE, LAMBDA);
    }

    // =========================================================================
    // I13 — withdraw implies liabilities(m) == 0
    // =========================================================================

    /// MUTATION: delete `if (m.liabilities != 0) revert OutstandingLiabilities();`
    /// MUTATION: gate on `openVoteCount == 0` instead of `liabilities == 0`.
    /// @dev The second mutation is P0-5's neighbour and is why the assertion below
    ///      uses a CHALLENGE, which no vote counter sees. A test written against
    ///      `openVoteCount` would pass under it.
    function test_I13_withdrawBlockedByAnOpenChallenge() public {
        _mature(alice, 10 * UNIT);
        logicA.createChallenge(alice, 1, CHALLENGE_BOND);
        assertEq(reg.liabilitiesOf(alice), CHALLENGE_BOND);

        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);

        vm.prank(alice);
        vm.expectRevert(StakeRegistry.OutstandingLiabilities.selector);
        reg.withdraw();

        // Settled, and the exit opens.
        logicA.discharge(alice, 1, CHALLENGE);
        assertEq(reg.liabilitiesOf(alice), 0);
        vm.prank(alice);
        reg.withdraw();
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.NONE);
    }

    /// @dev The cooldown alone is not the gate (P0-5): a voter must not be able to
    ///      commit, request exit, and withdraw before the case that would debit
    ///      them settles.
    function test_I13_cooldownAloneDoesNotAdmitWithdrawal() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.OutstandingLiabilities.selector);
        reg.withdraw();
    }

    // =========================================================================
    // I32 — first clause: only the case that created a claim may discharge it
    // =========================================================================

    /// MUTATION: in `_release`, set `m.liabilities = 0` instead of subtracting.
    /// MUTATION: have `discharge` take an `amount` argument and trust it.
    function test_I32_dischargingOneCaseLeavesTheOtherIntact() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createChallenge(alice, 2, CHALLENGE_BOND);
        assertEq(reg.liabilitiesOf(alice), LAMBDA + CHALLENGE_BOND);

        logicA.discharge(alice, 1, VOTE);

        assertEq(reg.liabilitiesOf(alice), CHALLENGE_BOND, "only case 1's amount left");
        (uint256 amt, address owner) = reg.claimOf(alice, 2, CHALLENGE);
        assertEq(amt, CHALLENGE_BOND);
        assertEq(owner, address(logicA));
        (, address gone) = reg.claimOf(alice, 1, VOTE);
        assertEq(gone, address(0));
    }

    /// @dev The amount is looked up, never supplied — so it cannot be wrong. There
    ///      is no signature through which a caller could state a figure.
    function test_I32_releaseAmountIsNotCallerSupplied() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.discharge(alice, 1, VOTE);
        assertEq(reg.liabilitiesOf(alice), 0);
        assertEq(reg.openClaims(address(logicA)), 0);
    }

    // =========================================================================
    // I32 — second clause: only the LOGIC that created the case may act on it
    // =========================================================================

    /// MUTATION: delete `if (cl.logic != msg.sender) revert NotClaimOwner();`
    ///           from `discharge`.
    /// @dev The migration shape §2.4 names: governance authorizes B while A still
    ///      has open cases — which any workable migration must permit, or every
    ///      in-flight case strands at the cutover. B must not be able to zero
    ///      alice's liabilities out from under A.
    function test_I32_foreignLogicCannotDischargeAnothersClaim() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        // B is fully authorized — this is not an authorization test.
        assertEq(reg.caps(address(logicB)), reg.MAY_CREATE() | reg.MAY_DISCHARGE());

        vm.expectRevert(StakeRegistry.NotClaimOwner.selector);
        logicB.discharge(alice, 1, VOTE);

        assertEq(reg.liabilitiesOf(alice), LAMBDA, "A's claim untouched");
    }

    /// MUTATION: delete `if (cl.logic != msg.sender) revert NotClaimOwner();`
    ///           from `debit`.
    /// @dev I1's second clause and I32's second clause are the same check seen from
    ///      two sides: a caller with no claim on a moderator can debit them nothing
    ///      at all, whatever their bond says.
    function test_I32_foreignLogicCannotDebitAnothersClaim() public {
        _mature(alice, 100 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        uint256 before = reg.bondOf(alice);

        vm.expectRevert(StakeRegistry.NotClaimOwner.selector);
        logicB.debit(alice, 1, VOTE, LAMBDA);

        assertEq(reg.bondOf(alice), before);
    }

    /// @dev The full §2.4 break, end to end: without the ownership check, B empties
    ///      alice's liabilities, she withdraws with three votes open under A, and
    ///      A's settlement later debits a moderator who has left (I13 false).
    function test_I32_migrationCannotStrandTheOutgoingLogic() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA);
        logicA.createVote(alice, 3, LAMBDA);

        vm.expectRevert(StakeRegistry.NotClaimOwner.selector);
        logicB.discharge(alice, 1, VOTE);

        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        vm.expectRevert(StakeRegistry.OutstandingLiabilities.selector);
        reg.withdraw();

        // A settles its own cases and only then does she leave.
        logicA.discharge(alice, 1, VOTE);
        logicA.discharge(alice, 2, VOTE);
        logicA.discharge(alice, 3, VOTE);
        vm.prank(alice);
        reg.withdraw();
    }

    // =========================================================================
    // I23 — liabilities == the sum of that moderator's open claim records
    // =========================================================================

    /// MUTATION: in `_release`, skip the `m.liabilities -= amount`.
    /// MUTATION: in `_create`, add `amount + 1` to liabilities.
    function test_I23_liabilitiesEqualsTheSumOfClaimRecords() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA * 2);
        logicA.createChallenge(alice, 3, CHALLENGE_BOND);

        uint256[] memory ids = new uint256[](3);
        uint8[] memory kinds = new uint8[](3);
        ids[0] = 1;
        kinds[0] = VOTE;
        ids[1] = 2;
        kinds[1] = VOTE;
        ids[2] = 3;
        kinds[2] = CHALLENGE;

        (bool ok, uint256 sum) = reg.liabilitiesMatch(alice, ids, kinds);
        assertTrue(ok, "identity holds after creation");
        assertEq(sum, LAMBDA + LAMBDA * 2 + CHALLENGE_BOND);
        assertEq(sum, reg.liabilitiesOf(alice));

        // ...and after a partial settlement.
        logicA.discharge(alice, 2, VOTE);
        uint256[] memory ids2 = new uint256[](2);
        uint8[] memory kinds2 = new uint8[](2);
        ids2[0] = 1;
        kinds2[0] = VOTE;
        ids2[1] = 3;
        kinds2[1] = CHALLENGE;
        (bool ok2, uint256 sum2) = reg.liabilitiesMatch(alice, ids2, kinds2);
        assertTrue(ok2, "identity holds after discharge");
        assertEq(sum2, LAMBDA + CHALLENGE_BOND);
    }

    /// MUTATION: delete the duplicate check from `liabilitiesMatch`.
    /// @dev The assertion has to be sound or it is worse than nothing. With two
    ///      claims of EQUAL amount, passing one twice and omitting the other has
    ///      the right length and the right sum — a false `true`.
    function test_I23_assertionRejectsADuplicateEnumeration() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA); // equal amounts: the false-positive shape

        uint256[] memory ids = new uint256[](2);
        uint8[] memory kinds = new uint8[](2);
        ids[0] = 1;
        kinds[0] = VOTE;
        ids[1] = 1; // duplicate, case 2 omitted
        kinds[1] = VOTE;

        vm.expectRevert(StakeRegistry.BadEnumeration.selector);
        reg.liabilitiesMatch(alice, ids, kinds);
    }

    /// MUTATION: delete the `n != openClaimsOf(a)` completeness check.
    function test_I23_assertionRejectsAnIncompleteEnumeration() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA);

        uint256[] memory ids = new uint256[](1);
        uint8[] memory kinds = new uint8[](1);
        ids[0] = 1;
        kinds[0] = VOTE;

        vm.expectRevert(StakeRegistry.BadEnumeration.selector);
        reg.liabilitiesMatch(alice, ids, kinds);
    }

    // =========================================================================
    // I14 / I21 — no moderator's loss is another's gain; every value has a
    //             named destination, and it is never another moderator
    // =========================================================================

    /// MUTATION: in `debit`, credit a second moderator's bond instead of
    ///           `maintenanceReserve` (a "redistribute the penalty" change).
    /// MUTATION: in `debit`, drop `maintenanceReserve += amount` entirely.
    /// @dev The first mutation is caught by the third-party assertions, the second
    ///      by the bucket identity: the debited value must be somewhere, and the
    ///      only place it may be is the named reserve.
    function test_I14_aDebitReachesTheReserveAndNoOtherModerator() public {
        _mature(alice, 100 * UNIT);
        _mature(bob, 100 * UNIT);
        _mature(carol, 100 * UNIT);

        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(bob, 1, LAMBDA);

        address[] memory all = new address[](3);
        all[0] = alice;
        all[1] = bob;
        all[2] = carol;

        uint256 bondsBefore = _bondsOf(all);
        uint256 reserveBefore = reg.maintenanceReserve();
        uint256 bobBefore = reg.bondOf(bob);
        uint256 carolBefore = reg.bondOf(carol);
        uint256 bobTrackBefore = reg.trackOf(bob);

        logicA.debit(alice, 1, VOTE, LAMBDA);

        assertEq(reg.maintenanceReserve(), reserveBefore + LAMBDA, "the named destination");
        assertEq(_bondsOf(all), bondsBefore - LAMBDA, "no bond absorbed it");
        assertEq(reg.bondOf(bob), bobBefore, "bob unchanged");
        assertEq(reg.bondOf(carol), carolBefore, "carol unchanged");
        assertEq(reg.trackOf(bob), bobTrackBefore, "no standing moved either");
        assertEq(reg.liabilitiesOf(bob), LAMBDA, "bob's claim unchanged");
    }

    /// MUTATION: in `reward`, credit the payee from another moderator's bond
    ///           rather than from the caller's transfer.
    /// @dev A payment is funded by the caller in the same call. Nothing in this
    ///      contract moves value from one moderator to another.
    function test_I14_aRewardIsFundedByTheCallerNotByAnotherModerator() public {
        _mature(alice, 10 * UNIT);
        _mature(bob, 10 * UNIT);

        uint256 bobBefore = reg.bondOf(bob);
        uint256 aliceBefore = reg.bondOf(alice);
        uint256 logicBefore = token.balanceOf(address(logicA));

        logicA.reward(alice, 7 * UNIT);

        assertEq(reg.bondOf(alice), aliceBefore + 7 * UNIT);
        assertEq(reg.bondOf(bob), bobBefore, "bob did not fund it");
        assertEq(token.balanceOf(address(logicA)), logicBefore - 7 * UNIT, "the caller did");
    }

    /// MUTATION: any of the above.
    /// @dev I21 as a ledger identity across a full lifecycle: every unit the
    ///      contract holds is in exactly one named bucket, and none is stranded.
    function test_I21_everyHeldUnitIsInANamedBucket() public {
        _mature(alice, 100 * UNIT);
        _mature(bob, 100 * UNIT);

        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(bob, 1, LAMBDA);
        logicA.debit(alice, 1, VOTE, LAMBDA);
        logicA.reward(bob, 3 * UNIT);
        logicA.discharge(alice, 1, VOTE);
        logicA.discharge(bob, 1, VOTE);

        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets(), "no stranded value");
        assertTrue(reg.solvent());

        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        reg.withdraw();

        assertEq(token.balanceOf(address(reg)), reg.balanceBuckets(), "still exact after exit");
        assertEq(reg.maintenanceReserve(), LAMBDA, "the debit is still where it was sent");
    }

    // =========================================================================
    // Capabilities (§2.4)
    // =========================================================================

    /// MUTATION: delete the `MAY_CREATE` check in `_create`.
    function test_caps_creationRequiresMayCreate() public {
        _mature(alice, 10 * UNIT);
        _authorize(address(logicA), reg.MAY_DISCHARGE()); // create revoked
        vm.expectRevert(StakeRegistry.NotCapable.selector);
        logicA.createVote(alice, 1, LAMBDA);
    }

    /// MUTATION: delete the `MAY_DISCHARGE` check in `discharge`.
    function test_caps_dischargeRequiresMayDischarge() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        // Revoking MAY_DISCHARGE while a claim is open is refused (below), so drop
        // to a logic that never had it.
        MockLogic logicC = new MockLogic(reg);
        _authorize(address(logicC), reg.MAY_CREATE());
        vm.expectRevert(StakeRegistry.NotCapable.selector);
        logicC.discharge(alice, 1, VOTE);
    }

    /// MUTATION: delete the `openClaims != 0` guard in `executeCaps`.
    /// @dev Retiring a contract must not strand every moderator who voted under it.
    function test_caps_mayDischargeIsNotRevocableWhileAClaimIsOpen() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        assertEq(reg.openClaims(address(logicA)), 1);

        vm.prank(gov);
        reg.proposeCaps(address(logicA), 0);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        vm.expectRevert(StakeRegistry.LogicHoldsClaims.selector);
        reg.executeCaps();

        // Settle, and the revocation goes through.
        logicA.discharge(alice, 1, VOTE);
        vm.prank(gov);
        reg.executeCaps();
        assertEq(reg.caps(address(logicA)), 0);
    }

    /// @dev The other half of the same rule: MAY_CREATE alone IS revocable while
    ///      claims are open, or a logic could never be retired at all.
    function test_caps_mayCreateIsRevocableWhileClaimsAreOpen() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        _authorize(address(logicA), reg.MAY_DISCHARGE());
        assertEq(reg.caps(address(logicA)), reg.MAY_DISCHARGE());

        vm.expectRevert(StakeRegistry.NotCapable.selector);
        logicA.createVote(alice, 2, LAMBDA);
        logicA.discharge(alice, 1, VOTE); // still settles what it holds
    }

    function test_caps_timelockIsEnforced() public {
        vm.prank(gov);
        reg.proposeCaps(address(0xDEAD), 3);
        vm.prank(gov);
        vm.expectRevert(StakeRegistry.TimelockNotElapsed.selector);
        reg.executeCaps();
    }

    function test_caps_onlyGovernanceMayPropose() public {
        vm.prank(stranger);
        vm.expectRevert(StakeRegistry.NotGovernance.selector);
        reg.proposeCaps(address(0xDEAD), 3);
    }

    // =========================================================================
    // Condemnation (§2.4)
    // =========================================================================

    function _condemn(address logic) internal {
        vm.prank(gov);
        reg.proposeCondemn(logic);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        reg.executeCondemn(logic);
    }

    /// MUTATION: gate `dischargeCondemned` on `msg.sender == governance`.
    /// @dev "Any of its claims may be discharged by anyone, forever." The affected
    ///      moderator calls it themselves — recovery does not depend on governance
    ///      holding a complete list, which is the whole reason this replaced the
    ///      force-discharge.
    function test_condemn_anyoneMayDischargeACondemnedLogicsClaim() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        _condemn(address(logicA));

        vm.prank(stranger);
        reg.dischargeCondemned(alice, 1, VOTE);
        assertEq(reg.liabilitiesOf(alice), 0);
        assertEq(reg.openClaims(address(logicA)), 0);

        // And the exit it was blocking now opens.
        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        reg.withdraw();
    }

    /// MUTATION: delete the `condemned[cl.logic]` check.
    function test_condemn_strangerCannotDischargeAHealthyLogicsClaim() public {
        _mature(alice, 10 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        vm.prank(stranger);
        vm.expectRevert(StakeRegistry.NotCondemned.selector);
        reg.dischargeCondemned(alice, 1, VOTE);
        assertEq(reg.liabilitiesOf(alice), LAMBDA);
    }

    /// @dev Idempotent, and partial application is not a state: there is no list,
    ///      so there is nothing to leave half-done. Claims may be released in any
    ///      order, by different callers, across different transactions.
    function test_condemn_isIdempotentAndOrderFree() public {
        _mature(alice, 50 * UNIT);
        _mature(bob, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA);
        logicA.createVote(bob, 1, LAMBDA);
        _condemn(address(logicA));

        vm.prank(bob);
        reg.dischargeCondemned(bob, 1, VOTE);
        vm.prank(stranger);
        reg.dischargeCondemned(alice, 2, VOTE);
        vm.prank(alice);
        reg.dischargeCondemned(alice, 1, VOTE);

        assertEq(reg.liabilitiesOf(alice), 0);
        assertEq(reg.liabilitiesOf(bob), 0);
        assertEq(reg.openClaims(address(logicA)), 0);

        // Twice is a no-op, not a double release.
        vm.prank(stranger);
        vm.expectRevert(StakeRegistry.NoSuchClaim.selector);
        reg.dischargeCondemned(alice, 1, VOTE);
    }

    /// MUTATION: add `caps[logic] = 0;` to `executeCondemn` (the force-discharge's
    ///           behaviour, which was the sole caller that broke the no-revoke
    ///           rule).
    /// @dev Condemnation ADDS a discharge path and removes none.
    function test_condemn_theCondemnedLogicKeepsMayDischarge() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createVote(alice, 2, LAMBDA);
        _condemn(address(logicA));

        assertEq(reg.caps(address(logicA)), reg.MAY_CREATE() | reg.MAY_DISCHARGE(), "caps untouched");
        logicA.discharge(alice, 1, VOTE); // still settles legitimately
        assertEq(reg.liabilitiesOf(alice), LAMBDA);
    }

    /// MUTATION: delete the `p.logic != logic` check in `executeCondemn`.
    function test_condemn_proposalCannotBeSwappedUnderTheTimelock() public {
        vm.prank(gov);
        reg.proposeCondemn(address(logicA));
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(gov);
        vm.expectRevert(StakeRegistry.NoPendingProposal.selector);
        reg.executeCondemn(address(logicB));
        assertFalse(reg.condemned(address(logicB)));
    }

    function test_condemn_timelockIsEnforced() public {
        vm.prank(gov);
        reg.proposeCondemn(address(logicA));
        vm.prank(gov);
        vm.expectRevert(StakeRegistry.TimelockNotElapsed.selector);
        reg.executeCondemn(address(logicA));
    }

    /// @dev The pardon, pinned as the decision it is rather than discovered later:
    ///      a condemned logic's claims are released WITHOUT the debit they covered.
    function test_condemn_pardonsThePendingDebit() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        uint256 bondBefore = reg.bondOf(alice);

        _condemn(address(logicA));
        vm.prank(alice);
        reg.dischargeCondemned(alice, 1, VOTE);

        assertEq(reg.bondOf(alice), bondBefore, "not one unit debited");
        assertEq(reg.maintenanceReserve(), 0, "and nothing reached the reserve");
    }

    // =========================================================================
    // §2.3 transitions
    // =========================================================================

    /// @dev §2.3: PENDING must have an exit path, or stake is locked for
    ///      MATURATION with no way out.
    function test_transitions_pendingHasAnExitPath() public {
        token.mint(alice, MIN_STAKE + BOND_MIN);
        vm.startPrank(alice);
        token.approve(address(reg), type(uint256).max);
        reg.stake(BOND_MIN);
        assertTrue(reg.stateOf(alice) == StakeRegistry.State.PENDING);
        reg.requestExit();
        vm.stopPrank();

        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        reg.withdraw();
        assertEq(token.balanceOf(alice), MIN_STAKE + BOND_MIN, "stake + bond, less nothing");
    }

    function test_transitions_claimsMayOnlyBeOpenedOnAnActiveModerator() public {
        token.mint(alice, MIN_STAKE + 10 * UNIT);
        vm.startPrank(alice);
        token.approve(address(reg), type(uint256).max);
        reg.stake(10 * UNIT);
        vm.stopPrank();

        vm.expectRevert(StakeRegistry.Insolvent.selector); // PENDING fails mayCommit
        logicA.createVote(alice, 1, LAMBDA);

        vm.warp(block.timestamp + MATURATION);
        logicA.createVote(alice, 1, LAMBDA);

        // EXITING moderators keep their open cases but may not take new ones.
        vm.prank(alice);
        reg.requestExit();
        vm.expectRevert(StakeRegistry.Insolvent.selector);
        logicA.createVote(alice, 2, LAMBDA);
        logicA.discharge(alice, 1, VOTE); // the open one still settles
    }

    function test_transitions_postBondRestoresSolvency() public {
        _mature(alice, LAMBDA);
        logicA.createVote(alice, 1, LAMBDA);
        assertFalse(reg.mayCommit(alice, LAMBDA));

        token.mint(alice, LAMBDA);
        vm.prank(alice);
        reg.postBond(LAMBDA);
        assertTrue(reg.mayCommit(alice, LAMBDA));
        logicA.createVote(alice, 2, LAMBDA);
    }

    function test_transitions_doubleClaimIsRefused() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        vm.expectRevert(StakeRegistry.ClaimExists.selector);
        logicA.createVote(alice, 1, LAMBDA);
    }

    /// @dev The same case may carry one VOTE and one CHALLENGE claim: the kinds are
    ///      distinct keys, and a challenger is not a voter.
    function test_transitions_voteAndChallengeCoexistOnOneCase() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);
        logicA.createChallenge(alice, 1, CHALLENGE_BOND);
        assertEq(reg.liabilitiesOf(alice), LAMBDA + CHALLENGE_BOND);
        assertEq(reg.openClaimsOf(alice), 2);
    }

    // =========================================================================
    // §6 track
    // =========================================================================

    /// MUTATION: delete the `decayFactor < minTrackDecay` check.
    /// @dev K-5: a replacement logic must not be able to zero a moderator's
    ///      standing by supplying a decay of 0.
    function test_track_decayFactorIsFloored() public {
        _mature(alice, 10 * UNIT);
        vm.expectRevert(StakeRegistry.BadTrackDecay.selector);
        logicA.record(alice, 1, 1, 0);
        vm.expectRevert(StakeRegistry.BadTrackDecay.selector);
        logicA.record(alice, 1, 1, MIN_TRACK_DECAY - 1);
        vm.expectRevert(StakeRegistry.BadTrackDecay.selector);
        logicA.record(alice, 1, 1, 1e18); // must be a strict decay
    }

    /// @dev §6: track is retained through withdrawal. That is what makes identity
    ///      replacement expensive rather than the stake.
    function test_track_isRetainedThroughWithdrawal() public {
        _mature(alice, 10 * UNIT);
        logicA.record(alice, 1, 1, 0.95e18);
        uint256 t = reg.trackOf(alice);
        assertGt(t, 0);

        vm.prank(alice);
        reg.requestExit();
        vm.warp(block.timestamp + EXIT_COOLDOWN + 1);
        vm.prank(alice);
        reg.withdraw();

        assertEq(reg.trackOf(alice), t, "track survives the exit");
    }

    /// @notice §6 requires the update to be order-independent. IT IS NOT, and this
    ///         pins the gap rather than asserting a property the code does not have.
    /// @dev Two cases with different pinned decay factors `a` and `b`, each
    ///      contributing one coherent unit. A-then-B gives `t·a·b + b + 1`;
    ///      B-then-A gives `t·a·b + a + 1`. §5.5 makes settlement permissionless
    ///      and unordered, so the difference is reachable by anyone. See the port
    ///      report — the fix is a decision in §6, not a reading.
    function test_track_updateIsOrderDependentAcrossPerCaseDecayFactors() public {
        _mature(alice, 50 * UNIT);
        _mature(bob, 50 * UNIT);

        uint256 a = 0.9e18;
        uint256 b = 0.6e18;

        // Seed both with identical prior standing.
        logicA.record(alice, 0, 5, 0.95e18);
        logicA.record(bob, 0, 5, 0.95e18);
        assertEq(reg.trackOf(alice), reg.trackOf(bob), "identical starting point");

        logicA.record(alice, 1, 1, a);
        logicA.record(alice, 2, 1, b);

        logicA.record(bob, 2, 1, b);
        logicA.record(bob, 1, 1, a);

        // A-then-B ends on `+b`; B-then-A ends on `+a`. The shared `t*a*b` term
        // differs only by integer truncation, so the gap is exactly `a - b`.
        assertTrue(reg.trackOf(bob) > reg.trackOf(alice), "order changes the result");
        assertApproxEqAbs(reg.trackOf(bob) - reg.trackOf(alice), a - b, 2, "gap is exactly a - b");
    }

    // =========================================================================
    // Governance
    // =========================================================================

    function test_governance_isTwoStep() public {
        vm.prank(gov);
        reg.proposeGovernance(bob);
        assertEq(reg.governance(), gov, "not transferred on proposal");

        vm.prank(stranger);
        vm.expectRevert(StakeRegistry.NotGovernance.selector);
        reg.acceptGovernance();

        vm.prank(bob);
        reg.acceptGovernance();
        assertEq(reg.governance(), bob);
    }

    // =========================================================================
    // §2.1 — the Claim record is one slot, and uint96 is wide enough
    // =========================================================================

    /// @dev uint96 holds 7.92e28 base units. At xBZZ's 16 decimals that is 7.9e12
    ///      tokens against a total supply of 6.3e7 — five orders of magnitude of
    ///      headroom over the entire supply, and a claim is one moderator's
    ///      coverage for one vote. It survives a move to 18 decimals too (7.9e10
    ///      tokens, still 1,250x the supply).
    function test_claimRecord_uint96CoversTheEntireTokenSupply() public {
        uint256 totalSupplyBZZ = 63_149_437;
        uint256 supplyBaseUnits16 = totalSupplyBZZ * 1e16;
        uint256 supplyBaseUnits18 = totalSupplyBZZ * 1e18;
        assertGt(uint256(type(uint96).max), supplyBaseUnits16 * 100_000);
        assertGt(uint256(type(uint96).max), supplyBaseUnits18 * 1_000);
    }

    /// MUTATION: widen `Claim.amount` to uint128.
    /// @dev The record must stay one slot — §2.4's cost argument is stated as one
    ///      cold write per commit, and two would double it.
    function test_claimRecord_isOneStorageSlot() public {
        _mature(alice, 50 * UNIT);
        logicA.createVote(alice, 1, LAMBDA);

        bytes32 k = keccak256(abi.encode(alice, uint256(1), VOTE));
        bytes32 slot = keccak256(abi.encode(k, uint256(3))); // `forge inspect ... storage`
        bytes32 packed = vm.load(address(reg), slot);

        assertEq(uint256(packed) & type(uint96).max, LAMBDA, "amount in the low 96");
        assertEq(address(uint160(uint256(packed) >> 96)), address(logicA), "logic in the high 160");
    }

    /// @dev An amount that does not fit the record is refused rather than truncated.
    function test_claimRecord_oversizedAmountIsRefusedNotTruncated() public {
        _mature(alice, 50 * UNIT);
        vm.expectRevert(StakeRegistry.AmountZero.selector);
        logicA.createVote(alice, 1, uint256(type(uint96).max) + 1);
    }
}
