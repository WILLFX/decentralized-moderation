// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StakeRegistry} from "../../src/StakeRegistry.sol";

/// @notice Test-only subclass exposing the one fixture the differential and
///         gas-bound suites need: booking committed stake directly.
///
///         Those suites build a FINALIZED case in storage and replay only its
///         settlement arithmetic, so their voters never went through
///         stake -> activate -> pledge -> commitVote. `__injectCommitted` writes
///         exactly the state that path would have left behind (committed +
///         totalCommittedStake), and the caller mints the matching tokens to the
///         registry so conservation holds from the first assertion.
contract StakeRegistryHarness is StakeRegistry {
    constructor(
        IERC20 _token,
        uint256 _timelockDelay,
        uint256 _minStake,
        uint256 _activationDelay,
        uint256 _exitCooldown,
        uint256 _riskPerSeat
    ) StakeRegistry(_token, _timelockDelay, _minStake, _activationDelay, _exitCooldown, _riskPerSeat) {}

    function __injectCommitted(address moderator, uint256 amount) external {
        Moderator storage m = moderators[moderator];
        m.exists = true;
        m.committed += amount;
        totalCommittedStake += amount;
    }

    /// Credit free stake without a deposit (fixture for suites that need a
    /// funded, drawable moderator without replaying the activation delay).
    function __injectFree(address moderator, uint256 amount) external {
        Moderator storage m = moderators[moderator];
        m.exists = true;
        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
    }

    function __setTrack(address moderator, uint256 track) external {
        moderators[moderator].track = track;
    }
}
