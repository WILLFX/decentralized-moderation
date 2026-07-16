// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// §9.10 (single benefit from stake): a faction's first-round win rate tracks its
/// STAKE SHARE, not its square. Two factions with a 70/30 equal-per-member stake
/// split vote opposite ways; the depth-0 outcome (drawn ∝ seats, seats drawn ∝
/// stake) should land APPROVE ≈ 70% of the time. Double-counting stake (weighted
/// selection AND a weighted tally) would push the majority's win rate toward 1.0.
contract StakeBenefitTest is ModerationTestBase {
    mapping(address => bool) internal isFactionA;

    function setUp() public override {
        bzz = new MockBZZ();
        mod = new ModerationHarness(IERC20(address(bzz)));
        _spawnModerators(10, 1000 * XBZZ); // equal stake each
        // 7 A : 3 B  ->  70% : 30% of stake.
        for (uint256 i = 0; i < mods.length; i++) {
            isFactionA[mods[i]] = i < 7;
        }
    }

    function _voteByFaction(uint256 caseId, bool commit) internal {
        (, uint256 shCount,,,,,,,,) = mod.roundInfo(caseId, 0);
        for (uint256 i = 0; i < shCount; i++) {
            address sh = mod.seatHolderAt(caseId, 0, i);
            Moderation.Vote v = isFactionA[sh] ? Moderation.Vote.Approve : Moderation.Vote.Reject;
            vm.prank(sh);
            if (commit) {
                mod.commitVote(caseId, keccak256(abi.encode(uint8(v), SALT)));
            } else {
                mod.revealVote(caseId, v, SALT);
            }
        }
    }

    function _submitVaried(address who, uint256 salt) internal returns (uint256 caseId) {
        uint256 fee = mod.minFee(1);
        bzz.mint(who, fee);
        vm.prank(who);
        bzz.approve(address(mod), type(uint256).max);
        bytes32[] memory t = new bytes32[](1);
        t[0] = keccak256(abi.encode("topic", salt));
        vm.prank(who);
        caseId = mod.submit(Moderation.Kind.SUBMISSION, keccak256(abi.encode(salt)), META, t, 0, fee);
    }

    function test_first_round_outcome_tracks_stake_share() public {
        uint256 n = 40;
        uint256 approvals;
        for (uint256 k = 0; k < n; k++) {
            uint256 caseId = _submitVaried(mods[k % mods.length], k);
            _realizeSeats(caseId);
            _voteByFaction(caseId, true);
            if (_phase(caseId) == Moderation.Phase.COMMIT) {
                vm.warp(block.timestamp + COMMIT_TIMEOUT);
                mod.closeCommit(caseId);
            }
            _voteByFaction(caseId, false);
            if (_phase(caseId) == Moderation.Phase.REVEAL) {
                vm.warp(block.timestamp + REVEAL_WINDOW);
                mod.closeReveal(caseId);
            }
            if (_phase(caseId) == Moderation.Phase.TALLY) {
                _realizeOutcome(caseId);
                (,,,,,,, Moderation.Outcome o,,) = mod.roundInfo(caseId, 0);
                if (o == Moderation.Outcome.Approve) approvals++;
            }
        }
        uint256 ratePct = (approvals * 100) / n;
        emit log_named_uint("approve_rate_pct", ratePct);
        assertGe(ratePct, 50, "majority does not dominate as if double-counted");
        assertLe(ratePct, 88, "win rate tracks stake share, not its square");
    }
}
