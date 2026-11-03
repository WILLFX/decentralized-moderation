// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HistoryFixture} from "./helpers/HistoryFixture.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {Moderation} from "../src/Moderation.sol";
import {ModerationAuthority} from "../src/persistent/ModerationAuthority.sol";
import {PersistentModeration} from "../src/persistent/PersistentModeration.sol";
import {PersistentStakeRegistry} from "../src/persistent/PersistentStakeRegistry.sol";
import {PersistentIndexRegistry} from "../src/persistent/PersistentIndexRegistry.sol";

contract PersistentRegistriesTest is HistoryFixture {
    MockBZZ token;
    ModerationAuthority authority;
    PersistentStakeRegistry stakes;
    PersistentIndexRegistry index;
    PersistentModeration first;
    PersistentModeration second;
    address publisher = address(0x5011);
    address[24] voters;
    uint256 constant FEE = 1200;
    uint256 constant NOTICE = 10;
    bytes32 constant SALT = bytes32("persistent test salt");

    function config() internal view returns (Moderation.Config memory) {
        return Moderation.Config(
            address(token),
            address(stakes),
            address(index),
            900,
            1800,
            3600,
            3600,
            8 days,
            2,
            FEE,
            3,
            1,
            keccak256("guidelines")
        );
    }

    function fingerprint(Moderation.Config memory c) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                c.token,
                c.commitWindow,
                c.revealWindow,
                c.challengeWindow,
                c.maxWaitForThird,
                c.freezePerLoss,
                c.seedLag,
                c.feeMin,
                c.minRevealsPerCommittee,
                c.guidelinesVersion,
                c.guidelinesHash
            )
        );
    }

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000_000);
        token = new MockBZZ();
        authority = new ModerationAuthority(address(this), NOTICE, address(token), 1000);
        stakes = new PersistentStakeRegistry(authority);
        index = new PersistentIndexRegistry(authority);
        authority.bindRegistries(address(stakes), address(index));
        first = new PersistentModeration(config(), authority);
        second = new PersistentModeration(config(), authority);
        activate(first);
        for (uint256 i; i < voters.length; ++i) {
            voters[i] = address(uint160(0x1000 + i));
            token.mint(voters[i], 1000);
            vm.startPrank(voters[i]);
            token.approve(address(stakes), 1000);
            stakes.stake();
            vm.stopPrank();
        }
        token.mint(publisher, 100 * FEE);
        vm.startPrank(publisher);
        token.approve(address(first), type(uint256).max);
        token.approve(address(second), type(uint256).max);
        vm.stopPrank();
    }

    function activate(PersistentModeration m) internal {
        authority.propose(address(m), address(m).codehash, fingerprint(config()));
        (,,, uint256 activationTime) = authority.proposal();
        vm.warp(activationTime);
        authority.activate();
    }

    function submit(PersistentModeration m, bytes32 content) internal returns (uint256) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(publisher);
        return m.submit(content, keccak256("metadata"), topics, FEE);
    }

    function commit(PersistentModeration m, uint256 id, uint256 voter) internal {
        bytes32 hash = m.commitHash(id, m.caseInfo(id).challenges, voters[voter], 1, SALT);
        vm.prank(voters[voter]);
        m.commit(id, hash);
    }

    function readyA(PersistentModeration m, uint256 id) internal {
        uint256 target = m.caseInfo(id).seedBlockA;
        if (block.number <= target) vm.roll(target + 1);
        vm.setBlockhash(target, keccak256(abi.encode("A", target)));
    }

    function round(PersistentModeration m, uint256 id, uint256 offset) internal {
        readyA(m, id);
        for (uint256 i; i < 3; ++i) {
            commit(m, id, offset + i);
        }
        vm.warp(m.pairScheduleOf(id).deadlineA);
        m.closeCommitA(id);
        uint256 target = m.caseInfo(id).seedBlockB;
        vm.roll(target + 1);
        bytes32 seed = keccak256(abi.encode("B", target));
        _recordHistory(target, seed);
        vm.setBlockhash(target, seed);
        for (uint256 i = 3; i < 6; ++i) {
            commit(m, id, offset + i);
        }
        vm.warp(m.pairScheduleOf(id).deadlineB);
        m.closeCommitB(id);
        for (uint256 i; i < 6; ++i) {
            vm.prank(voters[offset + i]);
            m.reveal(id, 1, SALT);
        }
        vm.warp(m.caseInfo(id).phaseDeadline);
        m.closeReveal(id);
        target = m.caseInfo(id).outcomeSeedBlock;
        vm.roll(target + 1);
        bytes32 entropy;
        bool found;
        for (uint256 i; i < 256; ++i) {
            entropy = keccak256(abi.encode("approve draw", i));
            (uint8 outcome,) = m.decideAt(id, entropy);
            if (outcome == 1) {
                found = true;
                break;
            }
        }
        assertTrue(found, "approve entropy not found");
        vm.setBlockhash(target, entropy);
        m.draw(id);
    }

    function finalize(PersistentModeration m, uint256 id) internal {
        uint256 deadline = m.caseInfo(id).phaseDeadline;
        if (block.timestamp < deadline) vm.warp(deadline);
        m.closeChallenge(id);
    }

    function test_authorizerDelayCancellationAndExactCandidate() public {
        vm.expectRevert(ModerationAuthority.NotAuthorizer.selector);
        vm.prank(voters[0]);
        authority.propose(address(second), address(second).codehash, fingerprint(config()));
        vm.expectRevert(ModerationAuthority.InvalidVersion.selector);
        authority.propose(address(second), bytes32(uint256(123)), fingerprint(config()));
        authority.propose(address(second), address(second).codehash, fingerprint(config()));
        vm.expectRevert(ModerationAuthority.PendingProposal.selector);
        authority.propose(address(second), address(second).codehash, fingerprint(config()));
        (,,, uint256 firstActivation) = authority.proposal();
        vm.warp(firstActivation - 1);
        vm.expectRevert(ModerationAuthority.NoticeNotElapsed.selector);
        authority.activate();
        vm.expectRevert(ModerationAuthority.NotAuthorizer.selector);
        vm.prank(voters[0]);
        authority.cancel();
        authority.cancel();
        vm.expectRevert(ModerationAuthority.NoProposal.selector);
        authority.activate();
        authority.propose(address(second), address(second).codehash, fingerprint(config()));
        (,,, uint256 nextActivation) = authority.proposal();
        vm.warp(nextActivation);
        vm.prank(voters[0]);
        authority.activate();
        assertEq(authority.active(), address(second));
        assertEq(authority.rulesHashOf(address(second)), second.rulesHash());
        vm.expectRevert(ModerationAuthority.InvalidVersion.selector);
        authority.propose(address(first), address(first).codehash, fingerprint(config()));
    }

    function test_changedRuntimeAndUnreviewedSettingsAreRefused() public {
        authority.propose(address(second), address(second).codehash, fingerprint(config()));
        (,,, uint256 activationTime) = authority.proposal();
        vm.warp(activationTime);
        vm.etch(address(second), hex"60006000fd");
        vm.expectRevert(ModerationAuthority.InvalidVersion.selector);
        authority.activate();
        Moderation.Config memory c = config();
        c.freezePerLoss++;
        PersistentModeration different = new PersistentModeration(c, authority);
        authority.cancel();
        vm.expectRevert(ModerationAuthority.InvalidVersion.selector);
        authority.propose(address(different), address(different).codehash, fingerprint(config()));
    }

    function test_handoverKeepsOldCaseAndSharesCustodyWithoutRestaking() public {
        uint256 oldId = submit(first, keccak256("old listing"));
        activate(second);
        uint256 beforeBalance = token.balanceOf(publisher);
        vm.expectRevert(ModerationAuthority.NotActive.selector);
        submit(first, keccak256("forbidden new listing"));
        assertEq(token.balanceOf(publisher), beforeBalance);
        assertEq(first.nextCaseId(), 2);
        round(first, oldId, 0);
        uint256 newId = submit(second, keccak256("new listing"));
        assertEq(oldId, newId); // Namespaces must keep these distinct.
        round(second, newId, 0);
        assertEq(stakes.openVotes(voters[0]), 2);
        finalize(first, oldId);
        first.claim(oldId, voters[0]);
        assertEq(stakes.openVotes(voters[0]), 1);
        vm.expectRevert();
        vm.prank(voters[0]);
        stakes.withdraw();
        vm.expectRevert(PersistentStakeRegistry.InvalidObligation.selector);
        vm.prank(address(first));
        stakes.settle(oldId, voters[0]);
        finalize(second, newId);
        second.claim(newId, voters[0]);
        assertEq(stakes.openVotes(voters[0]), 0);
        vm.prank(voters[0]);
        stakes.withdraw();
        assertEq(token.balanceOf(voters[0]), 1000 + 2 * (FEE / 6));
        Moderation.Case memory c = first.caseInfo(oldId);
        (address origin, uint256 originId, uint32 version, bytes32 guidelines) =
            index.originOf(index.entryKeyOf(c.claimKey, keccak256("biology")));
        assertEq(origin, address(first));
        assertEq(originId, oldId);
        assertEq(version, 1);
        assertEq(guidelines, first.guidelinesHash());
    }

    function test_oldVersionCanCompleteBothChallengesAndAllSettlements() public {
        uint256 id = submit(first, keccak256("challenged"));
        round(first, id, 0);
        activate(second);
        vm.prank(voters[6]);
        first.challenge(id, 0, 1);
        round(first, id, 7);
        vm.prank(voters[13]);
        first.challenge(id, 1, 1);
        round(first, id, 14);
        assertEq(first.caseInfo(id).phase, uint8(Moderation.Phase.FINALIZED));
        uint256 paid;
        for (uint256 i; i < 20; ++i) {
            uint256 before = token.balanceOf(voters[i]);
            first.claim(id, voters[i]);
            paid += token.balanceOf(voters[i]) - before;
            assertEq(stakes.openVotes(voters[i]), 0);
            assertEq(stakes.isFrozen(voters[i]), i == 6 || i == 13);
        }
        assertEq(paid, 18 * (FEE / 18));
        assertEq(token.balanceOf(address(first)), FEE - paid);
    }

    function test_crossVersionRemovalSlotReleaseAndProvenance() public {
        uint256 listing = submit(first, keccak256("removable"));
        round(first, listing, 0);
        finalize(first, listing);
        vm.prank(publisher);
        uint256 oldRemoval = first.submitRemoval(listing, FEE);
        activate(second);
        vm.expectRevert(ModerationAuthority.RemovalUnavailable.selector);
        vm.prank(publisher);
        second.submitRemoval(address(first), listing, FEE);
        vm.warp(first.pairScheduleOf(oldRemoval).deadlineA);
        first.closeCommitA(oldRemoval);
        assertEq(first.refundOwed(oldRemoval), FEE);
        first.withdrawRefund(oldRemoval);
        vm.prank(publisher);
        uint256 newRemoval = second.submitRemoval(address(first), listing, FEE);
        round(second, newRemoval, 0);
        finalize(second, newRemoval);
        Moderation.Case memory c = first.caseInfo(listing);
        assertFalse(index.isListed(c.claimKey, keccak256("biology")));
        assertTrue(authority.removed(authority.targetKey(address(first), listing)));
        (address origin, uint256 originId,,) = index.originOf(index.entryKeyOf(c.claimKey, keccak256("biology")));
        assertEq(origin, address(first));
        assertEq(originId, listing);
        vm.expectRevert(ModerationAuthority.RemovalUnavailable.selector);
        vm.prank(publisher);
        second.submitRemoval(address(first), listing, FEE);
    }

    function test_unresolvedOldVoteStillFreezesAndRefundsOnce() public {
        uint256 id = submit(first, keccak256("unresolved"));
        readyA(first, id);
        commit(first, id, 0);
        activate(second);
        vm.warp(first.pairScheduleOf(id).deadlineB);
        first.closeCommitB(id);
        vm.warp(first.caseInfo(id).phaseDeadline);
        first.closeReveal(id);
        first.claim(id, voters[0]);
        assertEq(stakes.openVotes(voters[0]), 0);
        assertEq(stakes.frozenUntil(voters[0]), block.timestamp + 8 days);
        uint256 before = token.balanceOf(publisher);
        first.withdrawRefund(id);
        assertEq(token.balanceOf(publisher) - before, FEE);
        vm.expectRevert();
        first.withdrawRefund(id);
        vm.expectRevert();
        first.claim(id, voters[0]);
        vm.expectRevert(PersistentStakeRegistry.CaseScopeRequired.selector);
        vm.prank(address(first));
        stakes.settle(voters[0], false, 0);
        vm.expectRevert(PersistentIndexRegistry.CaseScopeRequired.selector);
        vm.prank(address(first));
        index.removeListing(bytes32(0), bytes32(0));
    }
}
