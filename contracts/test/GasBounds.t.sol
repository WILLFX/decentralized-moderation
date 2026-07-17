// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// Gas-bound and failure-mode suite (spec §10, work order M2-9). The load-bearing
/// assertion is that worst-case settlement fits in ONE transaction under the 8M
/// hard ceiling (no stranded pots, invariant 8). Soft budgets for the common
/// paths are measured and recorded in contracts/GAS_BUDGETS.md.
contract GasBoundsTest is ModerationTestBase {
    uint256 internal constant HARD_CEILING = 8_000_000;

    /// Build the maximal case directly in storage and settle it: MAX_DEPTH (4
    /// rounds, 5+11+23+47 = 86 unique voters, all coherent), 5 topics written on
    /// APPROVE, and a winning appeal with contributors at every non-final depth.
    function test_worst_case_claim_under_hard_ceiling() public {
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));

        // pot includes the base fee plus the three winning appeal bonds
        // (2 * 5 xBZZ each) that joined it on appeal.
        uint256 pot = 1000 * XBZZ + 30 * XBZZ;
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, pot);
        b.mint(address(m), pot);

        // 5 topics -> 5 index writes at settlement.
        for (uint256 t = 0; t < 5; t++) {
            m.__injectTopic(caseId, keccak256(abi.encode("topic", t)));
        }

        uint256[4] memory sizes = [uint256(5), 11, 23, 47];
        uint256 v;
        for (uint256 d = 0; d < 4; d++) {
            m.__injectRound(caseId);
            for (uint256 s = 0; s < sizes[d]; s++) {
                address voter = address(uint160(uint256(keccak256(abi.encode("wv", v++)))));
                // Realistically the voter was already in the tree (drawn from it),
                // so settlement UPDATES its weight rather than inserting. Pre-stake
                // + activate so the measurement reflects update cost, not insert.
                b.mint(voter, 100 * XBZZ);
                vm.prank(voter);
                b.approve(address(m), type(uint256).max);
                vm.prank(voter);
                m.stake(20 * XBZZ);

                uint256 camt = 10 * XBZZ;
                m.__setTrack(voter, (v % 50) * 1e18); // varied track (set before inject: reveal-time snapshot)
                m.__injectSeat(caseId, d, voter, 1, camt, 1); // 1 seat, Approve (coherent)
                b.mint(address(m), camt);
            }
            // Non-final rounds carry a winning appeal (appealFor == Approve) with
            // two contributors, so settlement runs refunds + bonuses too.
            if (d < 3) {
                m.__injectBond(caseId, d, Moderation.Outcome.Approve, true);
                m.__injectBondContrib(caseId, d, address(uint160(0xC0DE + d * 2)), 5 * XBZZ);
                m.__injectBondContrib(caseId, d, address(uint160(0xC0DE + d * 2 + 1)), 5 * XBZZ);
                // these bonds' value is already included in `pot` above.
            }
        }

        // Activate all 86 voters so they hold real tree weight (update, not insert).
        vm.warp(block.timestamp + 7 days);
        for (uint256 j = 0; j < 86; j++) {
            m.activate(address(uint160(uint256(keccak256(abi.encode("wv", j))))));
        }

        uint256 g0 = gasleft();
        m.claim(caseId);
        uint256 used = g0 - gasleft();

        emit log_named_uint("worst_case_claim_gas", used);
        assertLt(used, HARD_CEILING, "worst-case claim must fit under the 8M hard ceiling");
        assertEq(uint256(_phaseOf(m, caseId)), uint256(Moderation.Phase.SETTLED));
    }

    function _phaseOf(ModerationHarness m, uint256 caseId) internal view returns (Moderation.Phase p) {
        (,, p,,,,) = m.caseInfo(caseId);
    }

    // --- C-01: settlement must be O(1) in appeal contributors ----------------

    /// Inject a FINALIZED case with one coherent voter and a WINNING appeal bond
    /// split across `nContrib` addresses that all sum to `totalBond`. Everything
    /// except the contributor count is held identical, so two cases built with
    /// different `nContrib` isolate exactly the settlement cost of the
    /// contributor set. Returns the caseId.
    function _injectWinningAppeal(ModerationHarness m, MockBZZ b, uint256 nContrib, uint256 totalBond)
        internal
        returns (uint256 caseId)
    {
        uint256 baseFee = 1000 * XBZZ;
        uint256 pot = baseFee + totalBond; // the winning bond joined the pot
        caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, pot);
        b.mint(address(m), pot);

        m.__injectRound(caseId);
        // one coherent voter so the reward channel is exercised
        address voter = address(uint160(uint256(keccak256(abi.encode("c01v", nContrib)))));
        b.mint(voter, 100 * XBZZ);
        vm.prank(voter);
        b.approve(address(m), type(uint256).max);
        vm.prank(voter);
        m.stake(20 * XBZZ);
        uint256 camt = 10 * XBZZ;
        m.__injectSeat(caseId, 0, voter, 1, camt, 1); // Approve == final
        b.mint(address(m), camt);

        // winning appeal on depth 0 (appealFor == final outcome)
        m.__injectBond(caseId, 0, Moderation.Outcome.Approve, true);
        uint256 each = totalBond / nContrib;
        uint256 acc;
        for (uint256 k = 0; k < nContrib; k++) {
            uint256 amt = (k == nContrib - 1) ? (totalBond - acc) : each; // last takes remainder
            address contrib = address(uint160(uint256(keccak256(abi.encode("c01c", nContrib, k)))));
            m.__injectBondContrib(caseId, 0, contrib, amt);
            acc += amt;
        }
    }

    /// The C-01 finding: a winning appeal funded from thousands of addresses used
    /// to make claim() iterate them all and exceed the block limit, permanently
    /// stranding the pot. Settlement must now cost the same regardless of the
    /// contributor count.
    function test_claim_gas_independent_of_appeal_contributors() public {
        uint256 totalBond = 900 * XBZZ;

        MockBZZ bFew = new MockBZZ();
        ModerationHarness mFew = new ModerationHarness(IERC20(address(bFew)));
        uint256 cFew = _injectWinningAppeal(mFew, bFew, 2, totalBond);
        uint256 g0 = gasleft();
        mFew.claim(cFew);
        uint256 gasFew = g0 - gasleft();

        MockBZZ bMany = new MockBZZ();
        ModerationHarness mMany = new ModerationHarness(IERC20(address(bMany)));
        uint256 cMany = _injectWinningAppeal(mMany, bMany, 2000, totalBond);
        g0 = gasleft();
        mMany.claim(cMany);
        uint256 gasMany = g0 - gasleft();

        emit log_named_uint("claim_gas_2_contributors", gasFew);
        emit log_named_uint("claim_gas_2000_contributors", gasMany);
        assertLt(gasMany, HARD_CEILING, "claim with 2000 bond contributors must fit under the ceiling");
        // claim() no longer reads the contributor set, so the two settlements do
        // essentially identical work; allow a small margin for arithmetic on the
        // (equal) pot totals only.
        assertApproxEqRel(gasMany, gasFew, 0.02e18, "settlement gas must not scale with contributor count");
        assertEq(uint256(_phaseOf(mMany, cMany)), uint256(Moderation.Phase.SETTLED));
    }

    /// The other half of C-01: the whole owed pool (refunds + bonuses) is
    /// retrievable by pulls, and the final claimer absorbs the pro-rata dust so
    /// the pool zeroes out exactly — conservation is retrievability, not just
    /// bookkeeping.
    function test_appeal_pool_fully_pullable_with_dust_to_last_claimer() public {
        uint256 nContrib = 47; // prime count -> guarantees pro-rata dust
        uint256 totalBond = 613 * XBZZ + 4242; // odd total -> dust
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));
        uint256 caseId = _injectWinningAppeal(m, b, nContrib, totalBond);

        m.claim(caseId);

        // The full owed pool (refunds + bonuses) is booked as pending at
        // settlement; the sum of pristine per-contributor floors is short by the
        // pro-rata dust, which the final claimer absorbs.
        uint256 pool = m.totalPendingPayout();
        uint256 owedFloors = 0;
        for (uint256 k = 0; k < nContrib; k++) {
            address contrib = address(uint160(uint256(keccak256(abi.encode("c01c", nContrib, k)))));
            owedFloors += m.appealPayoutOwed(caseId, contrib);
        }
        assertLe(owedFloors, pool, "pristine floors never exceed the pool");
        assertLt(pool - owedFloors, nContrib, "dust is bounded by one wei per contributor");

        uint256 pulledTotal;
        for (uint256 k = 0; k < nContrib; k++) {
            address contrib = address(uint160(uint256(keccak256(abi.encode("c01c", nContrib, k)))));
            uint256 before = b.balanceOf(contrib);
            vm.prank(contrib);
            m.claimAppealPayout(caseId, 0);
            pulledTotal += b.balanceOf(contrib) - before;
        }

        // Everything booked was pulled, to the wei; the pool is drained exactly.
        assertEq(pulledTotal, pool, "sum of pulls equals the full owed pool");
        assertEq(m.totalPendingPayout(), 0, "pending payout fully drained");
        // A second pull by anyone reverts (nothing left).
        address first = address(uint160(uint256(keccak256(abi.encode("c01c", nContrib, uint256(0))))));
        vm.prank(first);
        vm.expectRevert(Moderation.NothingToReclaim.selector);
        m.claimAppealPayout(caseId, 0);
    }

    // --- H-04: the REACHABLE worst case settles in bounded batches -----------

    /// Build the true adversarial maximum: 4 depths, each panel widened to
    /// 4×target (20+44+92+188 = 344 seats), almost all committed-but-failed
    /// (frozen at settlement), a handful coherent, winning appeals with
    /// contributors at every non-final depth, and 5 topics. This is the case the
    /// M2 "86-voter" gas test omitted.
    function _buildMaximalCase(ModerationHarness m, MockBZZ b) internal returns (uint256 caseId, uint256 nSeats) {
        uint256 pot = 100000 * XBZZ;
        caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, pot);
        b.mint(address(m), pot);
        for (uint256 tI = 0; tI < 5; tI++) {
            m.__injectTopic(caseId, keccak256(abi.encode("mtopic", tI)));
        }

        uint256[4] memory sizes = [uint256(20), 44, 92, 188]; // target × (1 + MAX_WIDEN=3)
        uint256 v;
        for (uint256 d = 0; d < 4; d++) {
            m.__injectRound(caseId);
            for (uint256 sI = 0; sI < sizes[d]; sI++) {
                address voter = address(uint160(uint256(keccak256(abi.encode("maxv", v)))));
                uint256 camt = 10 * XBZZ;
                // ~1 in 8 reveals coherently (Approve == final); the rest committed
                // and failed to reveal (frozen) — the adversarial widen pattern.
                uint8 rc = (v % 8 == 0) ? 1 : 0;
                m.__injectSeat(caseId, d, voter, 1, camt, rc);
                b.mint(address(m), camt);
                v++;
            }
            if (d < 3) {
                m.__injectBond(caseId, d, Moderation.Outcome.Approve, true);
                m.__injectBondContrib(caseId, d, address(uint160(0xBEEF + d * 2)), 5 * XBZZ);
                m.__injectBondContrib(caseId, d, address(uint160(0xBEEF + d * 2 + 1)), 5 * XBZZ);
            }
        }
        nSeats = v; // 344
    }

    function test_maximal_case_settles_in_bounded_batches() public {
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));
        (uint256 caseId, uint256 nSeats) = _buildMaximalCase(m, b);
        assertEq(nSeats, 344, "reachable worst case is 344 seats, not 86");

        // Settle in bounded batches; every batch must fit well under the ceiling.
        uint256 batch = 40;
        uint256 rounds;
        uint256 maxBatchGas;
        while (_phaseOf(m, caseId) != Moderation.Phase.SETTLED) {
            uint256 g = gasleft();
            m.claim(caseId, batch);
            uint256 used = g - gasleft();
            if (used > maxBatchGas) maxBatchGas = used;
            require(rounds++ < 100, "did not converge");
        }
        emit log_named_uint("max_batch_gas", maxBatchGas);
        emit log_named_uint("num_batches", rounds);
        assertLt(maxBatchGas, HARD_CEILING, "every settlement batch fits under the 8M ceiling");

        // Conservation holds exactly after full settlement (totalSettling back to 0).
        uint256 buckets = m.totalFreeStake() + m.totalCommittedStake() + m.totalFrozenStake();
        assertEq(
            b.balanceOf(address(m)),
            buckets + m.openPotsTotal() + m.totalPendingBond() + m.totalPendingPayout() + m.totalSettling(),
            "conservation after batched settlement"
        );
        assertEq(m.totalSettling(), 0, "no value left in flight");
    }

    /// The batched path exists because one-shot settlement of the maximal case is
    /// far heavier than the old 86-voter measurement implied. Logged for contrast.
    function test_maximal_case_oneshot_gas_measurement() public {
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));
        (uint256 caseId,) = _buildMaximalCase(m, b);
        uint256 g = gasleft();
        m.claim(caseId); // unbounded
        emit log_named_uint("maximal_oneshot_claim_gas", g - gasleft());
        assertEq(uint256(_phaseOf(m, caseId)), uint256(Moderation.Phase.SETTLED));
    }

    // --- H-03: index deletion must be O(1) in the topic-array size -----------

    /// Build a topic array of `n` entries and delete the FIRST-inserted one (the
    /// worst case for the old linear scan). Returns the gas the deletion used.
    function _buildAndDeleteFront(uint256 n) internal returns (uint256 used) {
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));
        bytes32 topic = keccak256("bigtopic");
        for (uint256 i = 0; i < n; i++) {
            m.__pushEntry(topic, i);
        }
        assertEq(m.entryCount(topic), n);
        uint256 g = gasleft();
        m.__deleteEntry(topic, 0); // front entry -> swap-pop with the last
        used = g - gasleft();
        assertEq(m.entryCount(topic), n - 1, "entry removed");
    }

    /// The H-03 finding: removal linear-scanned the topic array, so as a topic
    /// grew the deletion (inside atomic settlement) could exceed the block limit
    /// and permanently strand a removal case. Deletion must now cost the same
    /// regardless of topic size.
    function test_index_deletion_gas_independent_of_topic_size() public {
        uint256 gasSmall = _buildAndDeleteFront(8);
        uint256 gasBig = _buildAndDeleteFront(2000);
        emit log_named_uint("delete_front_of_8", gasSmall);
        emit log_named_uint("delete_front_of_2000", gasBig);
        assertApproxEqRel(gasBig, gasSmall, 0.05e18, "index deletion must not scale with topic-array size");
    }

    // --- soft-budget measurements (recorded, not gated tightly) --------------

    function test_measure_common_path_gas() public {
        _measureSubmit5Topics();

        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        (, uint256 shc,,,,,,,,) = mod.roundInfo(caseId, 0);
        bytes32 h = keccak256(abi.encode(uint8(Moderation.Vote.Approve), SALT));

        // commitVote (measure the first, then commit the rest).
        address sh0 = mod.seatHolderAt(caseId, 0, 0);
        uint256 g = gasleft();
        vm.prank(sh0);
        mod.commitVote(caseId, h);
        emit log_named_uint("commitVote_gas", g - gasleft());
        for (uint256 i = 1; i < shc; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            vm.prank(sh);
            mod.commitVote(caseId, h);
        }
        if (_phase(caseId) == Moderation.Phase.COMMIT) {
            vm.warp(block.timestamp + COMMIT_TIMEOUT);
            mod.closeCommit(caseId);
        }

        // revealVote (measure the first).
        g = gasleft();
        vm.prank(sh0);
        mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        emit log_named_uint("revealVote_gas", g - gasleft());
        for (uint256 i = 1; i < shc; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            vm.prank(sh);
            mod.revealVote(caseId, Moderation.Vote.Approve, SALT);
        }
        if (_phase(caseId) == Moderation.Phase.REVEAL) {
            vm.warp(block.timestamp + REVEAL_WINDOW);
            mod.closeReveal(caseId);
        }
        _realizeOutcome(caseId);

        // contributeAppealBond (partial, first contribution incl. appealFor set).
        address c = makeAddr("contrib");
        uint256 floor = mod.appealFloor(caseId);
        _fund(c, floor);
        g = gasleft();
        vm.prank(c);
        mod.contributeAppealBond(caseId, floor / 4);
        emit log_named_uint("contributeAppealBond_gas", g - gasleft());
    }

    /// The seat-draw poke over a large tree (D9's 2M budget row): a full 47-seat
    /// depth-panel draw over 1000 activated moderators.
    function test_measure_draw_poke_1000_mods() public {
        MockBZZ b = new MockBZZ();
        ModerationHarness m = new ModerationHarness(IERC20(address(b)));
        for (uint256 i = 0; i < 1000; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("bigmod", i)))));
            b.mint(a, 100 * XBZZ);
            vm.prank(a);
            b.approve(address(m), type(uint256).max);
            vm.prank(a);
            m.stake(20 * XBZZ);
        }
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 1000; i++) {
            m.activate(address(uint160(uint256(keccak256(abi.encode("bigmod", i))))));
        }

        // Inject a FINALIZED-then-reopened depth-3 round? Simpler: measure a
        // real depth-0 realizeSeats (5 seats) and a synthetic 47-seat draw via
        // the harness to isolate the per-panel draw cost over the 1000-leaf tree.
        uint256 caseId = m.__injectFinalized(0, Moderation.Outcome.Approve, 0);
        m.__injectRound(caseId);
        uint256 g = gasleft();
        m.__drawPanel(caseId, 0, 47, keccak256("seed"));
        uint256 used = g - gasleft();
        emit log_named_uint("draw_poke_47seats_1000mods_gas", used);
        assertLt(used, 3_500_000, "47-seat draw over 1000 moderators (adjusted soft budget)");
    }

    function _measureSubmit5Topics() internal {
        bytes32[] memory t = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            t[i] = keccak256(abi.encode("gtopic", i));
        }
        uint256 fee = mod.minFee(5);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        uint256 g = gasleft();
        vm.prank(mods[1]);
        mod.submit(Moderation.Kind.SUBMISSION, keccak256("gc"), META, t, 0, fee);
        emit log_named_uint("submit_5topics_gas", g - gasleft());
    }

    // --- §10 failure modes ---------------------------------------------------

    function test_over_max_topics_reverts() public {
        bytes32[] memory six = new bytes32[](6);
        uint256 fee = 100 * XBZZ;
        vm.prank(mods[0]);
        vm.expectRevert(Moderation.BadTopicCount.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, six, 0, fee);
    }

    function test_widen_cannot_loop_unboundedly() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId);
        // Never participate; drive until terminal — must stop within MAX_WIDEN+2 cycles.
        uint256 guard;
        while (_phase(caseId) != Moderation.Phase.VOID && _phase(caseId) != Moderation.Phase.FINALIZED) {
            require(guard++ < 2 * (MAX_WIDEN + 2), "widen looped unboundedly");
            Moderation.Phase p = _phase(caseId);
            if (p == Moderation.Phase.COMMIT) {
                vm.warp(block.timestamp + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            } else if (p == Moderation.Phase.REVEAL) {
                vm.warp(block.timestamp + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            } else {
                break;
            }
        }
        (,,,,,, uint256 widenCount,,,) = mod.roundInfo(caseId, 0);
        assertLe(widenCount, MAX_WIDEN, "widen bounded by MAX_WIDEN");
    }
}
