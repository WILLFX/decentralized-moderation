// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title FreezeMath
/// @notice The freezing-power curve of spec §6.4:
///
///         power    = 1 + (CAP - 1) * (1 - exp(-meanTrack / SAT))     in [1, CAP]
///         freezeDur = FREEZE_BASE * power
///
///         `meanTrack` is the seat-weighted MEAN of the winning side's track
///         records (split-resistant, principle 4), passed in WAD. The saturating
///         shape means track amplifies a freeze only up to CAP, and a cheap farm
///         cannot approach it (calibrated in the M1 simulation, FINDINGS §3).
/// @dev All fractional quantities are WAD (1e18). Track counts are WAD-scaled
///      (a raw track of 1 == 1e18). Uses solady expWad for exp of a negative arg
///      (result in (0, 1]).
library FreezeMath {
    uint256 internal constant WAD = 1e18;

    /// @param meanTrackWad Seat-weighted mean coherent track (WAD).
    /// @param satWad TRACK_SAT (WAD).
    /// @param capWad FREEZE_CAP multiplier (WAD, >= 1e18).
    /// @return powerWad Freezing power in [1e18, capWad].
    function freezingPower(uint256 meanTrackWad, uint256 satWad, uint256 capWad)
        internal
        pure
        returns (uint256 powerWad)
    {
        if (capWad <= WAD || satWad == 0) return WAD; // no amplification configured
        // exp(-meanTrack / SAT): arg is negative, so expWad returns a value in (0, 1].
        int256 arg = -int256((meanTrackWad * WAD) / satWad);
        uint256 e = uint256(FixedPointMathLib.expWad(arg)); // (0, 1e18]
        uint256 oneMinusE = WAD - e; // [0, 1e18)
        uint256 term = ((capWad - WAD) * oneMinusE) / WAD; // [0, capWad-WAD)
        powerWad = WAD + term; // [1e18, capWad)
    }

    /// @return Freeze duration in seconds = baseSeconds * power / WAD.
    function freezeDuration(uint256 meanTrackWad, uint256 satWad, uint256 capWad, uint256 baseSeconds)
        internal
        pure
        returns (uint256)
    {
        uint256 p = freezingPower(meanTrackWad, satWad, capWad);
        return (baseSeconds * p) / WAD;
    }
}
