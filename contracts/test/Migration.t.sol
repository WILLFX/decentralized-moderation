// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {ModerationTestBase} from "./base/ModerationTestBase.sol";
import {ModerationHarness} from "./harnesses/ModerationHarness.sol";
import {RulesetGovernor} from "../src/RulesetGovernor.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

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

    /// A replacement game contract, with its own governor — `Moderation.governor`
    /// is immutable, so a new logic version brings a new one (M2.6 split).
    function _deployReplacementLogic() internal returns (ModerationHarness m) {
        RulesetGovernor g = new RulesetGovernor(address(this), GOV_TIMELOCK);
        m = new ModerationHarness(IERC20(address(bzz)), stakeReg, indexReg, address(g));
        g.bindModeration(m);
    }

    // --- M2.6-item-4: the deployment must hold the registry's asset -----------

    /// Flagged by both original audits, then lost to a duplicate P1-2 numbering,
    /// so it survived the whole milestone unbuilt.
    ///
    /// The harm is not an accounting mismatch. `submit` pulls fees in the logic
    /// contract's token; settlement approves that token to the registry and calls
    /// `reward()`, which pulls `StakeRegistry.token()` from the logic contract
    /// (P0-4 — the registry funds itself and verifies the balance delta). Under a
    /// mismatch it pulls an asset the logic contract does not hold, the transfer
    /// reverts, and `claim` reverts with it: every adjudicated case bricks in
    /// SETTLING with its seat-holders' committed stake locked forever, while
    /// `submit` goes on accepting fees. VOIDs still drain — they pay the submitter
    /// in the logic's own token and never call `reward()` — so the fault presents
    /// as intermittent rather than total.
    ///
    /// That harm is argued from the call path rather than exercised, deliberately:
    /// a test for it would have to construct the mismatched deployment this check
    /// now makes unconstructible. The refusal is the assertion available, and it
    /// is the one that has to hold.
    function test_deployment_against_a_foreign_token_is_refused() public {
        MockBZZ other = new MockBZZ();
        assertTrue(address(other) != address(bzz), "fixture needs two distinct tokens");
        assertEq(address(stakeReg.token()), address(bzz), "registry holds the suite's token");

        RulesetGovernor g = new RulesetGovernor(address(this), GOV_TIMELOCK);
        vm.expectRevert(Moderation.TokenMismatch.selector);
        new ModerationHarness(IERC20(address(other)), stakeReg, indexReg, address(g));
    }

    /// The matching deployment still constructs, so the check is an identity test
    /// and not an accidental ban on redeploying the game contract — which is the
    /// entire point of the M2.5 split.
    function test_deployment_against_the_registry_token_is_accepted() public {
        RulesetGovernor g = new RulesetGovernor(address(this), GOV_TIMELOCK);
        ModerationHarness m = new ModerationHarness(IERC20(address(bzz)), stakeReg, indexReg, address(g));
        assertEq(address(m.token()), address(stakeReg.token()), "logic and registry hold one asset");
    }

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
        ModerationHarness modB = _deployReplacementLogic();
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
        ModerationHarness modB = _deployReplacementLogic();
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

    /// Stand up logic B, authorize it on both registries, revoke A, and point the
    /// base helpers at B. Returns the outgoing logic.
    function _migrateToNewLogic() internal returns (ModerationHarness modA, ModerationHarness modB) {
        modA = mod;
        modB = _deployReplacementLogic();
        _authorizeLogic(stakeReg, indexReg, address(modB));
        stakeReg.revokeLogic(address(modA));
        indexReg.revokeLogic(address(modA));
        mod = modB;
    }

    /// M2.6-P0-1c: a replacement logic can adjudicate an entry it did not write.
    ///
    /// The registry has permitted cross-version deletion since P0-1a, but the game
    /// exposed no path to it: `submitRemoval` resolves its target through this
    /// contract's own `cases[targetCaseId]`, and the case record for a legacy entry
    /// stayed behind in the contract that was replaced. So every entry inherited
    /// from a previous version was permanently unadjudicable — the index could grow
    /// across an upgrade but never be corrected.
    ///
    /// The M2.5 test that appeared to prove this worked was calling
    /// `indexReg.deleteEntry` under `vm.prank(address(modB))`. That impersonates
    /// the logic contract and proves only that the REGISTRY permits the delete.
    /// This test goes through `Moderation`'s public API, which is the claim.
    function test_legacy_entry_is_removable_through_the_new_logic() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        uint256 gid = mod.caseEntryIds(caseA)[0];
        assertTrue(indexReg.isIndexed(TK, gid), "A's entry is live in the index");

        (ModerationHarness modA,) = _migrateToNewLogic();

        // The local route cannot reach it: B's case array does not contain A's case.
        uint256 fee = mod.minFee(1); // before the prank (trap 1)
        _fund(mods[1], fee);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitRemoval(caseA, fee);

        // The legacy route does — an ordinary adjudicated case, start to finish.
        uint256 rem = _submitLegacyRemoval(mods[1], gid);
        _realizeSeats(rem);
        _runRoundToAppealWindow(rem, 0, Moderation.Vote.Approve);
        _finalize(rem);
        mod.claim(rem);

        assertFalse(indexReg.isIndexed(TK, gid), "the legacy entry was removed by the new logic");
        assertEq(indexReg.entryCount(TK), 0, "and it is gone from the topic");

        // The reservation A took is freed too. A is revoked and could never release
        // it itself, so without deletion-bound release the content would have been
        // permanently unsubmittable — a removal that removes nothing.
        bytes32 key = keccak256(abi.encode(CONTENT, META, TK));
        assertFalse(indexReg.isContentReserved(key), "removal freed the legacy reservation");

        uint256 fresh = _runUndisputed(mods[2], Moderation.Vote.Approve);
        mod.claim(fresh);
        assertEq(indexReg.entryCount(TK), 1, "the content can be submitted again, under B");
        (, address ownerLogic,) = indexReg.contentReservation(key);
        assertEq(ownerLogic, address(mod), "and B now holds the reservation");
        assertTrue(ownerLogic != address(modA), "not the retired logic");
        _assertConservation();
    }

    /// A REJECTED legacy removal leaves the entry and its reservation alone. The
    /// path is a case, not a delete button.
    function test_rejected_legacy_removal_leaves_the_entry_indexed() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        uint256 gid = mod.caseEntryIds(caseA)[0];

        _migrateToNewLogic();

        uint256 rem = _submitLegacyRemoval(mods[1], gid);
        _realizeSeats(rem);
        _runRoundToAppealWindow(rem, 0, Moderation.Vote.Reject);
        _finalize(rem);
        mod.claim(rem);

        assertTrue(indexReg.isIndexed(TK, gid), "a rejected removal removes nothing");
        assertEq(indexReg.entryCount(TK), 1);
        assertTrue(
            indexReg.isContentReserved(keccak256(abi.encode(CONTENT, META, TK))),
            "and frees nothing"
        );
        _assertConservation();
    }

    /// The two removal routes are disjoint. An entry THIS logic wrote has a case
    /// record, so it goes through `submitRemoval`, which binds the whole
    /// submission and maintains `isIndexed` on the target; routing it through the
    /// legacy path would delete an entry while leaving the target's case record
    /// claiming it is still indexed.
    function test_legacy_route_rejects_entries_this_logic_wrote() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        uint256 gid = mod.caseEntryIds(caseA)[0];

        uint256 fee = mod.minFee(1);
        _fund(mods[1], fee);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitLegacyRemoval(gid, fee);
    }

    /// An id that is not live is not adjudicable: never minted, or already removed.
    /// Without this the fee would be taken for a case that can only ever no-op.
    function test_legacy_route_rejects_ids_that_are_not_live() public {
        uint256 caseA = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(caseA);
        uint256 gid = mod.caseEntryIds(caseA)[0];

        _migrateToNewLogic();

        uint256 fee = mod.minFee(1);
        _fund(mods[1], fee * 3);

        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitLegacyRemoval(0, fee); // never minted: ids start at 1

        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitLegacyRemoval(gid + 999, fee); // never minted

        // Remove it, then try again: an already-removed id is not re-adjudicable.
        uint256 rem = _submitLegacyRemoval(mods[1], gid);
        _realizeSeats(rem);
        _runRoundToAppealWindow(rem, 0, Moderation.Vote.Approve);
        _finalize(rem);
        mod.claim(rem);

        vm.prank(mods[1]);
        vm.expectRevert(Moderation.TargetNotRemovable.selector);
        mod.submitLegacyRemoval(gid, fee);
    }

    // --- M2.6-P0-5: the retirement lifecycle ---------------------------------

    /// A retiring logic must reject new submissions and still settle what it has.
    ///
    /// With only on/off authorization there was no such state. Revoking a live
    /// logic STRANDED its cases — its pot, committed stake, duty reservations and
    /// unpaid appeal contributors sat in a contract that could no longer reach the
    /// registries, and the replacement could not settle them because the case
    /// storage lives in the old contract. Leaving it authorized instead let anyone
    /// keep opening new cases in it, so it never provably drained.
    function test_retiring_logic_rejects_submissions_but_still_settles() public {
        uint256 caseId = _submit(mods[0]); // opened while fully authorized
        _realizeSeats(caseId);

        stakeReg.retireLogic(address(mod));
        indexReg.retireLogic(address(mod));

        // No new cases.
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.NotAcceptingSubmissions.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT_B, META, _topics(), 0, fee);

        // But the in-flight one runs to completion, which is the whole point.
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _finalize(caseId);
        mod.claim(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLED), "in-flight case still settles");
        _assertConservation();
    }

    /// A revoked logic must refuse fees rather than trap them.
    ///
    /// `submit` never checked its own authorization, so a revoked contract kept
    /// taking money for cases it could never seat, settle or refund — every
    /// retired contract became a permanent fee trap with no path back out.
    function test_revoked_logic_refuses_fees_instead_of_trapping_them() public {
        stakeReg.retireLogic(address(mod));
        indexReg.retireLogic(address(mod));
        stakeReg.revokeLogic(address(mod)); // nothing outstanding, so this is allowed
        indexReg.revokeLogic(address(mod));

        uint256 fee = mod.minFee(1);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        uint256 balBefore = bzz.balanceOf(mods[1]);

        vm.prank(mods[1]);
        vm.expectRevert(Moderation.NotAcceptingSubmissions.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);

        assertEq(bzz.balanceOf(mods[1]), balBefore, "not a wei was taken");
        assertEq(bzz.balanceOf(address(mod)), 0, "and nothing is trapped in the dead logic");
    }

    /// Revocation is gated on a real drain signal, not on governance believing the
    /// old logic has finished.
    function test_cannot_revoke_a_logic_that_still_holds_obligations() public {
        uint256 caseId = _submit(mods[0]);
        _realizeSeats(caseId); // seats drawn: duty reserved and escrowed

        assertFalse(stakeReg.canRevoke(address(mod)), "obligations outstanding");
        vm.expectRevert(StakeRegistry.LogicStillHasObligations.selector);
        stakeReg.revokeLogic(address(mod));

        // Drive it to settlement; only then does the signal flip.
        _runRoundToAppealWindow(caseId, 0, Moderation.Vote.Approve);
        _finalize(caseId);
        mod.claim(caseId);

        assertTrue(stakeReg.canRevoke(address(mod)), "drained");
        stakeReg.revokeLogic(address(mod));
    }

    /// M2.6-P0-5b. The drain gate has to hold on BOTH registries, because a case's
    /// final step touches both: `_settleFinish` writes the index entries and
    /// releases the stake in the same call.
    ///
    /// Gating only the stake side left governance able to revoke index-side while a
    /// case sat in SETTLING. The stake registry then refused revocation forever —
    /// correctly, and uselessly: the case could no longer reach `writeEntry`, so
    /// every `claim()` reverted `NotLogic`, so its stake obligations never closed,
    /// so `StakeRegistry.canRevoke` never flipped. The stake-side gate did not
    /// prevent the strand; it only made it permanent.
    ///
    /// Driven against a real mid-settlement case and a real `revokeLogic` call, not
    /// asserted about the gate in isolation.
    function test_index_revocation_refuses_a_case_that_is_mid_settlement() public {
        uint256 caseId = _runUndisputed(mods[0], Moderation.Vote.Approve);

        // Enter SETTLING and stop one seat-holder in: the case is past the point of
        // no return and has not yet written its entries.
        mod.claim(caseId, 1);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.SETTLING), "case is mid-settlement");
        assertEq(indexReg.entryCount(TK), 0, "its index write has NOT happened yet");

        // The stake side already refused. That was never the problem.
        assertFalse(stakeReg.canRevoke(address(mod)), "stake obligations outstanding");
        vm.expectRevert(StakeRegistry.LogicStillHasObligations.selector);
        stakeReg.revokeLogic(address(mod));

        // The index side must refuse for its own reason: this case still has to
        // write through it. Before P0-5b this call SUCCEEDED, and the case was
        // stranded from that moment on.
        assertFalse(indexReg.canRevoke(address(mod)), "index obligations outstanding");
        assertTrue(indexReg.caseIsOpen(address(mod), caseId), "the case is what is outstanding");
        vm.expectRevert(IndexRegistry.LogicStillHasObligations.selector);
        indexReg.revokeLogic(address(mod));

        // Finish it. Only now do both signals flip, and they flip together.
        while (_phase(caseId) == Moderation.Phase.SETTLING) mod.claim(caseId);
        assertEq(indexReg.entryCount(TK), 1, "the entry _settleFinish owed the index");
        assertFalse(indexReg.caseIsOpen(address(mod), caseId), "obligation discharged");
        assertTrue(stakeReg.canRevoke(address(mod)), "stake drained");
        assertTrue(indexReg.canRevoke(address(mod)), "index drained");

        stakeReg.revokeLogic(address(mod));
        indexReg.revokeLogic(address(mod));
        _assertConservation();
    }

    /// A REMOVAL takes no content reservation but still DELETES at settlement, so
    /// counting reservations would have left removals ungated. The obligation is
    /// per case for exactly this reason.
    function test_index_revocation_refuses_an_open_removal_which_holds_no_reservation() public {
        uint256 target = _runUndisputed(mods[0], Moderation.Vote.Approve);
        mod.claim(target);
        assertEq(indexReg.entryCount(TK), 1);

        uint256 fee = mod.minFee(1);
        _fund(mods[1], fee);
        vm.prank(mods[1]);
        uint256 removal = mod.submitRemoval(target, fee);

        // No reservation was taken for the removal — the reserved key belongs to
        // the target's entry.
        assertTrue(indexReg.caseIsOpen(address(mod), removal), "but the obligation is recorded");
        vm.expectRevert(IndexRegistry.LogicStillHasObligations.selector);
        indexReg.revokeLogic(address(mod));

        _realizeSeats(removal);
        _runRoundToAppealWindow(removal, 0, Moderation.Vote.Approve);
        _finalize(removal);
        mod.claim(removal);
        assertEq(indexReg.entryCount(TK), 0, "the removal deleted the entry it owed");
        assertTrue(indexReg.canRevoke(address(mod)), "drained");
        indexReg.revokeLogic(address(mod));
    }

    /// A VOIDed case discharges its index obligation too — `_voidFinish` releases
    /// the reservation, and after that the case can never touch the index again.
    function test_void_discharges_the_index_obligation() public {
        uint256 caseId = _submit(mods[0]);
        assertTrue(indexReg.caseIsOpen(address(mod), caseId));

        // No drawable capacity anywhere -> the draw is abandoned -> VOID.
        for (uint256 i = 0; i < mods.length; i++) {
            vm.prank(mods[i]);
            stakeReg.setDutyUnits(0);
        }
        _settleEpoch(stakeReg);
        vm.warp(vm.getBlockTimestamp() + COMMIT_TIMEOUT);
        mod.resolveStalledDraw(caseId);
        while (_phase(caseId) == Moderation.Phase.VOID_SETTLING) mod.claim(caseId);
        assertEq(uint256(_phase(caseId)), uint256(Moderation.Phase.VOID));

        assertFalse(indexReg.caseIsOpen(address(mod), caseId), "VOID discharges it");
        assertTrue(indexReg.canRevoke(address(mod)), "drained");
    }

    /// Desynchronized authorization is unreachable from the path that creates
    /// exposure: the registries are governed independently, so a logic can be live
    /// in one and not the other. A case opened in that state would settle its
    /// stake and then fail its index write.
    function test_desynchronized_registry_authorization_rejects_submissions() public {
        indexReg.retireLogic(address(mod)); // index says settle-only, stake still open
        uint256 fee = mod.minFee(1);
        bzz.mint(mods[1], fee);
        vm.prank(mods[1]);
        bzz.approve(address(mod), type(uint256).max);
        vm.prank(mods[1]);
        vm.expectRevert(Moderation.NotAcceptingSubmissions.selector);
        mod.submit(Moderation.Kind.SUBMISSION, CONTENT, META, _topics(), 0, fee);
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
        stakeReg.lock(mods[0], 0, MIN_STAKE);

        vm.prank(address(mod));
        vm.expectRevert();
        indexReg.writeEntry(TK, 999, CONTENT, META, true, true, 0, 0, bytes32(0));
    }

    /// Trust model #2, with a live case in flight: a moderator that dislikes an
    /// announced migration can leave during the timelock. Exit is never gated by
    /// logic, so neither the outgoing nor the incoming game can trap stake.
    function test_moderator_can_exit_during_an_announced_migration() public {
        ModerationHarness modB = _deployReplacementLogic();
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
