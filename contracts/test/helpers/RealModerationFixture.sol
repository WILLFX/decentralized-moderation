// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HistoryFixture} from "./HistoryFixture.sol";
import {Moderation} from "../../src/Moderation.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";
import {IndexRegistry} from "../../src/IndexRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// Real registries, reveal floor three and 24 staked identities. No public tests.
/// Block/history hashes are known-answer VM fixtures, not live-chain entropy control.
abstract contract RealModerationFixture is HistoryFixture {
    Moderation mod;
    StakeRegistry stakes;
    IndexRegistry index;
    MockBZZ token;
    address[24] members;
    address constant PUBLISHER = address(0x5011);
    uint256 constant FEE = 1200;
    bytes32 constant SALT = bytes32("schedule salt");

    function setUp() public {
        _deploy(3600);
    }

    function _deploy(uint256 maximumWait) internal {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockBZZ();
        stakes = new StakeRegistry(address(token), 1000);
        index = new IndexRegistry();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            900, 1800, 3600, maximumWait, 8 days, 2, FEE, 3, 1, keccak256("guidelines")));
        stakes.setModeration(address(mod));
        index.setModeration(address(mod));
        for (uint256 i; i < members.length; ++i) {
            members[i] = address(uint160(0x1000 + i));
            token.mint(members[i], 1000);
            vm.startPrank(members[i]);
            token.approve(address(stakes), 1000);
            stakes.stake();
            vm.stopPrank();
        }
        token.mint(PUBLISHER, 100 * FEE);
        vm.prank(PUBLISHER);
        token.approve(address(mod), type(uint256).max);
    }

    function _submit() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(PUBLISHER);
        return mod.submit(keccak256("content"), keccak256("metadata"), topics, FEE);
    }

    function _state(uint256 id, address voter) internal view returns (bytes32) {
        return keccak256(abi.encode(mod.caseInfo(id), mod.pairScheduleOf(id),
            mod.voteOf(id, voter), stakes.openVotes(voter), token.balanceOf(address(mod))));
    }

    function _tickBlock(uint256 height) internal {
        require(height >= block.number, "review: block cannot go backwards");
        vm.warp(block.timestamp + (height - block.number) * 5);
        vm.roll(height);
    }

    function _tickTime(uint256 timestamp) internal {
        if (timestamp > block.timestamp) {
            _tickBlock(block.number + (timestamp - block.timestamp + 4) / 5);
        }
    }

    function _cast(uint256 id, uint256 member, uint8 vote) internal {
        bytes32 h = mod.commitHash(id, mod.caseInfo(id).challenges, members[member], vote, SALT);
        vm.prank(members[member]);
        mod.commit(id, h);
    }

    function _revealedPair(uint256 id, uint256 first, uint8 vote) internal {
        uint256 seedA = mod.caseInfo(id).seedBlockA;
        _tickBlock(seedA + 1);
        vm.setBlockhash(seedA, keccak256(abi.encode("review A", id, first)));
        for (uint256 i = first; i < first + 3; ++i) _cast(id, i, vote);
        _tickTime(mod.pairScheduleOf(id).deadlineA);
        mod.closeCommitA(id);
        uint256 seedB = mod.caseInfo(id).seedBlockB;
        if (block.number <= seedB) _tickBlock(seedB + 1);
        _recordHistory(seedB, keccak256(abi.encode("review B", id, first)));
        for (uint256 i = first + 3; i < first + 6; ++i) _cast(id, i, vote);
        _tickTime(mod.pairScheduleOf(id).deadlineB);
        mod.closeCommitB(id);
        for (uint256 i = first; i < first + 6; ++i) {
            vm.prank(members[i]);
            mod.reveal(id, vote, SALT);
        }
        _tickTime(mod.caseInfo(id).phaseDeadline);
        assertEq(mod.caseInfo(id).revealsA, 3);
        assertEq(mod.caseInfo(id).revealsB, 3);
    }

    function _arm(uint256 id, uint256 first, uint8 vote) internal {
        _revealedPair(id, first, vote);
        mod.closeReveal(id);
    }

    function _outcomeHash(uint256 id, uint8 wanted) internal view returns (bytes32) {
        for (uint256 i; i < 1024; ++i) {
            bytes32 entropy = keccak256(abi.encode("review outcome", id, i));
            (uint8 result,) = mod.decideAt(id, entropy);
            if (result == wanted) return entropy;
        }
        revert("review: no known-answer entropy found");
    }

    function _drawAs(uint256 id, uint8 wanted) internal {
        uint256 target = mod.caseInfo(id).outcomeSeedBlock;
        _tickBlock(target + 1);
        vm.setBlockhash(target, _outcomeHash(id, wanted));
        mod.draw(id);
        assertEq(mod.caseInfo(id).preliminary, wanted);
    }

    function _finalListing() internal returns (uint256 id) {
        id = _submit();
        _arm(id, 0, 1);
        _drawAs(id, 1);
        _tickTime(mod.caseInfo(id).phaseDeadline);
        mod.closeChallenge(id);
        for (uint256 i; i < 6; ++i) mod.claim(id, members[i]);
        assertEq(stakes.openVotes(members[0]), 0);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
    }
}
