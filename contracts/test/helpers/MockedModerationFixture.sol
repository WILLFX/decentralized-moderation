// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HistoryFixture} from "./HistoryFixture.sol";
import {Moderation} from "../../src/Moderation.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @notice Stake custody reduced to what `specs/protocol.md` §2 asks for: a
///         stake, and a total frozen time. No bond, no liabilities, no claims.
contract MockStakes {
    mapping(address => bool) public active;
    mapping(address => uint256) public frozenUntil;
    mapping(address => uint256) public totalFrozen;
    uint256 public stakedCount;

    function add(address a) external {
        active[a] = true;
        ++stakedCount;
    }

    function isActive(address a) external view returns (bool) {
        return active[a];
    }

    function isFrozen(address a) external view returns (bool) {
        return frozenUntil[a] > block.timestamp;
    }

    mapping(address => uint32) public openVotes;

    function noteCommit(address a) external {
        ++openVotes[a];
    }

    /// @dev §2 — durations are ADDITIVE to a total, not extensions from now, so
    ///      the same losses cost the same whatever order they settle in.
    function settle(address a, bool incoherent, uint256 duration) external {
        if (openVotes[a] != 0) --openVotes[a];
        if (!incoherent) return;
        totalFrozen[a] += duration;
        uint256 base = frozenUntil[a] > block.timestamp ? frozenUntil[a] : block.timestamp;
        frozenUntil[a] = base + duration;
    }

    function freeze(address a, uint256 duration) external {
        totalFrozen[a] += duration;
        uint256 base = frozenUntil[a] > block.timestamp ? frozenUntil[a] : block.timestamp;
        frozenUntil[a] = base + duration;
    }
}

contract MockIndex {
    struct Entry {
        bool written;
        bool allTicketsApprove;
        bool everChallenged;
    }

    mapping(bytes32 => Entry) public entries;
    uint256 public writes;

    function writeEntry(bytes32 claimKey, bytes32, uint8, bool allTicketsApprove, bool everChallenged, uint32, uint32)
        external
    {
        entries[claimKey] = Entry(true, allTicketsApprove, everChallenged);
        ++writes;
    }

    mapping(bytes32 => bool) public gone;
    uint256 public removals;

    function removeListing(bytes32 claimKey, bytes32) external {
        gone[claimKey] = true;
        ++removals;
    }
}

/// @dev Common floor-one setup; each suite selects its original moderator count.
abstract contract MockedModerationFixture is HistoryFixture {
    Moderation internal mod;
    MockBZZ internal token;
    MockStakes internal stakes;
    MockIndex internal index;

    uint256 internal constant COMMIT_WINDOW = 15 minutes;
    uint256 internal constant REVEAL_WINDOW = 30 minutes;
    uint256 internal constant CHALLENGE_WINDOW = 1 hours;
    uint256 internal constant MAX_WAIT = 1 hours;
    uint256 internal constant FREEZE = 8 days;
    uint256 internal constant SEED_LAG = 2;
    uint256 internal constant FEE = 1000;
    /// @dev The WEAKEST per-committee reveal floor. These suites exercise the
    ///      lifecycle, not the floor, and at k = 1 every scenario below keeps the
    ///      shape it had before the floor existed. The floor itself is tested at
    ///      its deployed value in `RevealFloor.t.sol`.
    uint256 internal constant FLOOR = 1;
    /// @dev This suite is about the lifecycle, not the guidelines pin; any non-zero
    ///      pair satisfies the constructor. `Integration.t.sol` is where the pin is
    ///      checked against the real document.
    uint32 internal constant GUIDELINES_VERSION = 1;
    bytes32 internal constant GUIDELINES_HASH = keccak256("guidelines-v1-test");

    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;

    address internal submitter = address(0x5011);
    address[] internal mods;

    /// @dev Block height tracked explicitly. `block.number` is cached within a
    ///      call frame, so `vm.roll(block.number + n)` silently no-ops after the
    ///      first read in a test body.
    uint256 internal blk = 100;
    uint256 internal ts = 1_000_000;

    function _advance(uint256 n) internal {
        blk += n;
        vm.roll(blk);
    }

    /// @dev `block.timestamp` is cached in a call frame for the same reason, so
    ///      time is tracked explicitly too.
    function _wait(uint256 n) internal {
        ts += n;
        vm.warp(ts);
    }

    function _setUpMockedModeration(uint256 moderatorCount) internal {
        token = new MockBZZ();
        stakes = new MockStakes();
        index = new MockIndex();
        mod = new Moderation(
            Moderation.Config(
                address(token),
                address(stakes),
                address(index),
                COMMIT_WINDOW,
                REVEAL_WINDOW,
                CHALLENGE_WINDOW,
                MAX_WAIT,
                FREEZE,
                SEED_LAG,
                FEE,
                FLOOR,
                GUIDELINES_VERSION,
                GUIDELINES_HASH
            )
        );

        mods = new address[](moderatorCount);
        for (uint256 i; i < mods.length; ++i) {
            mods[i] = address(uint160(0x1000 + i));
            stakes.add(mods[i]);
        }
        token.mint(submitter, 1_000_000);
        vm.prank(submitter);
        token.approve(address(mod), type(uint256).max);
        vm.roll(blk);
        vm.warp(ts);
    }

    function _submit() internal returns (uint256 id) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("biology");
        vm.prank(submitter);
        id = mod.submit(keccak256("content"), keccak256("meta"), topics, FEE);
    }
}
