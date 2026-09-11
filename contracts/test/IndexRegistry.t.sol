// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";

/// @notice A logic contract, so the writer capability has a real subject and the
///         migration property has a real second caller.
contract MockLogic {
    IndexRegistry public immutable idx;

    constructor(IndexRegistry _idx) {
        idx = _idx;
    }

    function write(bytes32 k, bytes32 t, uint8 s, uint8 p, bool strict) external returns (bytes32) {
        return idx.writeEntry(k, t, s, p, strict, idx.ACTION_LIST());
    }

    function writeAs(bytes32 k, bytes32 t, uint8 s, uint8 p, bool strict, uint8 act)
        external
        returns (bytes32)
    {
        return idx.writeEntry(k, t, s, p, strict, act);
    }

    function remove(bytes32 k, bytes32 t) external returns (bytes32) {
        return idx.removeListing(k, t);
    }

    function open(bytes32 k, bytes32 t) external {
        idx.openQuestion(k, t);
    }

    function close(bytes32 k, bytes32 t) external {
        idx.closeQuestion(k, t);
    }
}

/// @title IndexRegistry (v3) — §8 suite
/// @notice Tests marked MUTATION were verified by removing the named property from
///         the source and confirming this test goes red.
contract IndexRegistryTest is Test {
    IndexRegistry internal idx;
    MockLogic internal logicA;
    MockLogic internal logicB;

    address internal gov;
    address internal stranger;

    uint256 internal constant TIMELOCK = 2 days;

    bytes32 internal constant TOPIC_A = keccak256("topic-a");
    bytes32 internal constant TOPIC_B = keccak256("topic-b");
    bytes32 internal constant CONTENT = keccak256("content");
    bytes32 internal constant META = keccak256("meta");

    uint8 internal constant NONE = uint8(IndexRegistry.Status.NONE);
    uint8 internal constant PLUR_A = uint8(IndexRegistry.Status.PLURALITY_APPROVE);
    uint8 internal constant PLUR_R = uint8(IndexRegistry.Status.PLURALITY_REJECT);
    uint8 internal constant APPROVED = uint8(IndexRegistry.Status.APPROVED);
    uint8 internal constant REJECTED = uint8(IndexRegistry.Status.REJECTED);
    uint8 internal constant UNRESOLVED = uint8(IndexRegistry.Status.UNRESOLVED);
    uint8 internal constant REMOVED = uint8(IndexRegistry.Status.REMOVED);

    function setUp() public {
        gov = makeAddr("gov");
        stranger = makeAddr("stranger");

        vm.prank(gov);
        idx = new IndexRegistry(TIMELOCK);
        logicA = new MockLogic(idx);
        logicB = new MockLogic(idx);
        _grant(address(logicA), true);
        _grant(address(logicB), true);
    }

    function _grant(address logic, bool allowed) internal {
        vm.prank(gov);
        idx.proposeWriter(logic, allowed);
        (,, uint256 eta,) = idx.pendingWriterProposal();
        vm.warp(eta);
        vm.prank(gov);
        idx.executeWriter();
    }

    /// @dev §8.4's key shape. `actionType` is what separates a LIST claim from a
    ///      REMOVE claim about the same content.
    function _claimKey(string memory actionType) internal pure returns (bytes32) {
        bytes32[] memory t = new bytes32[](1);
        t[0] = TOPIC_A;
        return keccak256(abi.encode(actionType, CONTENT, META, t));
    }

    // =========================================================================
    // §8.2 — NONE = 0
    // =========================================================================

    /// MUTATION: begin the enum at `PLURALITY_APPROVE`.
    /// @dev This is the defect §8.2 exists to prevent, and it is one assertion: an
    ///      unwritten slot and a live `PLURALITY_APPROVE` must not read alike. A
    ///      safe-search client would otherwise be right to treat every
    ///      never-submitted item as carrying a live interim status.
    function test_s8_2_anUnwrittenEntryDoesNotReadAsAStatus() public {
        bytes32 k = _claimKey("LIST");
        assertEq(idx.statusOf(k, TOPIC_A), NONE, "never written");
        assertEq(uint8(IndexRegistry.Status.NONE), 0, "and NONE is the zero slot");

        logicA.write(k, TOPIC_A, PLUR_A, 1, false);
        assertEq(idx.statusOf(k, TOPIC_A), PLUR_A);
        assertTrue(idx.statusOf(k, TOPIC_A) != NONE, "the two are distinguishable");
    }

    /// @dev §8.2's enum gained `REMOVED` and deliberately did not gain `RETAINED`:
    ///      a failed removal disturbs no LIST answer, so there is nothing to write.
    function test_s8_2_removedIsAStatusAndRetainedIsNot() public pure {
        assertEq(uint8(IndexRegistry.Status.REMOVED), 6, "seven slots, REMOVED last");
    }

    /// MUTATION: accept `Status.NONE` as a write.
    /// @dev Writing NONE would erase the distinction the zero slot exists to make.
    function test_s8_2_noneCannotBeWritten() public {
        vm.expectRevert(IndexRegistry.BadStatus.selector);
        logicA.write(_claimKey("LIST"), TOPIC_A, NONE, 0, false);
    }

    // =========================================================================
    // §8.2b — the two zero-value traps
    // =========================================================================

    /// MUTATION: delete the `topicKey == 0` check.
    /// @dev I29. A claim carries up to `MAX_TOPICS` topics in a fixed-width slot and
    ///      unused slots read 0, so a legal zero topic makes "no topic here" and
    ///      "the topic whose key is 0" the same read.
    function test_s8_2b_zeroTopicKeyIsIllegal() public {
        vm.expectRevert(IndexRegistry.ZeroTopicKey.selector);
        logicA.write(_claimKey("LIST"), bytes32(0), APPROVED, 1, false);

        vm.expectRevert(IndexRegistry.ZeroTopicKey.selector);
        logicA.remove(_claimKey("LIST"), bytes32(0));
    }

    /// MUTATION: store the raw index in `posPlusOne` instead of `index + 1`.
    /// @dev `M2.6-F1` verbatim, and this codebase has fixed it once already. A
    ///      position map returning 0 for "absent" cannot distinguish absent from
    ///      FIRST IN THE LIST — so the first entry in a topic is the discriminating
    ///      case, and it is the one tested here.
    function test_s8_2b_theFirstEntryInATopicIsNotReadAsAbsent() public {
        bytes32 first = _claimKey("LIST");
        logicA.write(first, TOPIC_A, APPROVED, 1, false);

        assertEq(idx.listedCount(TOPIC_A), 1);
        assertTrue(idx.isListed(first, TOPIC_A), "the FIRST entry reads as present");

        // ...and delisting it actually works, which is what a raw-index map breaks.
        logicA.write(first, TOPIC_A, REJECTED, 2, false);
        assertFalse(idx.isListed(first, TOPIC_A));
        assertEq(idx.listedCount(TOPIC_A), 0, "swap-and-pop removed it");
    }

    /// @dev The identifier is content-derived and nothing else. Same content, same
    ///      topic, same key — computed off-chain by anyone.
    function test_s8_2b_entryKeyIsAFunctionOfContentAlone() public view {
        bytes32 k = _claimKey("LIST");
        assertEq(idx.entryKeyOf(k, TOPIC_A), keccak256(abi.encode(k, TOPIC_A)));
        assertTrue(idx.entryKeyOf(k, TOPIC_A) != idx.entryKeyOf(k, TOPIC_B), "one entry per (content, topic)");
    }

    /// @dev The migration property: v1 paid a CRITICAL (P0-1a) for a logic-local
    ///      identifier that collided across a migration. An entry written by one
    ///      logic is addressable, at the same key, by a second logic given the same
    ///      content — because no identifier here is a function of insertion order,
    ///      a counter, or any state a logic owns.
    ///
    /// MUTATION: derive the entry key from a per-logic counter.
    function test_s8_2b_anEntryIsAddressableByAReplacementLogic() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);
        bytes32 keyA = idx.entryKeyOf(k, TOPIC_A);

        // A replacement contract, authorised later, re-derives the SAME identifier
        // from the same content and updates the same entry.
        logicB.write(k, TOPIC_A, REJECTED, 2, false);

        assertEq(idx.entryKeyOf(k, TOPIC_A), keyA, "same key");
        assertEq(idx.entryAt(keyA).status, REJECTED, "and the same entry");
        assertEq(idx.listedCount(TOPIC_A), 0, "the replacement's write delisted it");
    }

    // =========================================================================
    // §8.1 — the fifth write
    // =========================================================================

    /// MUTATION: have `removeListing` delete the entry instead of setting REMOVED.
    /// MUTATION: have it set REMOVED without delisting.
    /// @dev The only write that reaches outside its own claim key. A removal case
    ///      carries its own key, so its own terminal writes its own entry by the
    ///      four rows — and when it SUCCEEDS it must also set the original LIST
    ///      entry to `REMOVED`, because that is the entry a reader consults.
    ///
    ///      `REMOVED` is a status and not a deletion: for a safe-search client
    ///      `REMOVED` and `REJECTED` are the same instruction, and the distinction is
    ///      for the reader who wants to know why.
    function test_s8_1_aSuccessfulRemovalSetsTheListEntryRemovedAndDelistsIt() public {
        bytes32 listKey = _claimKey("LIST");
        bytes32 removeKey = _claimKey("REMOVE");
        assertTrue(listKey != removeKey, "actionType earns the removal its own key");

        logicA.write(listKey, TOPIC_A, APPROVED, 1, true);
        assertTrue(idx.isListed(listKey, TOPIC_A));

        // The removal case's own terminal writes its own entry...
        logicA.write(removeKey, TOPIC_A, APPROVED, 1, false);
        // ...and, succeeding, reaches the LIST entry.
        logicA.remove(listKey, TOPIC_A);

        assertEq(idx.statusOf(listKey, TOPIC_A), REMOVED, "the entry a reader consults");
        assertFalse(idx.isListed(listKey, TOPIC_A), "and it left the listing");
        assertEq(idx.listedCount(TOPIC_A), 1, "the removal case's own entry is still listed");

        // The record persists and stays addressable at the same key — the listing
        // and the record are two different objects.
        assertEq(idx.entryAt(idx.entryKeyOf(listKey, TOPIC_A)).status, REMOVED);
    }

    /// @dev A removal that FAILS writes its own entry and touches nothing else.
    ///      `RETAINED` is the case's terminal, not an entry status.
    function test_s8_1_aFailedRemovalLeavesTheListEntryApprovedAndListed() public {
        bytes32 listKey = _claimKey("LIST");
        bytes32 removeKey = _claimKey("REMOVE");

        logicA.write(listKey, TOPIC_A, APPROVED, 1, true);
        logicA.write(removeKey, TOPIC_A, REJECTED, 2, false); // the removal was refused

        assertEq(idx.statusOf(listKey, TOPIC_A), APPROVED, "untouched");
        assertTrue(idx.isListed(listKey, TOPIC_A), "and still listed");
        assertTrue(idx.isSuperSafe(listKey, TOPIC_A), "and still SUPER_SAFE");
    }

    function test_s8_1_removalOfAnEntryThatDoesNotExistReverts() public {
        vm.expectRevert(IndexRegistry.NoSuchEntry.selector);
        logicA.remove(_claimKey("LIST"), TOPIC_A);
    }

    // =========================================================================
    // §8.3 — SUPER_SAFE, and why openQuestions is a counter
    // =========================================================================

    /// MUTATION: make `openQuestions` a boolean.
    /// @dev The case a boolean fails, and the reason §8.3 specifies a counter: two
    ///      concurrent questions closing ONE AT A TIME would clear a boolean while a
    ///      question was still open, and "no question is open" would read true in a
    ///      state it must exclude (I29).
    function test_s8_3_superSafeSurvivesTwoConcurrentQuestions() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);
        assertTrue(idx.isSuperSafe(k, TOPIC_A), "strict and unquestioned");

        logicA.open(k, TOPIC_A);
        assertFalse(idx.isSuperSafe(k, TOPIC_A), "one question stops it");

        logicA.open(k, TOPIC_A); // a second, concurrent
        assertFalse(idx.isSuperSafe(k, TOPIC_A));

        logicA.close(k, TOPIC_A);
        assertFalse(idx.isSuperSafe(k, TOPIC_A), "STILL false - one question remains open");

        logicA.close(k, TOPIC_A);
        assertTrue(idx.isSuperSafe(k, TOPIC_A), "and resumes only when the last closes");
    }

    /// MUTATION: drop the `strict` conjunct from `isSuperSafe`.
    /// @dev The static half. A non-strict entry with no open question is not
    ///      SUPER_SAFE — the counter alone does not confer it.
    function test_s8_3_aNonStrictEntryIsNeverSuperSafe() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, false);
        assertEq(idx.entryOf(k, TOPIC_A).openQuestions, 0);
        assertFalse(idx.isSuperSafe(k, TOPIC_A), "no open question, but not strict");
    }

    /// MUTATION: drop the `openQuestions == 0` conjunct.
    /// @dev The live half is the only thing that moves, and it is why `SUPER_SAFE`
    ///      is a query rather than a stored status: a re-review opened years later
    ///      must revoke it, and a stored flag would go stale.
    function test_s8_3_superSafeIsRevokedWhileAQuestionIsOpen() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);
        assertTrue(idx.isSuperSafe(k, TOPIC_A));
        logicA.open(k, TOPIC_A);
        assertFalse(idx.isSuperSafe(k, TOPIC_A));
    }

    function test_s8_3_closingAQuestionThatIsNotOpenReverts() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);
        vm.expectRevert(IndexRegistry.NoQuestionOpen.selector);
        logicA.close(k, TOPIC_A);
    }

    /// @dev A later terminal rewrites `strict`, so a re-review that ends worse
    ///      takes the label away permanently rather than only while it was open.
    function test_s8_3_aLaterTerminalRewritesTheStaticHalf() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);
        logicA.write(k, TOPIC_A, APPROVED, 1, false); // a re-review, less unanimous
        assertFalse(idx.isSuperSafe(k, TOPIC_A));
    }

    // =========================================================================
    // §8.1 — listing membership tracks status, on every write
    // =========================================================================

    /// MUTATION: add to the listing without checking `status == APPROVED`.
    function test_s8_1_onlyApprovedContentIsListed() public {
        bytes32 k = _claimKey("LIST");
        uint8[5] memory notListed = [PLUR_A, PLUR_R, REJECTED, UNRESOLVED, REMOVED];
        for (uint256 i; i < 5; ++i) {
            logicA.write(k, TOPIC_A, notListed[i], 1, false);
            assertFalse(idx.isListed(k, TOPIC_A), "only APPROVED lists");
            assertEq(idx.listedCount(TOPIC_A), 0);
        }
        logicA.write(k, TOPIC_A, APPROVED, 1, false);
        assertTrue(idx.isListed(k, TOPIC_A));
        assertEq(idx.listedCount(TOPIC_A), 1);
    }

    /// @dev Idempotent in both directions — a repeated APPROVED write must not
    ///      double-list, and a repeated delist must not underflow.
    function test_s8_1_listingIsIdempotent() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, false);
        logicA.write(k, TOPIC_A, APPROVED, 1, false);
        assertEq(idx.listedCount(TOPIC_A), 1, "not double-listed");

        logicA.write(k, TOPIC_A, REJECTED, 2, false);
        logicA.write(k, TOPIC_A, REJECTED, 2, false);
        assertEq(idx.listedCount(TOPIC_A), 0, "not double-removed");
    }

    // =========================================================================
    // §4 — enumeration is paged, and swap-and-pop is O(1)
    // =========================================================================

    function _fill(bytes32 topic, uint256 n) internal returns (bytes32[] memory keys) {
        keys = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            keys[i] = keccak256(abi.encode("bulk", i));
            logicA.write(keys[i], topic, APPROVED, 1, false);
        }
    }

    /// @dev The read side is where an index dies. A topic accumulates entries
    ///      without limit, so no function here may walk one.
    function test_s4_enumerationIsPagedAndCorrectAtScale() public {
        uint256 n = 3000;
        _fill(TOPIC_A, n);
        assertEq(idx.listedCount(TOPIC_A), n);

        // Page through the whole topic and confirm no entry is missed or repeated.
        uint256 seen;
        for (uint256 off; off < n; off += 500) {
            bytes32[] memory page = idx.listedPage(TOPIC_A, off, 500);
            assertEq(page.length, 500);
            seen += page.length;
        }
        assertEq(seen, n, "every entry is reachable by paging");

        // Past the end is empty, not a revert — a client may page until it is.
        assertEq(idx.listedPage(TOPIC_A, n, 100).length, 0);
        // A partial last page is clamped, not padded.
        assertEq(idx.listedPage(TOPIC_A, n - 7, 500).length, 7);
    }

    /// @dev The gas curve, which is the point: a write and a delist must not get
    ///      more expensive as the topic grows, and a page must cost `O(limit)`
    ///      rather than `O(topic)`.
    function test_s4_gasCurveIsFlatInTopicSize() public {
        bytes32[] memory keys = _fill(TOPIC_A, 3000);

        // A write into a 3,000-entry topic.
        uint256 g = gasleft();
        logicA.write(keccak256("late"), TOPIC_A, APPROVED, 1, false);
        uint256 writeAtScale = g - gasleft();

        // A delist from the MIDDLE, which is the swap-and-pop case.
        g = gasleft();
        logicA.write(keys[1500], TOPIC_A, REJECTED, 2, false);
        uint256 delistAtScale = g - gasleft();

        // A page of 50 from a small topic vs the same page from a huge one.
        _fill(TOPIC_B, 10);
        g = gasleft();
        idx.listedPage(TOPIC_B, 0, 10);
        uint256 pageSmall = g - gasleft();
        g = gasleft();
        idx.listedPage(TOPIC_A, 0, 10);
        uint256 pageHuge = g - gasleft();

        emit log_named_uint("write into a 3,000-entry topic ", writeAtScale);
        emit log_named_uint("delist from the middle of 3,000", delistAtScale);
        emit log_named_uint("page(0,10) of a 10-entry topic ", pageSmall);
        emit log_named_uint("page(0,10) of a 3,001-entry topic", pageHuge);

        assertLt(writeAtScale, 120_000, "a write does not grow with the topic");
        assertLt(delistAtScale, 60_000, "nor does a swap-and-pop delist");
        assertApproxEqRel(pageHuge, pageSmall, 0.25e18, "a page costs O(limit), not O(topic)");
    }

    function test_s4_pageOfZeroLimitReverts() public {
        vm.expectRevert(IndexRegistry.BadPage.selector);
        idx.listedPage(TOPIC_A, 0, 0);
    }

    /// @dev Swap-and-pop must not corrupt the survivors' positions.
    function test_s4_delistingPreservesEveryOtherEntry() public {
        bytes32[] memory keys = _fill(TOPIC_A, 10);
        logicA.write(keys[0], TOPIC_A, REJECTED, 2, false); // delist the FIRST
        logicA.write(keys[9], TOPIC_A, REJECTED, 2, false); // and what was the LAST

        assertEq(idx.listedCount(TOPIC_A), 8);
        for (uint256 i = 1; i < 9; ++i) {
            assertTrue(idx.isListed(keys[i], TOPIC_A), "survivor still addressable");
        }
        assertFalse(idx.isListed(keys[0], TOPIC_A));
        assertFalse(idx.isListed(keys[9], TOPIC_A));
    }

    // =========================================================================
    // Writer capability
    // =========================================================================

    /// MUTATION: drop `onlyWriter` from any write path.
    function test_caps_onlyAGrantedLogicMayWrite() public {
        bytes32 k = _claimKey("LIST");
        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotWriter.selector);
        idx.writeEntry(k, TOPIC_A, APPROVED, 1, false, 0);

        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotWriter.selector);
        idx.removeListing(k, TOPIC_A);

        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotWriter.selector);
        idx.openQuestion(k, TOPIC_A);

        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotWriter.selector);
        idx.closeQuestion(k, TOPIC_A);
    }

    /// MUTATION: invert the timelock comparison; drop `onlyGovernance`.
    function test_caps_writeAccessIsGrantedBehindTheTimelock() public {
        MockLogic logicC = new MockLogic(idx);
        vm.prank(gov);
        idx.proposeWriter(address(logicC), true);

        vm.prank(gov);
        vm.expectRevert(IndexRegistry.TimelockNotElapsed.selector);
        idx.executeWriter();

        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotGovernance.selector);
        idx.proposeWriter(stranger, true);

        (,, uint256 eta,) = idx.pendingWriterProposal();
        vm.warp(eta);
        vm.prank(gov);
        idx.executeWriter();
        assertTrue(idx.writers(address(logicC)));
    }

    /// @dev Revocation runs through the same idiom, and a revoked logic loses write
    ///      access without any entry it wrote becoming unaddressable.
    function test_caps_revocationLeavesEntriesIntact() public {
        bytes32 k = _claimKey("LIST");
        logicA.write(k, TOPIC_A, APPROVED, 1, true);

        _grant(address(logicA), false);
        vm.expectRevert(IndexRegistry.NotWriter.selector);
        logicA.write(k, TOPIC_A, REJECTED, 2, false);

        assertEq(idx.statusOf(k, TOPIC_A), APPROVED, "the entry survives its writer");
        assertTrue(idx.isSuperSafe(k, TOPIC_A));
    }

    /// MUTATION: drop `onlyGovernance` from `executeWriter` or `cancelWriter`.
    /// @dev The order says follow `StakeRegistry`'s idiom, and that idiom is
    ///      `onlyGovernance` on ALL THREE. A permissionless execute is a defensible
    ///      timelock design elsewhere, but it is not this project's, and an
    ///      untested "governance only" is not a property — it is a comment.
    function test_caps_everyStepOfTheWriterTimelockIsGovernanceOnly() public {
        MockLogic logicC = new MockLogic(idx);
        vm.prank(gov);
        idx.proposeWriter(address(logicC), true);

        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotGovernance.selector);
        idx.cancelWriter();

        (,, uint256 eta,) = idx.pendingWriterProposal();
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(IndexRegistry.NotGovernance.selector);
        idx.executeWriter();
        assertFalse(idx.writers(address(logicC)), "a stranger cannot grant write access");

        vm.prank(gov);
        idx.executeWriter();
        assertTrue(idx.writers(address(logicC)));
    }

    function test_caps_cancelClearsTheProposal() public {
        MockLogic logicC = new MockLogic(idx);
        vm.prank(gov);
        idx.proposeWriter(address(logicC), true);
        vm.prank(gov);
        idx.cancelWriter();

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(gov);
        vm.expectRevert(IndexRegistry.NoPendingProposal.selector);
        idx.executeWriter();
        assertFalse(idx.writers(address(logicC)));
    }

    function test_governance_isTwoStep() public {
        vm.prank(gov);
        idx.proposeGovernance(stranger);
        assertEq(idx.governance(), gov);
        vm.prank(stranger);
        idx.acceptGovernance();
        assertEq(idx.governance(), stranger);
    }

    // =========================================================================
    // M2.10 — actionType on the entry, and what the fifth write may reach
    // =========================================================================

    /// @dev These two properties are UNREACHABLE through `Moderation`, which only
    ///      ever calls `removeListing` with a key it derived as `ActionType.LIST`.
    ///      That is exactly why they belong here: the index is a standalone contract
    ///      with its own writer capability, and a second logic contract — or a later
    ///      replacement for `Moderation` — is not bound by the caller discipline the
    ///      current one happens to keep. A guard that only holds because today's
    ///      only caller is well-behaved is not a guard.
    ///
    ///      Both survived the M2.10 campaign (M29, M30) with no test naming them.

    /// MUTATION: drop `if (e.actionType != ACTION_LIST) revert NotAListEntry();`
    function test_s8_1_theFifthWriteRefusesToRetargetARemoveEntry() public {
        bytes32 rk = _claimKey("REMOVE");
        logicA.writeAs(rk, TOPIC_A, APPROVED, 0, false, idx.ACTION_REMOVE());

        // A removal case's own record is not a listing, and marking it REMOVED
        // would let one removal overwrite another's answer.
        vm.expectRevert(IndexRegistry.NotAListEntry.selector);
        logicA.remove(rk, TOPIC_A);

        assertEq(uint8(idx.entryOf(rk, TOPIC_A).status), APPROVED, "untouched");
    }

    /// MUTATION: drop `e.actionType = actionType;` from `writeEntry`.
    ///
    /// @dev The default for the field is 0, which IS `ACTION_LIST` — so a dropped
    ///      write does not fail loudly, it silently reclassifies every REMOVE entry
    ///      as a listing answer. That is the shape of defect that survives a suite
    ///      asserting only on happy paths.
    function test_s8_2_theEntryRecordsWhatItsClaimAsked() public {
        bytes32 lk = _claimKey("LIST");
        bytes32 rk = _claimKey("REMOVE");

        logicA.write(lk, TOPIC_A, APPROVED, 0, false);
        logicA.writeAs(rk, TOPIC_A, APPROVED, 0, false, idx.ACTION_REMOVE());

        assertEq(idx.entryOf(lk, TOPIC_A).actionType, idx.ACTION_LIST(), "a listing says so");
        assertEq(idx.entryOf(rk, TOPIC_A).actionType, idx.ACTION_REMOVE(), "and a removal says so");

        // And the classification is what the fifth write's guard reads, so the two
        // entries are not interchangeable to it.
        logicA.remove(lk, TOPIC_A);
        vm.expectRevert(IndexRegistry.NotAListEntry.selector);
        logicA.remove(rk, TOPIC_A);
    }

    /// @dev The listing predicate, at the index's own level rather than through a
    ///      whole case. `Moderation` cannot write an APPROVED REMOVE entry to a
    ///      topic that has no listing, but a writer can.
    ///
    /// MUTATION: drop the `actionType == ACTION_LIST` conjunct in `_syncListing`.
    function test_s8_2_anApprovedRemoveEntryIsNeverListed() public {
        bytes32 rk = _claimKey("REMOVE");
        logicA.writeAs(rk, TOPIC_A, APPROVED, 0, false, idx.ACTION_REMOVE());

        assertFalse(idx.isListed(rk, TOPIC_A), "a takedown record is not content");
        assertEq(idx.listedCount(TOPIC_A), 0, "and the topic stays empty");
    }

    /// MUTATION: drop `if (actionType > ACTION_REMOVE) revert BadActionType();`
    function test_s8_2_anUnknownActionTypeIsRefused() public {
        vm.expectRevert(IndexRegistry.BadActionType.selector);
        logicA.writeAs(_claimKey("LIST"), TOPIC_A, APPROVED, 0, false, 2);
    }
}
