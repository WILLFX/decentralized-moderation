// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";
import {ModerationAuthority} from "./ModerationAuthority.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title StakeRegistry
/// @notice Moderator custody for `specs/protocol.md` §2: a fixed-size stake, and
///         a total frozen time. That is the whole of it.
///
/// **There is no bond.** The previous revision carried `bond`, `liabilities`,
/// `openVoteCount`, `openChallenges` and a claim ledger, and its solvency check
/// was a concurrency limit as a side effect — which is how a design with
/// unlimited concurrency ended up capped. §2 grants unlimited concurrency, so
/// nothing here reserves, encumbers or debits anything.
///
/// **The stake is never taken.** Not slashed, not redistributed, not transferred.
/// Time is the only currency of penalty, and a frozen moderator's stake is idle
/// rather than gone.
///
/// **Freezes are additive.** `frozenUntil = max(now, frozenUntil) + duration`
/// accumulates the *total* time served: three losses cost the sum of their
/// durations whatever order they settle in. The earlier design stacked intervals
/// in a way that made the same three losses cost 24 days or 19 depending on
/// order; this does not, because the base is never re-derived from a moving
/// deadline.
contract StakeRegistry {
    using SafeTransferLib for address;

    struct Moderator {
        bool staked;
        uint40 frozenUntil;
        uint32 openVotes; // §A below — not in the spec, and required by it
        uint128 totalFrozen; // cumulative, for observability
    }

    IERC20 public immutable token;
    uint256 public immutable stakeAmount;

    ModerationAuthority public immutable authority;
    mapping(address => mapping(uint256 => mapping(address => uint8))) public obligation;
    error InvalidObligation();

    mapping(address => Moderator) internal mods;
    uint256 public stakedCount;

    event Staked(address indexed m);
    event Withdrawn(address indexed m);
    event Frozen(address indexed m, uint256 duration, uint40 until);

    error AlreadyStaked();
    error NotStaked();
    error IsFrozen();
    error HasOpenVotes();

    constructor(ModerationAuthority authority_) {
        authority = authority_;
        token = IERC20(authority_.token());
        stakeAmount = authority_.stakeAmount();
    }

    // ------------------------------------------------------------- staking

    /// @dev §2 — every stake is the same size. Influence is bought by running
    ///      more identities, each paying its own stake, never by staking more.
    function stake() external {
        Moderator storage s = mods[msg.sender];
        if (s.staked) revert AlreadyStaked();
        s.staked = true;
        ++stakedCount;
        address(token).safeTransferFrom(msg.sender, address(this), stakeAmount);
        emit Staked(msg.sender);
    }

    /// @dev Blocked while frozen, and blocked with votes still open.
    ///
    ///      **The second guard is not in the spec and the spec needs it.** If the
    ///      only penalty is a freeze, then committing and withdrawing before
    ///      settlement escapes every penalty the design has — there is nothing
    ///      else to take. One counter closes that; see §A.
    function withdraw() external {
        Moderator storage s = mods[msg.sender];
        if (!s.staked) revert NotStaked();
        if (s.frozenUntil > block.timestamp) revert IsFrozen();
        if (s.openVotes != 0) revert HasOpenVotes();

        s.staked = false;
        --stakedCount;
        address(token).safeTransfer(msg.sender, stakeAmount);
        emit Withdrawn(msg.sender);
    }

    // ---------------------------------------------------------- from cases

    function noteCommit(uint256 id, address voter) external {
        authority.requireCase(msg.sender, id, true);
        Moderation.Vote memory v = Moderation(msg.sender).voteOf(id, voter);
        if (
            obligation[msg.sender][id][voter] != 0 || v.commitment == bytes32(0) || v.settled || !mods[voter].staked
                || mods[voter].frozenUntil > block.timestamp
        ) {
            revert InvalidObligation();
        }
        obligation[msg.sender][id][voter] = 1;
        ++mods[voter].openVotes;
    }

    /// @dev Reads the registered case and settled vote. Non-reveal always freezes;
    /// a revealed vote freezes only when it differs from the completed outcome.
    function settle(uint256 id, address voter) external {
        authority.requireCase(msg.sender, id, false);
        Moderation.Case memory c = Moderation(msg.sender).caseInfo(id);
        Moderation.Vote memory v = Moderation(msg.sender).voteOf(id, voter);
        bool resolved = c.phase == uint8(Moderation.Phase.FINALIZED);
        if (
            (!resolved && c.phase != uint8(Moderation.Phase.UNRESOLVED)) || obligation[msg.sender][id][voter] != 1
                || !v.settled || v.commitment == bytes32(0) || mods[voter].openVotes == 0
        ) revert InvalidObligation();
        obligation[msg.sender][id][voter] = 2;
        bool frozen = v.revealed == 0 || (resolved && v.revealed != c.preliminary);
        _settle(voter, frozen, Moderation(msg.sender).freezePerLoss());
    }

    function _settle(address m, bool incoherent, uint256 duration) internal {
        Moderator storage s = mods[m];
        if (s.openVotes != 0) --s.openVotes;
        if (!incoherent) return;

        // `>` vs `>=` here is an EQUIVALENT mutant and mutation testing will
        // always report it as a survivor: when the two are equal both branches
        // yield the same value. Do not chase it.
        uint256 base = s.frozenUntil > block.timestamp ? s.frozenUntil : block.timestamp;
        uint40 until_ = uint40(base + duration);
        s.frozenUntil = until_;
        s.totalFrozen += uint128(duration);
        emit Frozen(m, duration, until_);
    }

    // --------------------------------------------------------------- views

    function isActive(address a) external view returns (bool) {
        return mods[a].staked;
    }

    function isFrozen(address a) external view returns (bool) {
        return mods[a].frozenUntil > block.timestamp;
    }

    function frozenUntil(address a) external view returns (uint40) {
        return mods[a].frozenUntil;
    }

    function totalFrozen(address a) external view returns (uint256) {
        return mods[a].totalFrozen;
    }

    function openVotes(address a) external view returns (uint32) {
        return mods[a].openVotes;
    }

    function infoOf(address a) external view returns (Moderator memory) {
        return mods[a];
    }
}

/*
 * §A. `openVotes`, and what it does not fix
 * ----------------------------------------
 * The spec says the only penalty is a freeze. A penalty you can step out of is
 * not one, so a moderator with an unsettled vote cannot withdraw. That is the
 * counter's whole job and it is one `uint32`.
 *
 * **It does not close identity rotation, and nothing here does.** After a case
 * settles, a frozen moderator can withdraw the stake — no, they cannot, they are
 * frozen — but they can leave the frozen stake idle and stake a *fresh* address,
 * and be voting again immediately. The cost of escaping a freeze is therefore one
 * stake's worth of capital tied up for the freeze duration, which is exactly the
 * cost of serving it. The freeze deters only to the extent that capital is
 * scarce.
 *
 * The previous design answered this with stake maturation (a fresh identity
 * cannot vote for a period) and a non-transferable track record. `specs/
 * protocol.md` §10.3 lists both as built without being asked for, and neither is
 * reinstated here. **This is an open question, not a solved one**, and it is the
 * sharpest one the freeze-only penalty raises.
 */
