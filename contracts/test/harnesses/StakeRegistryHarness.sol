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
        uint256 _riskPerSeat,
        uint256 _epochBlocks,
        uint256 _minTrackDecay
    )
        StakeRegistry(
            _token,
            _timelockDelay,
            _minStake,
            _activationDelay,
            _exitCooldown,
            _riskPerSeat,
            _epochBlocks,
            _minTrackDecay
        )
    {}

    /// Fabricate the obligation record a real `lock` would have created, so
    /// injected settlement fixtures exercise the same debit path (M2.6-P0-5).
    /// @param seats Seats the obligation was drawn for. M2.6-K-5: `drawPanel`
    ///        stamps `drawnUnits` per seat and `recordParticipation` refuses an
    ///        obligation that shows no draw, so an injector that skipped it would
    ///        make every injected settlement revert at the track write.
    ///
    /// ## SCOPE LIMIT: injected obligations model the COMMITTED side only
    ///
    /// This is a documented omission, not an oversight, and it is stated here
    /// rather than topped up. `drawPanel` writes the whole duty side per seat —
    /// `ob.dutyUnits`, `ob.dutyBonded`, `ob.drawnUnits`, `logicDutyReserved`,
    /// `m.dutyReserved`, `m.dutyBonded` — and this writes three things:
    /// `o.committed`, `o.drawnUnits`, `logicCommitted`. So an injected obligation
    /// sits in a state no real one ever holds: post-lock on the committed side,
    /// with `dutyUnits == 0` and `dutyBonded == 0`.
    ///
    /// The consequence is concrete: **`settleDuty` is a no-op in every injected
    /// fixture** (it clamps `rel` to `o.dutyUnits`, which is zero), so injected
    /// cases never exercise escrow release or the H-07/H-10 no-show penalty. The
    /// differential corpus and the gas-bound suites are therefore silent about
    /// duty disposal. They were never claimed to cover it; this says so out loud.
    ///
    /// **Do not fix it partially.** Setting `o.dutyUnits = seats` without also
    /// raising `m.dutyReserved` and `logicDutyReserved` makes `settleDuty`
    /// underflow — the injector would trade a silent gap for a loud crash in
    /// suites that are not about duty at all.
    ///
    /// **And not fully, here.** Full fidelity makes `settleDuty` start firing
    /// inside injected settlements, which moves the differential vectors' expected
    /// values and requires `reference_int.py` to learn duty disposal. That is a
    /// corpus regeneration, and M2.6-item-11 already scopes one for two other
    /// reasons (the banked round and the short draw). Doing it here means
    /// regenerating twice, so the full-fidelity rebuild is folded into item 11.
    function __injectObligation(
        address logic,
        address moderator,
        uint256 caseRef,
        uint256 committed,
        uint256 seats
    ) external {
        StakeRegistry.Obligation storage o = obligations[obligationKey(logic, moderator, caseRef)];
        o.committed += uint104(committed);
        o.drawnUnits += uint16(seats);
        logicCommitted[logic] += committed;
    }

    /// M2.6-K-5: set a moderator's track directly. `setTrack` is deleted from the
    /// production surface, and the fixtures that used it were setting up a
    /// pre-existing standing to measure the freeze curve against — a state a real
    /// moderator reaches by participating, which no fixture wants to replay.
    /// Test-only, on the harness, reachable by no logic contract.
    function __forceTrack(address moderator, uint256 track) external {
        moderators[moderator].track = track;
    }

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
