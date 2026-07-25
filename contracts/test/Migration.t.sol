// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";

/// The whole point of the M2.5 split, exercised end to end against live state
/// rather than asserted about empty registries: run a real case to settlement
/// under logic A, repoint both registries at logic B, and check that nobody had
/// to re-stake, no approval was lost, and B can adjudicate immediately.
///
/// If this test can be made to fail, the split has bought nothing — a logic
/// upgrade would still cost every moderator a withdraw/re-stake cycle and throw
/// the index away.
contract MigrationTest is ModerationTestBase {
    bytes32 internal constant TK = keccak256("marine biology");
    bytes32 internal constant CONTENT_B = keccak256("content-b");

    function test_live_migration_preserves_stake_and_index() public {
        // --- under logic A: a case runs all the way to an indexed approval ---
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        assertEq(uint256(_phase(caseA)), uint256(Moderation.Phase.SETTLED), "case A settled under logic A");
        assertEq(mod.entryCount(TK), 1, "logic A wrote its approval to the index");
        _assertConservation();

        // Snapshot what the moderators own, including the rewards A just paid.
        uint256[] memory totalBefore = new uint256[](mods.length);
        uint256[] memory weightBefore = new uint256[](mods.length);
        for (uint256 i = 0; i < mods.length; i++) {
            totalBefore[i] = stakeReg.totalStakeOf(mods[i]);
            weightBefore[i] = stakeReg.eligibleWeightOf(mods[i]);
            assertGt(totalBefore[i], 0, "moderator holds stake before the migration");
        }
        uint256 bucketsBefore = stakeReg.stakeBuckets();
        uint256 registryBalBefore = bzz.balanceOf(address(stakeReg));
        IndexRegistry.Entry memory entryBefore = mod.entryAt(TK, 0);

        // --- governance migrates the game to logic B -------------------------
        ModerationHarness modA = mod; // keep a handle: `mod` is repointed to B below
        ModerationHarness modB = new ModerationHarness(IERC20(address(bzz)), stakeReg, indexReg);
        _authorizeLogic(stakeReg, indexReg, address(modB));

        // Not one moderator lifted a finger, and not one token moved.
        for (uint256 i = 0; i < mods.length; i++) {
            assertEq(stakeReg.totalStakeOf(mods[i]), totalBefore[i], "stake survives the migration");
            assertEq(stakeReg.eligibleWeightOf(mods[i]), weightBefore[i], "draw weight survives the migration");
        }
        assertEq(stakeReg.stakeBuckets(), bucketsBefore, "buckets untouched");
        assertEq(bzz.balanceOf(address(stakeReg)), registryBalBefore, "registry custody untouched");

        // The index is intact, entry for entry.
        assertEq(mod.entryCount(TK), 1, "approval survives the migration");
        IndexRegistry.Entry memory entryAfter = indexReg.entryAt(TK, 0);
        assertEq(entryAfter.contentHash, entryBefore.contentHash, "entry content intact");
        assertEq(entryAfter.localCaseId, entryBefore.localCaseId, "entry back-reference intact");
        assertEq(entryAfter.approvalTime, entryBefore.approvalTime, "approval time intact");

        // A has drained, so it is revoked. Reads are never gated by any of this.
        stakeReg.revokeLogic(address(mod));
        indexReg.revokeLogic(address(mod));
        assertEq(indexReg.entryCount(TK), 1, "reads keep working across the handover");

        // --- logic B adjudicates a fresh case on the inherited stake ---------
        // Distinct content: the SAME content is now permanently reserved by A's
        // approval (M2.6-P0-1b) and B is correctly refused it — asserted below.
        mod = modB; // drive the base helpers against the new logic contract
        uint256 caseB = _runUndisputedContent(mods[1], CONTENT_B, META, Moderation.Vote.Approve);
        mod.claim(caseB);
        assertEq(uint256(_phase(caseB)), uint256(Moderation.Phase.SETTLED), "case B settled under logic B");
        assertEq(indexReg.entryCount(TK), 2, "logic B appends to the same index");

        // --- M2.6-P0-1: the cross-version collision the audits found ---------
        // Both logics wrote their OWN local case 0 under the same topic. Before
        // global ids, the second write silently overwrote the first's reverse-map
        // slot: A's entry became a ghost (readable, reported absent by isIndexed,
        // and un-deletable), and a delete aimed at A would hit B's entry instead.
        IndexRegistry.Entry memory eA = indexReg.entryAt(TK, 0);
        IndexRegistry.Entry memory eB = indexReg.entryAt(TK, 1);
        assertEq(eA.localCaseId, eB.localCaseId, "both logics really did use the same LOCAL case id");
        assertTrue(eA.globalId != eB.globalId, "but their permanent identities are distinct");
        assertTrue(indexReg.isIndexed(TK, eA.globalId), "A's entry is addressable");
        assertTrue(indexReg.isIndexed(TK, eB.globalId), "B's entry is addressable");

        // Provenance survives the logic that produced it.
        (address originA,,,) = indexReg.entryProvenance(TK, eA.globalId);
        (address originB,,,) = indexReg.entryProvenance(TK, eB.globalId);
        assertEq(originA, address(modA), "A's entry records the logic that decided it");
        assertEq(originB, address(modB), "B's entry records the logic that decided it");
        assertTrue(originA != originB, "provenance distinguishes the two versions");

        // Each is independently deletable, and deleting one never orphans the other.
        vm.prank(address(modB));
        indexReg.deleteEntry(TK, eA.globalId); // remove the LEGACY entry
        assertEq(indexReg.entryCount(TK), 1, "only one entry removed");
        assertFalse(indexReg.isIndexed(TK, eA.globalId), "legacy entry gone");
        assertTrue(indexReg.isIndexed(TK, eB.globalId), "B's entry survived and is still addressable");

        vm.prank(address(modB));
        indexReg.deleteEntry(TK, eB.globalId);
        assertEq(indexReg.entryCount(TK), 0, "no ghost entries left behind");
        _assertConservation();

        // The moderators earned under B on stake they deposited under A.
        uint256 totalAfter;
        uint256 totalPrior;
        for (uint256 i = 0; i < mods.length; i++) {
            totalAfter += stakeReg.totalStakeOf(mods[i]);
            totalPrior += totalBefore[i];
        }
        assertGt(totalAfter, totalPrior, "B paid rewards into stake that never left the registry");
    }

    /// M2.6-P0-1b, end to end through the public API: content that is live in
    /// the permanent index cannot be re-indexed after a logic upgrade.
    ///
    /// Before the fix, dedup lived in `Moderation.dedupOwnerPlusOne`, so logic B
    /// booted with an empty map and accepted content logic A had already indexed
    /// and never removed. The identical (content, meta, topic) triple then sat in
    /// the topic twice, and the earlier version of this suite asserted that
    /// duplicate as the expected outcome ("logic B appends to the same index").
    function test_identical_content_cannot_be_reindexed_after_migration() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        assertEq(indexReg.entryCount(TK), 1, "A indexed the content");

        bytes32 key = keccak256(abi.encode(CONTENT, META, TK));
        (bool exists, address owner, uint256 ownerCase) = indexReg.contentReservation(key);
        assertTrue(exists, "the reservation is held in the PERMANENT registry");
        assertEq(owner, address(mod), "A holds it");
        assertEq(ownerCase, caseA, "under its own case id");

        // --- migrate: B authorized, A revoked. B has never seen this content --
        ModerationHarness modA = mod;
        ModerationHarness modB = new ModerationHarness(IERC20(address(bzz)), stakeReg, indexReg);
        _authorizeLogic(stakeReg, indexReg, address(modB));
        stakeReg.revokeLogic(address(modA));
        indexReg.revokeLogic(address(modA));

        // Compute the fee BEFORE pranking: an external call in the argument list
        // consumes the prank (see StackDeployer's header).
        uint256 fee = modB.minFee(1);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(modB), type(uint256).max);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.DuplicateSubmission.selector);
        modB.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);

        assertEq(indexReg.entryCount(TK), 1, "no duplicate entry was created");
        (, address ownerAfter,) = indexReg.contentReservation(key);
        assertEq(ownerAfter, address(modA), "the reservation outlives its logic's revocation");

        // Distinct content is unaffected — this is dedup, not a freeze.
        mod = modB;
        uint256 caseB = _runUndisputedContent(mods[1], CONTENT_B, META, Moderation.Vote.Approve);
        mod.claim(caseB);
        assertEq(indexReg.entryCount(TK), 2, "B can still index NEW content");
        _assertConservation();
    }

    /// The revoked logic contract is powerless afterwards: it cannot touch stake
    /// or the index even though it still holds its own case records.
    function test_revoked_logic_cannot_touch_either_registry() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);

        stakeReg.revokeLogic(address(mod));
        indexReg.revokeLogic(address(mod));

        vm.prank(address(mod));
        vm.expectRevert();
        stakeReg.lock(mods[0], MIN_STAKE);

        vm.prank(address(mod));
        vm.expectRevert();
        indexReg.writeEntry(TK, 999, CONTENT, META, true, true, 0, 0);
    }

    /// Trust model #2, with a live case in flight: a moderator that dislikes an
    /// announced migration can leave during the timelock. Exit is never gated by
    /// logic, so neither the outgoing nor the incoming game can trap stake.
    function test_moderator_can_exit_during_an_announced_migration() public {
        ModerationHarness modB = new ModerationHarness(IERC20(address(bzz)), stakeReg, indexReg);
        stakeReg.proposeLogic(address(modB)); // migration announced, not yet live

        address leaver = mods[2];
        uint256 owned = stakeReg.totalStakeOf(leaver);
        vm.prank(leaver);
        stakeReg.setDutyUnits(0); // stop taking new duty
        vm.prank(leaver);
        stakeReg.requestExit(owned);

        vm.warp(vm.getBlockTimestamp() + REG_COOLDOWN);
        uint256 balBefore = bzz.balanceOf(leaver);
        vm.prank(leaver);
        stakeReg.withdraw();

        assertEq(bzz.balanceOf(leaver) - balBefore, owned, "left with everything, before the migration landed");
        assertEq(stakeReg.totalStakeOf(leaver), 0);
    }
}
