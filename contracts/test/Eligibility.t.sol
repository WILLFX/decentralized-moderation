// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {HistoryFixture} from "./helpers/HistoryFixture.sol";

import {Test, console} from "forge-std/Test.sol";
import {Moderation} from "../src/Moderation.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";
import {MockStakes, MockIndex} from "./Lifecycle.t.sol";

/// @notice Answers `stakedCount` and nothing else. `_eligBits` reads only that, so
///         a registry of 65,536 costs one constructor argument rather than 65,536
///         calls to a real mock — which is the difference between a test that runs
///         and a test nobody runs.
contract FixedCount {
    uint256 public stakedCount;

    constructor(uint256 n) {
        stakedCount = n;
    }

    function isActive(address) external pure returns (bool) {
        return true;
    }

    function isFrozen(address) external pure returns (bool) {
        return false;
    }

    function noteCommit(address) external {}
    function settle(address, bool, uint256) external {}
}

/// @notice Exposes `_eligBits` so the threshold can be compared against an
///         independent derivation instead of only against itself, and lets a case
///         be planted at a chosen bit width.
///
///         Planting is what makes the differential mean anything. A real registry
///         puts `eligBits` at 2 for any size from 64 to 127, and reaching 5 bits
///         needs 512 staked identities — so the narrowing hash would only ever be
///         compared at ONE width, and a mistake in the shift would be tested
///         exactly once. The threshold itself is pinned separately by
///         `test_eligBitsAcrossTheWholeRange`, so nothing is assumed here that is
///         not checked somewhere.
contract BitsHarness is Moderation {
    constructor(address t, address s, address i)
        Moderation(Moderation.Config(t, s, i, 15 minutes, 30 minutes, 1 hours, 1 hours, 8 days, 2, 1, 1, 1, keccak256("g")))
    {}

    function eligBits() external view returns (uint8) {
        return _eligBits();
    }

    function plantCase(uint256 caseId, uint8 bits, uint40 seedBlock) external {
        Case storage c = cases[caseId];
        c.eligBits = bits;
        c.seedBlockA = seedBlock;
        c.seedBlockB = seedBlock;
    }

    function probe(uint256 caseId, address m, uint8 committee) external view returns (bool) {
        return _eligible(caseId, m, committee);
    }

    function committeeOf(uint8 phase) external pure returns (uint8) {
        return _committeeOf(phase);
    }
}

