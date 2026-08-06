// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";

/// M2.6-P0-3d / H-03B: the UPWARD family, which only exists across `realizeSeats`
/// batches and which no registry-level fixture can reach.
///
/// `DRAW_SEATS_PER_BATCH` is 24, so any panel above that returns to the caller
/// between batches with the seed AND batch 1's seats both public. Anything that
/// RAISES a live seatability input in that window — `setDutyUnits` upward,
/// `activate`, `thaw`, `claim` on another case — changes whether a drawn address is
/// accepted in batch 2. Under the old shape that changed seat consumption, which
/// changed exhaustion, which moved third parties. `voluntaryCutEpoch` did not
/// apply: none of these are reductions, and the comment asserting that raising
/// capacity is not a lever was true within one `drawPanel` call and false across
/// batches.
///
/// The property is the same one as H-03A and is compared the same way: restricted
/// to addresses other than the subject, the two runs agree position by position for
/// as far as the shorter runs. A shorter run may extend; it must never diverge.
contract SeatDrawTest is ModerationTestBase {
    uint256 internal constant PANEL = 40; // > DRAW_SEATS_PER_BATCH, so two batches

    address[] internal pool;

    function setUp() public override {
        super.setUp();
        // A panel wider than one batch, and enough drawable capacity to fill it.
        _widenRuleset(PANEL);
        _spawnPool(30);
    }

    /// Depth-0 panel of `n`, no widen, no appeals — the smallest ruleset that makes
    /// `realizeSeats` return between batches.
    function _widenRuleset(uint256 n) internal {
        Moderation.Params memory p = mod.getParams();
        p.maxWiden = 0;
        p.maxDepth = 0;
        uint256[] memory cts = new uint256[](1);
        cts[0] = n;
        uint256[] memory aws = new uint256[](1);
        aws[0] = 4 days;
        governor.proposeParameters(p, cts, aws);
        vm.warp(vm.getBlockTimestamp() + GOV_TIMELOCK);
        governor.executeParameters();
    }

    /// `pool[0]` is deliberately dominant. It is the subject of every lever test,
    /// and a subject that never gets DRAWN in batch 2 proves nothing — the first
    /// attempt at this fixture gave it 6% of the tree and it went unseated in both
    /// batches, so every lever test passed vacuously. The base fixture's own eight
    /// moderators hold 24,000 XBZZ between them, which is what the share has to be
    /// sized against.
    function _spawnPool(uint256 n) internal {
        uint256 riskPerSeat = mod.getParams().riskPerSeat;
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("pool", i)))));
            pool.push(a);
            uint256 amt = i == 0 ? 20000 * XBZZ : 200 * XBZZ;
            bzz.mint(a, amt);
            vm.prank(a);
            bzz.approve(address(stakeReg), type(uint256).max);
            vm.prank(a);
            stakeReg.stake(amt);
        }
        vm.warp(vm.getBlockTimestamp() + ACTIVATION_DELAY);
        for (uint256 i = 0; i < n; i++) {
            stakeReg.activate(pool[i]);
            (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(pool[i]);
            uint256 units = free / riskPerSeat;
            vm.prank(pool[i]);
            stakeReg.setDutyUnits(units);
        }
        _settleEpoch(stakeReg);
    }

    /// Drive one `realizeSeats` batch and return the seats seated so far.
    function _batch(uint256 caseId) internal {
        _rollToSeed(caseId);
        mod.realizeSeats(caseId);
    }

    /// The seat-holder sequence in insertion order — which is first-appearance order
    /// in the walk — together with each holder's seat count. `r.seats` is a count and
    /// `seatHolders` is an order, so the interleaved sequence is not recoverable from
    /// storage; comparing both projections is equivalent for this property, and it is
    /// what carries the seat-count dimension the prefix rule requires.
    address[] internal lastHolders;
    uint256[] internal lastCounts;

    function _capturePanel(uint256 caseId) internal {
        delete lastHolders;
        delete lastCounts;
        (, uint256 n,,,,,,,,) = mod.roundInfo(caseId, 0);
        for (uint256 i = 0; i < n; i++) {
            address h = mod.seatHolderAt(caseId, 0, i);
            lastHolders.push(h);
            lastCounts.push(mod.__seats(caseId, 0, h));
        }
    }

    /// Everything except `skip`, in order (seat-holder order, with multiplicity
    /// carried by `seatsOf`).
    function _without(address[] memory xs, address skip) internal pure returns (address[] memory out) {
        out = new address[](xs.length);
        uint256 k;
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] != skip) out[k++] = xs[i];
        }
        assembly {
            mstore(out, k)
        }
    }

    function _assertPrefix(address[] memory shorter, address[] memory longer, string memory what) internal pure {
        require(shorter.length <= longer.length, "fixture: expected the second run to be at least as long");
        for (uint256 i = 0; i < shorter.length; i++) {
            assertEq(longer[i], shorter[i], what);
        }
    }

    /// Seat counts are NOT prefix-structured by insertion order — a holder that
    /// first appears at position 3 can pick up a fifth seat at attempt 60 — so the
    /// count property is monotone rather than equal: as the run extends, no third
    /// party may LOSE a seat. Divergence shows up in the order prefix above; this
    /// catches the case where the order is preserved but the multiplicities move.
    function _assertCountsMonotone(uint256[] memory shorter, uint256[] memory longer, string memory what)
        internal
        pure
    {
        for (uint256 i = 0; i < shorter.length; i++) {
            assertLe(shorter[i], longer[i], what);
        }
    }

    /// Compare two runs without caring which went further. "Further" is measured by
    /// TOTAL third-party seats, not by distinct-holder count: a run can seat the
    /// same set of addresses while giving them more seats each, so the array lengths
    /// do not order the two runs. Getting that backwards inverts the monotonicity
    /// and the assertion fires on correct behaviour.
    function _assertRunsAgree(
        address[] memory a,
        uint256[] memory ac,
        address[] memory b,
        uint256[] memory bc,
        string memory what
    ) internal pure {
        if (_sum(ac) <= _sum(bc)) {
            _assertPrefix(a, b, what);
            _assertCountsMonotone(ac, bc, what);
        } else {
            _assertPrefix(b, a, what);
            _assertCountsMonotone(bc, ac, what);
        }
    }

    function _sum(uint256[] memory xs) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < xs.length; i++) {
            n += xs[i];
        }
    }

    /// Run the panel to completion, invoking `lever` once between batch 1 and the
    /// rest, and return the resulting seat-holder sequence.
    /// 0 = none, 1 = setDutyUnits(up), 2 = thaw, 3 = make an insider denied.
    function _runWithLever(uint8 lever) internal returns (address[] memory) {
        uint256 caseId = _submit(mods[0]);
        _batch(caseId); // batch 1: up to DRAW_SEATS_PER_BATCH seats
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW), "returned between batches");
        assertGt(mod.__seatCount(caseId, 0), 0, "batch 1 seated somebody");
        if (lever == 1) _leverRaiseDuty();
        else if (lever == 2) _leverThaw();
        else if (lever == 3) _leverDenyByExit();
        uint256 e0 = stakeReg.currentEpoch();
        uint256 guard;
        while (_phase(caseId) == Moderation.Phase.DRAW) {
            _batch(caseId);
            assertLt(++guard, 32, "the draw terminates");
        }
        // The whole draw must stay inside one epoch, or the runs differ for a
        // legitimate reason (boundary drain + seed re-arm) and prove nothing.
        assertEq(stakeReg.currentEpoch(), e0, "fixture: the draw stayed inside one epoch");
        _capturePanel(caseId);
        return lastHolders;
    }

    // --- the levers ----------------------------------------------------------

    address internal subject;

    /// A holder already in the tree but DENIED, whose seatability the lever raises.
    /// Constructed deliberately: a freshly activated staker has zero epoch weight
    /// and cannot be drawn at all, so `activate` alone is not a lever.
    /// The subject must be DENIED before the draw starts and RESTORED between
    /// batches — that is the shape of the upward lever. Denying it mid-epoch leaves
    /// its leaf carrying full boundary weight, so it is still drawn; under the old
    /// shape being drawn-and-denied removed the leaf and remapped the rest.
    ///
    /// Every value is computed into a local first: an external call in a pranked
    /// argument list consumes the prank (trap 1 in the state-of-play), and all of
    /// these helpers hit it on the first attempt.
    address internal SUBJ;

    /// Deny by un-pledging. Mid-epoch, so the leaf is untouched.
    function _denyByDuty() internal {
        SUBJ = pool[0];
        assertGt(stakeReg.eligibleWeightOf(SUBJ), 0, "in the tree before being denied");
        vm.prank(SUBJ);
        stakeReg.setDutyUnits(0);
        assertEq(stakeReg.eligibleWeightOf(SUBJ), 0, "denied");
    }

    /// Deny by locking away the free stake behind a freeze.
    function _denyByFreeze() internal {
        SUBJ = pool[0];
        uint256 risk = mod.getParams().riskPerSeat;
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(SUBJ);
        uint256 lockAll = free - (risk - 1); // leave under one seat's worth usable
        uint256 until_ = vm.getBlockTimestamp() + 1;
        vm.prank(address(mod));
        stakeReg.lock(SUBJ, 999, lockAll);
        vm.prank(address(mod));
        stakeReg.freeze(SUBJ, 999, lockAll, until_);
        vm.warp(vm.getBlockTimestamp() + 2); // the freeze itself has expired...
        // Weight is nonzero but under one seat, which is what `usable < riskPerSeat`
        // rejects — the leaf is intact and the address is still drawn.
        assertLt(stakeReg.eligibleWeightOf(SUBJ), risk, "...but the stake is still frozen, so denied");
    }

    function _leverRaiseDuty() internal {
        uint256 risk = mod.getParams().riskPerSeat;
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(SUBJ);
        uint256 raised = free / risk;
        vm.prank(SUBJ);
        stakeReg.setDutyUnits(raised);
    }

    /// Permissionless and free: the actor is the test contract, not the subject.
    function _leverThaw() internal {
        stakeReg.thaw(SUBJ);
    }

    /// The DOWNWARD lever on the cross-batch path. `requestExit` is used rather than
    /// `setDutyUnits(0)` because by this point the subject holds seats from batch 1,
    /// and P0-2 correctly refuses to un-pledge capacity a live panel is holding.
    function _leverDenyByExit() internal {
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(SUBJ);
        vm.prank(SUBJ);
        stakeReg.requestExit(free);
    }

    // --- tests ---------------------------------------------------------------

    /// Baseline: two batches, no lever. Establishes the fixture really does return
    /// between batches, so the tests below are not vacuous.
    function test_H03B_fixture_really_batches() public {
        uint256 caseId = _submit(mods[0]);
        _batch(caseId);
        uint256 afterOne = mod.__seatCount(caseId, 0);
        assertGt(afterOne, 0);
        assertLt(afterOne, PANEL, "batch 1 does NOT complete the panel");
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.DRAW));
        assertEq(afterOne, mod.__drawBatchSize(), "one full batch, as sized by the constant");
    }

    /// Raising a live seatability input between batches must not move third parties.
    ///
    /// GUARD, not a discriminator: this one passes on the pre-fix code too, and the
    /// reason is worth recording. To be denied by capacity the subject has to have
    /// cut its own duty, which sets P0-3c's `voluntaryCutEpoch` flag — so P0-3c
    /// already suppressed the exclusion for this exact construction. It is the one
    /// upward lever that the downward fix happened to cover, because the same
    /// address flagged itself on the way down. `thaw` below is the discriminating
    /// one: a freeze sets no flag.
    function test_H03B_raising_duty_between_batches_cannot_reshape_the_draw() public {
        _denyByDuty();
        uint256 snap = vm.snapshotState();
        address[] memory clean = _runWithLever(0);
        uint256[] memory cleanCounts = _countsWithout(clean, SUBJ);
        vm.revertToState(snap);
        address[] memory ground = _runWithLever(1);

        assertTrue(_holds(ground, SUBJ), "the lever actually took effect");
        assertFalse(_holds(clean, SUBJ), "and the subject was denied without it");
        _assertRunsAgree(
            _without(clean, SUBJ), cleanCounts, _without(ground, SUBJ), _countsWithout(ground, SUBJ),
            "setDutyUnits(up) between batches moves nobody"
        );
    }

    /// `thaw` raises `usable` by returning frozen stake, and is permissionless — the
    /// actor need not be the moderator being changed and need have nothing at risk.
    function test_H03B_thaw_between_batches_cannot_reshape_the_draw() public {
        _denyByFreeze();
        uint256 snap = vm.snapshotState();
        address[] memory clean = _runWithLever(0);
        uint256[] memory cleanCounts = _countsWithout(clean, SUBJ);
        vm.revertToState(snap);
        address[] memory ground = _runWithLever(2);

        assertTrue(_holds(ground, SUBJ), "the lever actually took effect");
        assertFalse(_holds(clean, SUBJ), "and the subject was denied without it");
        _assertRunsAgree(
            _without(clean, SUBJ), cleanCounts, _without(ground, SUBJ), _countsWithout(ground, SUBJ),
            "thaw between batches moves nobody"
        );
    }

    function _holds(address[] memory xs, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] == a) return true;
        }
        return false;
    }

    /// The downward lever on the same path, for symmetry: a denial extends the run
    /// rather than diverting it.
    /// The downward direction on the same path, for symmetry: a denial makes the
    /// run EXTEND, never diverge.
    function test_H03B_denial_between_batches_only_extends_the_run() public {
        SUBJ = pool[0];
        uint256 snap = vm.snapshotState();
        address[] memory clean = _runWithLever(0);
        uint256 cleanSubjSeats = _seatsFor(clean, SUBJ);
        uint256[] memory cleanCounts = _countsWithout(clean, SUBJ);
        vm.revertToState(snap);
        address[] memory ground = _runWithLever(3);

        assertGt(cleanSubjSeats, _seatsFor(ground, SUBJ), "the denial actually cost the subject seats");
        _assertRunsAgree(
            _without(clean, SUBJ), cleanCounts, _without(ground, SUBJ), _countsWithout(ground, SUBJ),
            "a denial must not divert the walk"
        );
    }

    function _seatsFor(address[] memory holders, address a) internal view returns (uint256) {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == a) return lastCounts[i];
        }
        return 0;
    }

    function _countsWithout(address[] memory holders, address skip) internal view returns (uint256[] memory out) {
        out = new uint256[](holders.length);
        uint256 k;
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] != skip) out[k++] = lastCounts[i];
        }
        assembly {
            mstore(out, k)
        }
    }

    /// `withdraw()` is NOT a lever, and this pins that rather than assuming it:
    /// `usable = free - pending - exitAmount`, and withdraw reduces `free` by
    /// `exitAmount` while zeroing `exitAmount`, so `usable` is unchanged. Recorded
    /// as a guard because a future edit to the exit path could make it one.
    function test_H03B_withdraw_does_not_change_seatability() public {
        address a = pool[3];
        (uint256 free,,,,,,,,) = stakeReg.moderatorInfo(a);
        vm.prank(a);
        stakeReg.requestExit(free / 2);
        uint256 before = stakeReg.eligibleWeightOf(a);

        vm.warp(vm.getBlockTimestamp() + REG_COOLDOWN);
        vm.prank(a);
        stakeReg.withdraw();

        assertEq(stakeReg.eligibleWeightOf(a), before, "withdraw leaves usable unchanged");
    }
}