/// @notice §3 — eligibility, pinned against an independent derivation.
///
/// `Integration.t.sol` checks that eligibility narrows: at 64 staked, roughly a
/// quarter are eligible under N−4. That constrains the COUNT and nothing else.
/// The historical N−5 suite admitted an inverted predicate because the complement
/// of a half-sized set was also half-sized. The differential pins WHICH identities
/// pass, so it also detects preimage errors that leave the expected count intact.
///
/// This suite closes that the way `Draw.t.sol` plus `simulation/check_draw_vectors.py`
/// closed the same gap on the draw:
///
/// - `test_emitEligibilityVectors` writes the identity-by-identity verdict for both
///   committees of a real case, at a registry large enough that the narrowing hash
///   actually runs, and `simulation/check_eligibility_vectors.py` re-derives every
///   one from a pure-Python keccak that refuses to load unless it reproduces
///   published KATs — and sabotages its own derivation to prove it would notice.
/// - `test_eligBitsAcrossTheWholeRange` pins the threshold itself, which the
///   differential takes as given.
/// - the rest are the seed-window boundaries, which a differential cannot reach
///   because they are about reverting rather than about the hash.
contract EligibilityTest is HistoryFixture {
    Moderation mod;
    MockBZZ token;
    MockStakes stakes;
    MockIndex index;

    address submitter = address(0x5011);
    /// @dev 64 staked puts `eligBits` at 2 under N−4. Narrowing first applies at
    ///      32 staked; the 64 identities here cover both accepted and rejected
    ///      identities in each committee.
    uint256 constant STAKED = 64;
    address[] mods;

    uint8 constant APPROVE = 1;
    uint256 constant SEED_LAG = 2;
    uint256 constant MAX_WAIT = 1 hours;
    uint256 constant REVEAL_WINDOW = 30 minutes;
    uint256 constant FEE = 1000;

    uint256 blk = 100;
    uint256 ts = 1_000_000;

    function setUp() public {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(Moderation.Config(address(token), address(stakes), address(index),
            15 minutes, REVEAL_WINDOW, 1 hours, MAX_WAIT, 8 days, SEED_LAG, FEE, 1,
            1, keccak256("g")));
        for (uint256 i; i < STAKED; ++i) {
            address m = address(uint160(0x30000 + i));
            mods.push(m);
            stakes.add(m);
        }
        token.mint(submitter, 1_000_000);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);
        vm.roll(blk);
        vm.warp(ts);
    }

    function _advance(uint256 n) internal {
        blk += n;
        vm.roll(blk);
    }

    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function _submit(string memory salt) internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        id = mod.submit(keccak256(abi.encode(salt)), keccak256("meta"), topics, FEE);
    }

    // --------------------------------------------------- the threshold itself

    /// @dev §3 says `N` is chosen so the registry lies in `[2^N, 2^(N+1))` and the
    ///      threshold is `max(N − 4, 0)`. The expected eligible population is
    ///      [16, 32) for S >= 16, before frozen, prior-vote and turnout exclusions.
    ///      Literal boundaries pin both the floor-log2 step and subtraction.
    ///
    ///      The expected values here are computed from the DEFINITION, not copied
    ///      from the loop: `N` is the index of the highest set bit.
    function test_eligBitsAcrossTheWholeRange() public {
        uint256[19] memory sizes = [
            uint256(0), 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100,
            511, 512, 1000, 1023, 1024, 65536
        ];
        uint8[19] memory want = [0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 4, 5, 5, 5, 6, 12];

        for (uint256 k; k < sizes.length; ++k) {
            BitsHarness h = new BitsHarness(
                address(token), address(new FixedCount(sizes[k])), address(index)
            );
            assertEq(
                h.eligBits(),
                want[k],
                string.concat("eligBits at registry ", vm.toString(sizes[k]))
            );
        }
    }

    /// @dev The consequence §3 claims, stated as a range rather than a count: the
    ///      expected committee is `registry * 2^-bits`, which the threshold keeps
    ///      inside [16, 32) for every registry of 16 or more. This is eligibility,
    ///      not a guarantee of participation or three reveals per committee.
    function test_expectedEligiblePopulationIsSixteenToThirtyTwo() public {
        uint256[11] memory sizes = [uint256(16), 31, 32, 63, 64, 100, 511, 512, 1000, 1024, 65536];
        for (uint256 k; k < sizes.length; ++k) {
            BitsHarness h = new BitsHarness(
                address(token), address(new FixedCount(sizes[k])), address(index)
            );
            uint256 expected = sizes[k] >> h.eligBits();
            assertGe(expected, 16, string.concat("too narrow at ", vm.toString(sizes[k])));
            assertLt(expected, 32, string.concat("too wide at ", vm.toString(sizes[k])));
        }
    }

    /// @dev The phase-derived committee must equal the explicit one. `commit` and
    ///      `isEligible` reach `_eligible` through `_committeeOf(phase)`; the width
    ///      sweep reaches it with an explicit number. If those two disagree the
    ///      contract is asking about a committee nobody is in.
    ///
    ///      This is the only in-Solidity check on the committee number, and it is
    ///      needed because the Python differential cannot supply it: a mutant that
    ///      makes `_committeeOf` return 3 for COMMIT_B also REGENERATES the vectors
    ///      with 3, and the differential is a separate script that `forge test` never
    ///      runs. So the mutation campaign is blind to it and this is not.
    function test_thePhaseDerivedCommitteeMatchesTheExplicitOne() public {
        BitsHarness h = new BitsHarness(address(token), address(stakes), address(index));
        _advance(5);
        uint40 sb = uint40(block.number - 3);
        _recordHistory(sb, keccak256("committee history"));
        vm.setBlockhash(sb, keccak256("committee history"));
        h.plantCase(1, 1, sb);

        assertEq(h.committeeOf(uint8(Moderation.Phase.COMMIT_A)), 1, "COMMIT_A is committee 1");
        assertEq(h.committeeOf(uint8(Moderation.Phase.COMMIT_B)), 2, "COMMIT_B is committee 2");
        assertEq(h.committeeOf(uint8(Moderation.Phase.REVEAL)), 0, "REVEAL has no committee");
        assertEq(h.committeeOf(uint8(Moderation.Phase.CHALLENGE)), 0, "nor CHALLENGE");
        assertEq(h.committeeOf(uint8(Moderation.Phase.FINALIZED)), 0, "nor FINALIZED");

        // and the two committee numbers really are different draws over the same seed
        uint256 differ;
        for (uint256 i; i < mods.length; ++i) {
            if (h.probe(1, mods[i], 1) != h.probe(1, mods[i], 2)) ++differ;
        }
        assertGt(differ, 0, "committee 1 and 2 must not be the same set");
    }

    // ------------------------------------------------------- the differential

    /// @dev Writes the identity-by-identity verdict for BOTH committees of one real
    ///      case. Both matter: the committee number is mixed into the hash, and a
    ///      wrong one produces a set of the right size, uniformly distributed,
    ///      passing every count check while quietly correlating the two committees.
    ///
    ///      The seed is recorded rather than recomputed, because it is a blockhash
    ///      the Python side cannot produce. Everything downstream of it is derived
    ///      independently.
    function test_emitEligibilityVectors() public {
        uint256 id = _submit("vectors");
        Moderation.Case memory c = mod.caseInfo(id);
        assertGt(c.eligBits, 0, "the narrowing hash must actually run");

        _advance(SEED_LAG + 1);

        string memory out = "[";
        uint256 n;

        // committee A — phase COMMIT_A
        (out, n) = _emitPhase(id, out, n);

        // close A with enough commits to move on, then committee B — phase COMMIT_B
        for (uint256 i; i < mods.length && mod.caseInfo(id).commitsA < 3; ++i) {
            if (!mod.isEligible(id, mods[i])) continue;
            bytes32 h = mod.commitHash(id, 0, mods[i], APPROVE, bytes32("s"));
            vm.prank(mods[i]);
            mod.commit(id, h);
        }
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        blk = _readyB(mod, id);
        _advance(SEED_LAG + 1);
        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.COMMIT_B));

        (out, n) = _emitPhase(id, out, n);
        out = string.concat(out, "]");

        c = mod.caseInfo(id);
        string memory doc = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"contract":"',
            vm.toString(address(mod)),
            '","eligBits":',
            vm.toString(c.eligBits),
            ',"stakedCount":',
            vm.toString(stakes.stakedCount()),
            ',"vectors":',
            out,
            "}"
        );
        vm.writeFile("test/vectors/eligibility_vectors.json", doc);
        console.log("wrote eligibility vectors:", n);
    }

    /// @dev One record per staked identity, at whatever phase the case is in.
    function _emitPhase(uint256 id, string memory out, uint256 n)
        internal
        view
        returns (string memory, uint256)
    {
        Moderation.Case memory c = mod.caseInfo(id);
        uint8 phase = c.phase;
        uint40 sb = phase == uint8(Moderation.Phase.COMMIT_A) ? c.seedBlockA : c.seedBlockB;
        bytes32 seed = blockhash(sb);

        for (uint256 i; i < mods.length; ++i) {
            bool e = mod.isEligible(id, mods[i]);
            if (n > 0) out = string.concat(out, ",");
            out = string.concat(
                out,
                '{"caseId":',
                vm.toString(id),
                ',"phase":',
                vm.toString(phase),
                ',"seed":"',
                vm.toString(seed),
                '","moderator":"',
                vm.toString(mods[i]),
                '","eligible":',
                e ? "true" : "false",
                "}"
            );
            ++n;
        }
        return (out, n);
    }

    /// @dev The same predicate across BIT WIDTHS, which a real registry cannot
    ///      reach: `eligBits` is 2 for every registry from 64 to 127, and 5 bits
    ///      needs 512 staked. Without this the narrowing hash is compared at one
    ///      width only, and the shift is tested exactly once.
    ///
    ///      Both committee numbers are swept at every width, because the committee
    ///      is in the preimage and is the only thing making A and B different draws.
    function test_emitEligibilityWidthVectors() public {
        BitsHarness h = new BitsHarness(address(token), address(stakes), address(index));

        // a seed block in the past, inside the horizon, so `blockhash` answers
        _advance(5);
        uint40 sb = uint40(block.number - 3);

        _recordHistory(sb, keccak256("width history"));
        vm.setBlockhash(sb, keccak256("width history"));

        // Written line by line, not built up with `string.concat`. Concatenating
        // hundreds of records is quadratic in memory and this test died of
        // MemoryOOG at 512 of them; appending is linear. The format is therefore
        // JSONL: a header object, then one object per vector.
        string memory path = "test/vectors/eligibility_width_vectors.jsonl";
        vm.writeFile(path, "");
        vm.writeLine(
            path,
            string.concat(
                '{"header":true,"chainId":',
                vm.toString(block.chainid),
                ',"contract":"',
                vm.toString(address(h)),
                '","seed":"',
                vm.toString(blockhash(sb)),
                '"}'
            )
        );

        uint256 n;
        for (uint8 bits = 1; bits <= 4; ++bits) {
            uint256 caseId = uint256(bits);
            h.plantCase(caseId, bits, sb);
            for (uint8 committee = 1; committee <= 2; ++committee) {
                for (uint256 i; i < mods.length; ++i) {
                    bool e = h.probe(caseId, mods[i], committee);
                    vm.writeLine(
                        path,
                        string.concat(
                            '{"caseId":',
                            vm.toString(caseId),
                            ',"committee":',
                            vm.toString(committee),
                            ',"bits":',
                            vm.toString(bits),
                            ',"moderator":"',
                            vm.toString(mods[i]),
                            '","eligible":',
                            e ? "true" : "false",
                            "}"
                        )
                    );
                    ++n;
                }
            }
        }
        console.log("wrote width vectors:", n);
    }

    // ------------------------------------------------------ the seed window

    /// @dev A seed cannot be read at its own block — `blockhash(block.number)` is
    ///      zero, so eligibility there would be computed against no entropy and
    ///      every identity would get the same answer forever. Kills
    ///      `block.number <= sb` -> `<` in `_eligible`.
    function test_eligibilityAtTheSeedBlockItselfReverts() public {
        uint256 id = _submit("window");
        uint256 sb = mod.caseInfo(id).seedBlockA;

        vm.roll(sb);
        vm.expectRevert(Moderation.SeedUnavailable.selector);
        mod.isEligible(id, mods[0]);

        vm.roll(sb + 1);
        mod.isEligible(id, mods[0]); // and one past it answers
    }

    /// @dev Only 256 blockhashes are addressable, so a seed expires. The horizon is
    ///      inclusive: at exactly `sb + BLOCKHASH_HORIZON` the hash is still
    ///      readable and eligibility must still answer. Kills
    ///      `block.number > sb + BLOCKHASH_HORIZON` -> `>=` in `_eligible`.
    function test_theSeedHorizonIsInclusive() public {
        uint256 id = _submit("horizon");
        uint256 sb = mod.caseInfo(id).seedBlockA;
        uint256 horizon = mod.BLOCKHASH_HORIZON();

        vm.roll(sb + horizon);
        mod.isEligible(id, mods[0]); // the last block that still works

        vm.roll(sb + horizon + 1);
        vm.expectRevert(Moderation.SeedUnavailable.selector);
        mod.isEligible(id, mods[0]);
    }

    /// @dev Outside a commit phase nobody is eligible, because there is no committee
    ///      to be eligible for. Kills `if (committee == 0) return false` -> `true`,
    ///      which would tell every client that every identity may vote in a case
    ///      that has stopped accepting votes.
    function test_nobodyIsEligibleOutsideACommitPhase() public {
        uint256 id = _submit("phases");
        _advance(SEED_LAG + 1);
        for (uint256 i; i < mods.length && mod.caseInfo(id).commitsA < 3; ++i) {
            if (!mod.isEligible(id, mods[i])) continue;
            bytes32 h = mod.commitHash(id, 0, mods[i], APPROVE, bytes32("s"));
            vm.prank(mods[i]);
            mod.commit(id, h);
        }
        _wait(MAX_WAIT + 1);
        mod.closeCommitA(id);
        blk = _readyB(mod, id);
        _advance(SEED_LAG + 1);
        for (uint256 i; i < mods.length && mod.caseInfo(id).commitsB < 1; ++i) {
            if (!mod.isEligible(id, mods[i])) continue;
            bytes32 h = mod.commitHash(id, 0, mods[i], APPROVE, bytes32("s"));
            vm.prank(mods[i]);
            mod.commit(id, h);
        }
        _wait(MAX_WAIT + 1);
        mod.closeCommitB(id);

        assertEq(mod.caseInfo(id).phase, uint8(Moderation.Phase.REVEAL));
        for (uint256 i; i < 8; ++i) {
            assertFalse(mod.isEligible(id, mods[i]), "REVEAL has no committee");
        }
    }
}
