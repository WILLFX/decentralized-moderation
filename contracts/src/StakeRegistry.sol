// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SortitionTree} from "./lib/SortitionTree.sol";

/// @title StakeRegistry
/// @notice Custody + bookkeeping for moderator stake, independent of the
///         moderation game's business logic (M2.5-P0-b).
///
///         The moderation protocol is expected to be improved over time. If stake
///         lived inside the game contract, every redeployment would force every
///         moderator to withdraw and re-stake — a migration that costs real money,
///         loses the moderator set, and (worse) is the kind of hassle that quietly
///         kills participation. So stake lives here, permanently, and the *game*
///         is the replaceable part: governance repoints this registry at a new
///         logic contract and nobody re-stakes.
///
///         This registry knows only: who has stake, how it is partitioned
///         (free / pending / committed / frozen / exiting), and how much draw
///         weight each moderator carries. It has no notion of cases, votes,
///         appeals or outcomes — those belong to the logic contract.
///
/// ## Trust model (the part that matters)
///
/// The authorized logic contract is powerful: it can lock, freeze and credit
/// stake. Repointing the registry at a new logic contract therefore *is* the
/// protocol's trust root, and it is deliberately constrained:
///
/// 1. **Timelocked.** A repoint must be proposed and can only be executed after
///    `timelockDelay`, so moderators always see a migration coming.
/// 2. **Exit is never gated by logic.** `requestExit`/`withdraw` are callable by
///    the owner of the stake and never consult the logic contract. A moderator who
///    dislikes an announced migration can always leave during the timelock window.
///    There is no pause, and governance cannot add one. (Invariant §9.5.)
/// 3. **Handover window.** The outgoing logic stays authorized until its open
///    cases settle, so a migration cannot strand in-flight cases: both the old and
///    the new logic are authorized during the handover.
/// 4. **No governance access to funds.** Governance can name the logic contract
///    and nothing else; it can never move, freeze, or credit a single wei itself.
/// 5. **Credits must be funded.** `reward()` pulls its own tokens and verifies the
///    measured balance delta (M2.6-P0-4). An authorized logic cannot conjure a
///    withdrawable balance, so it cannot drain other stakers' principal through the
///    ordinary exit path.
///
/// ## What this registry does and does not guarantee (M2.6, be honest about it)
///
/// STAKE obligations ARE now scoped. `lock`, `release`, `freeze` and `settleDuty`
/// each take a `caseRef` and resolve a handle keyed
/// `keccak256(authEpoch, logic, moderator, caseRef)` (P0-5), so only the case that
/// created an obligation can discharge it — across logic contracts during a
/// handover, and across cases within one logic. `canRevoke(logic)` is a real
/// on-chain drain signal, and `SETTLE_ONLY` lets an outgoing logic finish its cases
/// without accepting new ones.
///
/// So the solvency statement is now: *principal cannot be minted (P0-4), and no
/// authorized logic can discharge an obligation it did not create (P0-5).* That is
/// materially stronger than the pre-M2.6 position, which was "correct only if every
/// authorized logic is correct and stays inside its own cases".
///
/// What is still true and must not be overstated:
///
/// - A logic contract can still mis-account WITHIN its own namespace. Scoping stops
///   it reaching another case's collateral; it does not make its own bookkeeping
///   correct.
/// - Governance still names the authorized logic, behind a timelock. That remains
///   the trust root.
/// - **`setTrack` is GONE (M2.6-K-5).** It took no `caseRef` and wrote an absolute
///   value, so a concurrently authorized logic could overwrite any moderator's
///   track — including moderators it had never drawn — by design of the handover
///   rather than in spite of it. `recordParticipation` replaces it: the caller must
///   hold an obligation created by a draw, may use it once, may credit no more than
///   the seats it drew, must pass a decay factor inside this contract's immutable
///   envelope, and must use the SAME factor for every moderator in one case-round.
///   The value itself stays global — `m.track` is untouched by the change, so
///   standing accumulates across logic versions and no migration resets it. That is
///   the point of the registry outliving the game, and it is why the authority is
///   scoped rather than the value.
///
///   **The accepted surface, and why it is a consequence rather than an oversight.**
///   Three things the registry still permits that the honest logic does not do:
///
///     (a) a track write for a holder that was drawn but never committed;
///     (b) a track write on a case that VOIDed;
///     (c) a track write at any point in or AFTER the case's lifecycle, for as long
///         as the logic remains authorized.
///
///   All three have ONE cause: tightening any of them requires knowing whether a
///   seat committed, whether a case voided, or what phase it is in — and every one
///   of those is game state this contract deliberately does not hold. That is the
///   same reason the update RULE could not move here wholesale: coherence is a
///   function of the final outcome, so `coherentUnits` is a claim this contract
///   bounds but cannot verify. Buying (a)-(c) back would mean importing the case
///   state machine into the permanent registry, which is the coupling this
///   architecture exists to avoid.
///
///   **(c) is a FORCED TRADE and is wider than it looks — read this before
///   re-tightening it.** An earlier shape had these checks read `dutyUnits`, which
///   `settleDuty` consumes, so settlement closed the write window as a side effect.
///   Reading `drawnUnits` is what removes the ordering dependency, and it removes
///   that closure with it: "closes at settlement" means "reads a field settlement
///   consumes", which IS the dependency. You cannot have both. The dependency was
///   the worse of the two — it is invisible until someone reorders two lines eight
///   apart in `Settlement` — so the trade is deliberate.
///
///   What it leaves behind is a population of standing, unfired writes. After a case
///   settles, an unfired `recordParticipation` remains available for: every no-show
///   holder (widening (a) — the honest logic never writes for them, since
///   `_touchTrack` sits behind `if (r.committed[a])`), every seat of a VOIDed case
///   (widening (b)), and every case the logic simply never recorded. For any
///   `caseRef` where no write ever happened, `caseTrackDecay[ck]` is unset — so the
///   uniformity check binds nothing and the factor is free at firing time, anywhere
///   in `[minTrackDecay, WAD)`.
///
///   **Revocation is the bound, and it is a real one.** `onlyLogic` refuses a logic
///   in state `NONE`, so revoking ends every unfired write it holds at once. But note
///   what `canRevoke` actually reads: `logicCommitted` and `logicDutyReserved`, both
///   of which drain at settlement and neither of which knows anything about
///   `trackRecorded`. So a logic that has settled everything is revocable **while
///   still holding unfired track writes** — governance can revoke it, and until
///   governance does, the window is open. Re-authorizing it later does not reopen the
///   old handles: `authEpoch` is bumped, which renames the whole namespace.
///
///   **What remains open, stated as a bound rather than a hope.** A logic can still
///   corrupt the standing of moderators it legitimately drew, within the envelope
///   and once per obligation. Obligations are per case-ROUND while the decay rule is
///   per CASE, so the registry cannot enforce once-per-case without parsing
///   `caseRef` — which would re-couple it to a replaceable logic's encoding. Decay
///   compounds: `N` writes multiply to `minTrackDecay^N`, `N` up to 81 at governance
///   caps. See `minTrackDecay` for why no admissible floor bounds that, and
///   `specs/m2_6-work-order.md` K-5 for the full accounting.
/// - `reward` is likewise per-moderator rather than per-obligation, but it is
///   funded-on-call and balance-checked (P0-4), so the worst an authorized logic
///   does is credit a reward out of its own money.
///
contract StakeRegistry {
    using SafeTransferLib for address;
    using SortitionTree for SortitionTree.Tree;

    // --- storage -------------------------------------------------------------

    struct Moderator {
        uint256 free; // withdrawable (includes pending + exit-reserved)
        uint256 pending; // not yet past activation delay -> not draw-eligible
        uint256 committed; // locked against open cases by the logic contract
        uint256 frozen; // penalty-locked
        uint256 frozenUntil;
        uint256 activatesAt;
        uint256 exitAmount;
        uint256 exitClaimableAt; // snapshotted at request (H-11)
        uint256 track; // coherent-participation record (WAD), maintained by logic
        // H-07 duty pool: pledged concurrent seat capacity and how much of it is
        // held by live panels. Only available capacity is draw-eligible, so
        // selection weight equals collateral that can actually be locked, and
        // stake that never opted in is never drawable.
        uint256 dutyUnits;
        uint256 dutyReserved;
        // M2.6-P0-2: collateral ESCROWED against outstanding draw assignments,
        // `riskPerSeat` per reserved seat. Before this bucket existed, `drawPanel`
        // incremented `dutyReserved` but moved no tokens: the seat's backing stayed
        // in `free`, and therefore stayed user-controlled. A selected moderator
        // escaped the no-show penalty entirely by calling `setDutyUnits(0)` or
        // `requestExit(free)` — the exit did not even have to complete, since the
        // then-current penalty function subtracted `exitAmount` from what it could
        // reach. The penalty is the stated defence against appeal-panel
        // obstruction (H-10) and it cost nothing.
        //
        // Bonded stake is not free, not exitable, not reducible by
        // `setDutyUnits`, and not available to another case. It leaves only by
        // being committed (a vote), frozen (a no-show penalty), or released (the
        // case ended) — and since M2.6-P0-5c every one of those moves goes through
        // an obligation handle, so this pooled figure is an ACCOUNTING total that
        // nothing writes without naming the case it belongs to.
        uint256 dutyBonded;
        bool exists;
    }

    IERC20 public immutable token;

    mapping(address => Moderator) internal moderators;
    SortitionTree.Tree internal stakeTree;

    uint256 public totalFreeStake;
    uint256 public totalCommittedStake;
    uint256 public totalFrozenStake;
    /// M2.6-P0-2: escrowed against outstanding draw assignments. A fourth bucket,
    /// so conservation still accounts for every token exactly once.
    uint256 public totalDutyBondedStake;

    // Parameters this registry needs on its own (it must not depend on the logic
    // contract for the exit path — see trust model #2).
    uint256 public minStake;
    uint256 public activationDelay;
    uint256 public exitCooldown;
    /// @notice What ONE DUTY UNIT is worth: the collateral a moderator pledges
    ///         per concurrent seat it offers to serve. This is a staking-layer
    ///         constant, and it is deliberately `immutable`.
    ///
    ///         The logic contract has its own `riskPerSeat` — what a case LOCKS
    ///         per seat — which is a consensus parameter and is pinned per case
    ///         (H-11). The two are different roles and must not be collapsed:
    ///         collapsing them would either break per-case pinning or make draw
    ///         eligibility retroactively mutable.
    ///
    ///         Only one direction of divergence is harmful: a case locking MORE
    ///         than the unit reserved for it, which would let a panel be seated
    ///         on collateral that cannot cover it. `Moderation._validateParams`
    ///         rejects any ruleset with `riskPerSeat > stakeReg.riskPerSeat()`,
    ///         so that state is unrepresentable. Immutability here is what makes
    ///         that check trustworthy — a mutable value could be lowered after a
    ///         ruleset was validated against it.
    uint256 public immutable riskPerSeat;

    uint256 internal constant WAD = 1e18;

    /// @notice M2.6-K-5. The floor on how much standing one track write may
    ///         destroy: `recordParticipation` accepts a decay factor only in
    ///         `[minTrackDecay, WAD)`. Same shape as `riskPerSeat` — the registry
    ///         owns the range, the ruleset picks a value inside it, and the
    ///         governor rejects any ruleset that does not.
    /// @dev **Read the residual before choosing this number.** Decay is
    ///      MULTIPLICATIVE and this bounds ONE write. A logic holds one obligation
    ///      per case-round, so a moderator drawn into every round of a case can be
    ///      decayed `N` times, and the compounded floor is `minTrackDecay^N`, not
    ///      `minTrackDecay`. `N` is 16 at the shipped ruleset and 81 at governance
    ///      caps. At `N = 81`: 0.99 retains 44%, 0.95 retains 1.6%, 0.9 retains
    ///      0.02%. Since a legitimate ruleset must be admitted and the shipped
    ///      decay is 0.95, no floor at or above 0.95 is available — so this
    ///      constant CANNOT bound the compounded case, and does not claim to. It
    ///      bounds the step. The count is bounded only by the logic's own
    ///      once-per-case rule, which this contract cannot enforce without parsing
    ///      `caseRef` — see the accepted surface in the header.
    uint256 public immutable minTrackDecay;

    // --- eligibility epochs (M2.6-P0-3) --------------------------------------
    //
    // H-05 was defended by `eligibilityAddVersion`, a counter the logic contract
    // compared before drawing and re-armed on. It failed in both directions:
    // `setDutyUnits(sameValue)` bumped it with no change, so any pledged
    // moderator could re-arm EVERY pending case forever for gas; while `release`,
    // `reward` and `releaseDuty` added draw-eligible weight and never bumped it
    // at all, leaving the grind it existed to stop wide open. Weight REMOVALS
    // (`setDutyUnits(0)`, `requestExit`, freezing) never bumped either, and those
    // remap the whole weighted tree — grinding over tree states, not
    // self-exclusion.
    //
    // Replaced by something structural. Draw-eligible weight now changes only at
    // EPOCH BOUNDARIES, on a fixed block cadence nobody can influence: a change
    // made during epoch `e` is staged and takes effect in `e + 1`. So the SAMPLING
    // TREE is constant across a draw window, there is no change to detect, and
    // nothing to re-arm on — which is why the counter is gone rather than fixed.
    //
    // **Be precise about what that does and does not give you.** The tree being
    // constant between epochs is not, on its own, the property. `drawPanel` must
    // read the live moderator struct to decide whether a drawn address may actually
    // be seated (P0-2), so the SEATABLE SET moves within an epoch — and while the
    // draw removed rejected addresses to save attempts, that live set fed a tree
    // write and steered the panel (H-03A/H-03B). The draw no longer writes the tree
    // at all (M2.6-P0-3d), which is what makes the boundary cadence sufficient
    // rather than merely necessary. State the mechanism, not the conclusion.
    uint256 public immutable epochBlocks;
    /// Epochs up to and including this one have had their staged changes applied.
    uint256 public appliedEpoch;
    /// Moderators whose weight changed during epoch `e`, applied at the start of
    /// `e + 1`. Keyed by epoch so changes staged mid-drain are not swept early.
    mapping(uint256 => address[]) internal stagedByEpoch;
    mapping(uint256 => mapping(address => bool)) internal isStaged;
    /// M2.6-P0-3d: attempts a draw may spend per seat sought. Sized by measurement,
    /// not by intuition — it is what pays for NOT removing an unseatable address
    /// from the tree, since one that is denied can be drawn again.
    ///
    /// 6 was chosen against the panel-fill bar (P99 fill >= 95%) over: ordinary
    /// load; honest churn at 10%; an adversarial absorber at 30% and 50%; a
    /// post-settlement frozen cohort of 47; and a scarce network whose capacity
    /// barely exceeds the target. It is FREE in every dense case — the panel fills
    /// long before the cap binds, so gas at 6 is identical to gas at 2 (worst
    /// measured 4.19M, 52% of the 8M ceiling). It is only ever spent under scarcity,
    /// which is exactly where the old budget of 2 failed.
    ///
    /// Documented breaking point: usable capacity ~= the seat target, where filling
    /// becomes coupon-collector-bound rather than budget-bound and no attempt budget
    /// helps. Re-derive with the panel-fill rows in `GasBounds.t.sol` if the loop
    /// changes.
    uint256 internal constant ATTEMPTS_PER_SEAT = 6;

    /// Position reached inside the epoch currently being drained. Public because it
    /// is the only way to see that a partial drain PERSISTED (M2.6-P0-3b) — the
    /// regression it guards against was invisible precisely because the discarded
    /// work left no trace.
    uint256 public drainCursor;
    /// The weight each moderator's leaf carries for the CURRENT epoch. Written
    /// only at drain time. (It no longer has a second job: since M2.6-P0-3d a draw
    /// excludes nothing, so there is nothing to restore.)
    mapping(address => uint256) internal epochWeight;

    /// M2.6-P0-3d (H-03A/H-03B): **the sortition tree is immutable for the whole
    /// of an epoch.** It is written in exactly two places — `initialize`, and
    /// `_drainEpochs` at a boundary. `drawPanel` reads it and never writes it.
    ///
    /// That single sentence is what closes the grind, and it is checkable by
    /// inspection rather than by argument. The draw's address mapping is
    /// `addr(i) = draw(keccak(seed, offset + i))`, which depends on the seed, the
    /// attempt index and the tree. All three are fixed before the seed becomes
    /// public: `_armSeed` keeps a seed's window inside one epoch and `realizeSeats`
    /// re-arms if the epoch turns over; the cursor accumulates ATTEMPTS, so batches
    /// are contiguous segments of one walk; and the tree cannot move. Live
    /// seatability inputs therefore feed only accept/deny, which changes how far the
    /// walk runs and never what the walk is.
    ///
    /// What this replaces. P0-3 froze the tree between epochs and concluded that
    /// eligibility was "constant by construction, so there is nothing to grind". The
    /// tree was constant; the SEATABLE SET was not. `drawPanel` removed a rejected
    /// address with `stakeTree.set(seat, 0)` to save attempts, and that remapped
    /// every later interval — so a post-seed `setDutyUnits(0)` or `requestExit(free)`
    /// from an unseated holder steered the panel (H-03A), and so did anything that
    /// RAISED seatability between batches: `setDutyUnits` up, `activate`, `thaw`,
    /// `claim` on another case (H-03B). P0-3c suppressed the first family by tracking
    /// voluntary reductions; that closed two levers, not the property.
    ///
    /// Both families close here for one reason instead of a list, and the freeze
    /// lever — which P0-3c had to carve out as an accepted residual — closes with
    /// them. `voluntaryCutEpoch` is deleted: with no write to suppress, it had
    /// nothing left to do.

    // --- obligation handles (M2.6-P0-5) --------------------------------------
    //
    // `lock`, `release`, `freeze` and `settleDuty` carried no obligation identity
    // — only per-moderator aggregates. Two distinct failures followed.
    //
    // ACROSS LOGICS: during a handover both are authorized, so logic B could
    // release stake logic A had committed, freeze A's committed stake under B's
    // case, or discharge A's duty reservations. A's later honest settlement then
    // underflowed and reverted, stranding the case. Malice was never needed; an
    // ordinary bug in either contract did it.
    //
    // ACROSS CASES, within ONE logic: `dutyBonded` was a single pool per
    // moderator, so a case settling one seat could hand back escrow belonging to
    // a different case's outstanding seat, silently un-bonding it — that case's
    // no-show penalty then became a no-op. Nothing was minted, so conservation
    // still held and the leak was invisible. It was written once in P0-2 and
    // caught by reading, not by a test.
    //
    // Keying every obligation by (authorization epoch, logic, moderator, case)
    // makes both unrepresentable rather than merely absent from today's call
    // sites. The per-moderator aggregates remain as the ACCOUNTING layer —
    // conservation and draw weight are computed from them — while these handles
    // are the AUTHORIZATION layer.
    /// Packed into ONE storage slot deliberately. `drawPanel` touches an
    /// obligation for every seated moderator, so the difference between one cold
    /// SSTORE and three is ~40,000 gas per seat on the most expensive transaction
    /// in the protocol — it moves `MAX_PANEL` directly.
    ///
    /// Ranges: xBZZ has 16 decimals and a supply around 6.25e23 base units, so
    /// `uint104` (~2.0e31, 32 million times the supply) cannot be reached by any
    /// real amount; seats for one moderator in one case-round are bounded by
    /// `(1 + MAX_RULE_WIDEN) * MAX_PANEL = 1152` and by `MAX_TOTAL_DRAWS = 4000`
    /// across the whole case, far inside `uint16`.
    ///
    /// **M2.6-K-5 re-packed this struct rather than growing it.** The layout is
    /// 104 + 104 + 16 + 16 + 8 = **248 bits**, still one slot with 8 to spare. The
    /// obvious layout — keeping `uint112` twice and adding the two new fields —
    /// comes to 264 and spills into a second slot, because Solidity stores a
    /// `bool` in a whole BYTE, not a bit. That would put a second cold SSTORE on
    /// `drawPanel`'s per-seat path, ~40,000 gas per seat on the most expensive
    /// transaction in the protocol, which moves `MAX_PANEL` directly. The money
    /// fields lost 8 bits each to pay for it and are still absurdly oversized.
    struct Obligation {
        uint104 committed; // stake locked against this specific case
        uint104 dutyBonded; // escrow posted for its seats
        uint16 dutyUnits; // seats OUTSTANDING for it — consumed by settleDuty
        /// Seats this obligation was ever DRAWN for. Set at the draw and **never
        /// decremented**. M2.6-K-5: this is what `recordParticipation` reads, for
        /// both its existence test and its magnitude bound, so neither check
        /// depends on running before `settleDuty` consumes `dutyUnits`. A nonzero
        /// value is itself the "created by a draw" proof — no separate flag.
        uint16 drawnUnits;
        /// M2.6-K-5: one track write per obligation, ever.
        bool trackRecorded;
    }

    mapping(bytes32 => Obligation) internal obligations;
    /// M2.6-K-5: the decay factor bound to a case-round on its first track write,
    /// keyed `keccak256(authEpoch, logic, caseRef)` — deliberately WITHOUT the
    /// moderator, since making it uniform across moderators is the whole point.
    mapping(bytes32 => uint256) internal caseTrackDecay;
    /// Bumped each time a logic is authorized, so a contract re-authorized after
    /// revocation cannot inherit handles from its previous life.
    mapping(address => uint256) public authEpoch;
    /// Per-logic totals: a real on-chain drain signal. `openPotsTotal` in the game
    /// contract is not one — it is decremented at settlement INIT.
    mapping(address => uint256) public logicCommitted;
    mapping(address => uint256) public logicDutyReserved;

    // --- authorization -------------------------------------------------------

    address public governance;
    uint256 public immutable timelockDelay;

    /// Authorized logic contracts. More than one may be authorized at a time so a
    /// migration can hand over while the outgoing logic settles its open cases.

    /// M2.6-P0-5: a logic contract's authorization has three states, not two.
    ///
    /// With only on/off, revoking a live logic STRANDED its cases — its pot, its
    /// committed stake, its duty reservations and its unpaid appeal contributors
    /// all sat in a contract that could no longer touch the registries, and the
    /// replacement could not settle them because the case storage lives in the old
    /// contract. Governance's only alternative was to leave the old logic fully
    /// authorized, which let anyone keep opening NEW cases in it, so it never
    /// provably drained. `SETTLE_ONLY` is the missing middle: finish what you
    /// started, start nothing new.
    enum LogicState {
        NONE,
        OPEN_AND_SETTLE,
        SETTLE_ONLY
    }

    mapping(address => LogicState) public logicState;

    struct PendingLogic {
        address logic;
        uint256 eta;
        bool exists;
    }

    PendingLogic public pendingLogic;

    // --- events --------------------------------------------------------------

    event Staked(address indexed moderator, uint256 amount, uint256 activatesAt);
    event Activated(address indexed moderator, uint256 eligibleWeight);
    event ExitRequested(address indexed moderator, uint256 amount, uint256 claimableAt);
    event Withdrawn(address indexed moderator, uint256 amount);
    event Thawed(address indexed moderator, uint256 amount);
    event StakeLocked(address indexed moderator, uint256 amount);
    event StakeReleased(address indexed moderator, uint256 amount);
    event StakeFrozen(address indexed moderator, uint256 amount, uint256 until);
    event Rewarded(address indexed moderator, uint256 amount);
    /// M2.6-K-5: replaces `TrackSet`. Carries the whole basis of the write — who
    /// claimed it, under which obligation, the credit claimed and the factor
    /// applied — because `coherentUnits` is a claim this contract bounds but
    /// cannot verify, and an unverifiable input should at least be observable.
    event ParticipationRecorded(
        address indexed moderator,
        address indexed logic,
        uint256 caseRef,
        uint256 coherentUnits,
        uint256 decayFactor,
        uint256 newTrack
    );
    event DutyUnitsSet(address indexed moderator, uint256 units, uint256 reserved);
    event NoShowPenalized(address indexed moderator, uint256 penalty, uint256 until);

    event LogicProposed(address indexed logic, uint256 eta);
    event LogicAuthorized(address indexed logic);
    event LogicRetiring(address indexed logic);
    event LogicRevoked(address indexed logic);
    event GovernanceTransferProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    // --- errors --------------------------------------------------------------

    error NotGovernance();
    error NotLogic();
    error AmountZero();
    error BelowMinStake();
    error InsufficientFree();
    error InsufficientEligibleFree();
    error MinStakeFloor();
    error ExitPending();
    error NoExitPending();
    error CooldownNotElapsed();
    error NotFrozen();
    error NoModerator();
    error NothingPending();
    error NotYetActivatable();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error ZeroAddress();
    error RewardNotFunded(); // reward() must be funded by the caller in the same call
    error DutyReserved(); // M2.6-P0-2: cannot un-pledge capacity a live panel holds
    error EpochNotSettled(); // M2.6-P0-3: call advanceEpoch() to apply staged changes
    error NotYourObligation(); // M2.6-P0-5: only the creating case may discharge it
    error LogicStillHasObligations(); // M2.6-P0-5: cannot revoke a logic mid-flight
    error TrackAlreadyRecorded(); // M2.6-K-5: one track write per obligation
    error TrackCreditExceedsSeats(); // M2.6-K-5: credit above seats actually drawn
    error BadTrackDecay(); // M2.6-K-5: decay outside the immutable envelope
    error TrackDecayNotUniform(); // M2.6-K-5: one decay factor per case-round

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLogic() {
        if (logicState[msg.sender] == LogicState.NONE) revert NotLogic();
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _timelockDelay,
        uint256 _minStake,
        uint256 _activationDelay,
        uint256 _exitCooldown,
        uint256 _riskPerSeat,
        uint256 _epochBlocks,
        uint256 _minTrackDecay
    ) {
        if (_epochBlocks == 0) revert AmountZero();
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_riskPerSeat == 0) revert AmountZero();
        // M2.6-K-5: the envelope must admit a usable decay and must not be WAD
        // (which is no decay at all — see M2.6-P1-3).
        if (_minTrackDecay == 0 || _minTrackDecay >= WAD) revert BadTrackDecay();
        token = _token;
        timelockDelay = _timelockDelay;
        minStake = _minStake;
        activationDelay = _activationDelay;
        exitCooldown = _exitCooldown;
        epochBlocks = _epochBlocks;
        appliedEpoch = block.number / _epochBlocks;
        riskPerSeat = _riskPerSeat;
        minTrackDecay = _minTrackDecay;
        governance = msg.sender;
        stakeTree.initialize(2);
    }

    // =========================================================================
    // Moderator-facing: never gated by the logic contract (trust model #2)
    // =========================================================================

    function stake(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        // Floor binds on CURRENT total, so stake -> full exit -> dust re-stake
        // cannot enter the tree below the minimum (H-07).
        if (_total(m) == 0 && amount < minStake) revert BelowMinStake();
        m.exists = true;

        address(token).safeTransferFrom(msg.sender, address(this), amount);
        m.free += amount;
        m.pending += amount;
        m.activatesAt = block.timestamp + activationDelay;
        totalFreeStake += amount;

        emit Staked(msg.sender, amount, m.activatesAt);
    }

    /// Permissionless poke: activation only ever helps its target.
    function activate(address moderator) external {
        Moderator storage m = moderators[moderator];
        if (!m.exists) revert NoModerator();
        if (m.pending == 0) revert NothingPending();
        if (block.timestamp < m.activatesAt) revert NotYetActivatable();
        m.pending = 0;
        _syncTree(moderator, m);
        emit Activated(moderator, _eligibleWeight(m));
    }

    function requestExit(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[msg.sender];
        if (m.exitAmount != 0) revert ExitPending();
        if (amount > m.free) revert InsufficientFree();
        uint256 remaining = _total(m) - amount;
        if (remaining != 0 && remaining < minStake) revert MinStakeFloor();

        m.exitAmount = amount;
        // Terms are settled now: a later parameter change can neither extend the
        // wait nor invalidate an already-valid exit (H-11).
        m.exitClaimableAt = block.timestamp + exitCooldown;
        _syncTree(msg.sender, m);
        emit ExitRequested(msg.sender, amount, m.exitClaimableAt);
    }

    /// @notice Claim a requested exit. Deliberately independent of the logic
    ///         contract and of governance: no admin gate exists on this path, and
    ///         none can be added, so a moderator can always leave — including
    ///         during the timelock of a migration it does not consent to.
    function withdraw() external {
        Moderator storage m = moderators[msg.sender];
        uint256 amount = m.exitAmount;
        if (amount == 0) revert NoExitPending();
        if (block.timestamp < m.exitClaimableAt) revert CooldownNotElapsed();

        m.free -= amount;
        totalFreeStake -= amount;
        if (m.pending > m.free) m.pending = m.free;
        m.exitAmount = 0;
        m.exitClaimableAt = 0;
        _syncTree(msg.sender, m);

        address(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Pledge concurrent seat capacity (H-07). Each unit is backed by
    ///         `riskPerSeat` of your own stake, and only pledged, unreserved
    ///         capacity is draw-eligible. Duty is opt-in precisely so that failing
    ///         to serve can be penalized without conscripting passive stakers.
    function setDutyUnits(uint256 units) external {
        Moderator storage m = moderators[msg.sender];
        if (!m.exists) revert NoModerator();
        // M2.6-P0-2 (bypass 1): capacity already held by live panels cannot be
        // un-pledged. `setDutyUnits(0)` after selection used to make the
        // then-current penalty function return immediately on its
        // `dutyUnits == 0` guard, so a drawn moderator walked away from an
        // assignment for free. `settleDuty` needs no such guard — it can only
        // reach escrow the draw actually posted for a named case.
        if (units < m.dutyReserved) revert DutyReserved();
        if (units > 0) {
            uint256 reserved = m.pending + m.exitAmount;
            uint256 usable = m.free > reserved ? m.free - reserved : 0;
            if (usable < units * riskPerSeat) revert InsufficientEligibleFree();
        }
        m.dutyUnits = units;
        _syncTree(msg.sender, m);
        emit DutyUnitsSet(msg.sender, units, m.dutyReserved);
    }

    /// Permissionless poke: releases an already-expired freeze.
    function thaw(address moderator) external {
        Moderator storage m = moderators[moderator];
        if (m.frozen == 0) revert NotFrozen();
        if (block.timestamp < m.frozenUntil) revert NotFrozen();
        uint256 amount = m.frozen;
        m.frozen = 0;
        totalFrozenStake -= amount;
        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit Thawed(moderator, amount);
    }

    // =========================================================================
    // Logic-facing: the narrow privileged API
    // =========================================================================

    /// @notice The obligation key for `moderator` under the CALLING logic's case.
    /// @param caseRef The caller's own case identity. `Moderation` packs
    ///        `(caseId << 8) | depth`; the registry treats it opaquely and only
    ///        needs it to be unique per case-round within one logic.
    /// @dev Includes `authEpoch[msg.sender]`, so a logic re-authorized after
    ///      revocation starts a fresh namespace and cannot reach obligations from
    ///      its previous life.
    function obligationKey(address logic, address moderator, uint256 caseRef) public view returns (bytes32) {
        return keccak256(abi.encode(authEpoch[logic], logic, moderator, caseRef));
    }

    function _ob(address moderator, uint256 caseRef) internal view returns (Obligation storage) {
        return obligations[keccak256(abi.encode(authEpoch[msg.sender], msg.sender, moderator, caseRef))];
    }

    /// Read an obligation (permissionless).
    function obligationOf(address logic, address moderator, uint256 caseRef)
        external
        view
        returns (uint256 committed, uint256 dutyUnits, uint256 dutyBonded)
    {
        Obligation storage o = obligations[obligationKey(logic, moderator, caseRef)];
        return (o.committed, o.dutyUnits, o.dutyBonded);
    }

    /// Move `amount` -> committed (backing a vote in an open case).
    /// @dev M2.6-P0-2: drawn from `dutyBonded` first — that escrow exists for
    ///      exactly this, and a case locking `riskPerSeat` per seat can never need
    ///      more than was bonded for those seats (`Moderation._validateParams`
    ///      rejects a ruleset whose `riskPerSeat` exceeds this registry's unit).
    ///      Any remainder comes from free stake, which keeps the injector paths and
    ///      any future non-duty lock working.
    function lock(address moderator, uint256 caseRef, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        Obligation storage o = _ob(moderator, caseRef);
        // M2.6-P0-5: spend THIS case's escrow. Drawing from the moderator's pooled
        // `dutyBonded` would let one case's commit consume collateral posted for
        // another case's outstanding seat.
        uint256 fromBond = amount > o.dutyBonded ? o.dutyBonded : amount;
        uint256 fromFree = amount - fromBond;
        if (fromFree > 0) {
            uint256 reserved = m.pending + m.exitAmount;
            uint256 eligible = m.free > reserved ? m.free - reserved : 0;
            if (eligible < fromFree) revert InsufficientEligibleFree();
            m.free -= fromFree;
            totalFreeStake -= fromFree;
        }
        if (fromBond > 0) {
            o.dutyBonded -= uint104(fromBond);
            m.dutyBonded -= fromBond;
            totalDutyBondedStake -= fromBond;
        }
        o.committed += uint104(amount);
        logicCommitted[msg.sender] += amount;
        m.committed += amount;
        totalCommittedStake += amount;
        _syncTree(moderator, m);
        emit StakeLocked(moderator, amount);
    }

    /// Move `amount` committed -> free (case settled coherently).
    function release(address moderator, uint256 caseRef, uint256 amount) external onlyLogic {
        Moderator storage m = moderators[moderator];
        _debit(_ob(moderator, caseRef), amount);
        m.committed -= amount;
        m.free += amount;
        totalCommittedStake -= amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit StakeReleased(moderator, amount);
    }

    /// Move `amount` committed -> frozen until `until` (penalty; never a transfer).
    function freeze(address moderator, uint256 caseRef, uint256 amount, uint256 until) external onlyLogic {
        Moderator storage m = moderators[moderator];
        _debit(_ob(moderator, caseRef), amount);
        m.committed -= amount;
        m.frozen += amount;
        totalCommittedStake -= amount;
        totalFrozenStake += amount;
        if (until > m.frozenUntil) m.frozenUntil = until;
        _syncTree(moderator, m);
        emit StakeFrozen(moderator, amount, m.frozenUntil);
    }

    /// Credit a reward to free balance. The logic contract must have transferred
    /// the corresponding tokens to this registry (rewards are external money —
    /// fees and forfeited bonds — never another moderator's principal).
    /// @notice Credit a reward, pulling its funding from the caller in the same
    ///         call. The logic contract must have approved this registry.
    ///
    ///         The funding is ENFORCED here, not assumed. Previously this function
    ///         only incremented balances and the requirement to transfer first lived
    ///         in a comment — so any authorized logic (buggy, superseded, or
    ///         malicious) could mint withdrawable claims from nothing and drain real
    ///         stakers via requestExit/withdraw. A safety property written in prose
    ///         is not a safety property.
    ///
    ///         The measured balance delta also catches a caller funding with the
    ///         wrong token, which would otherwise leave the registry insolvent in
    ///         the asset it actually owes.
    function reward(address moderator, uint256 amount) external onlyLogic {
        if (amount == 0) revert AmountZero();
        Moderator storage m = moderators[moderator];

        uint256 before = token.balanceOf(address(this));
        address(token).safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert RewardNotFunded();

        m.free += amount;
        totalFreeStake += amount;
        _syncTree(moderator, m);
        emit Rewarded(moderator, amount);
    }

    /// @notice Apply one case's track transition to a moderator, scoped to the
    ///         obligation the caller drew it under (M2.6-K-5).
    /// @dev **This replaces `setTrack(address,uint256)`, which is DELETED.** That
    ///      function took no `caseRef` and wrote an absolute value, so `onlyLogic`
    ///      was its only gate — and `onlyLogic` blocks a revoked logic, nothing
    ///      more. Trust model #3 keeps both logics authorized through a handover by
    ///      design, so a concurrently authorized logic could overwrite ANY
    ///      moderator's track, including moderators it had never drawn.
    ///
    ///      What a logic may legitimately do to standing is: report the outcome of
    ///      an obligation IT created, about the moderator that obligation belongs
    ///      to, in a magnitude bounded by the work that obligation represents.
    ///      Every check below is one clause of that sentence.
    ///
    ///      **The registry computes the transition; it does not accept a value.**
    ///      An absolute-value setter cannot be bounded without reconstructing the
    ///      rule anyway, and it makes a lost update REPRESENTABLE: a logic may read
    ///      `trackOf` in one transaction and write a value derived from it in
    ///      another, silently discarding whatever a concurrently authorized logic
    ///      wrote in between. Today's `Moderation` reads and writes inside one
    ///      call, so it does not do this — but "no current caller does it" is the
    ///      argument that failed for `penalizeNoShow`. Here the read-modify-write
    ///      happens inside the registry, so no caller can express it.
    ///
    ///      **What the registry cannot check, and why that is a consequence rather
    ///      than an oversight:** coherence is a function of the case's final
    ///      outcome, which is game state this contract deliberately does not hold.
    ///      So `coherentUnits` is a CLAIM, bounded but not verified. Every widening
    ///      in the accepted surface (see the header) has that same single cause.
    /// @param caseRef The caller's own case identity, treated opaquely.
    /// @param coherentUnits Units of standing earned, bounded by seats drawn.
    /// @param decayFactor The ruleset's per-case decay, WAD-scaled. Bound to the
    ///        `caseRef` on first use: every moderator in one case-round decays by
    ///        the same factor or the call reverts.
    function recordParticipation(address moderator, uint256 caseRef, uint256 coherentUnits, uint256 decayFactor)
        external
        onlyLogic
    {
        Obligation storage o = _ob(moderator, caseRef);
        // (1) Created by a draw. `drawnUnits` is never decremented, so this holds
        //     wherever in settlement the caller chooses to run.
        if (o.drawnUnits == 0) revert NotYourObligation();
        // (2) Once per obligation, ever.
        if (o.trackRecorded) revert TrackAlreadyRecorded();
        // (3) Bounded by work actually done under this obligation.
        if (coherentUnits > o.drawnUnits) revert TrackCreditExceedsSeats();
        // (4) Inside the immutable envelope. The ruleset picks the value; this
        //     contract owns the range, exactly as it owns `riskPerSeat` while the
        //     ruleset picks what a case locks.
        if (decayFactor < minTrackDecay || decayFactor >= WAD) revert BadTrackDecay();
        // (5) One factor per case-round, across every moderator in it. Without
        //     this the factor is chosen per call, at settlement, with the outcome
        //     already known — so a logic could hand the ruleset's decay to the
        //     moderators it likes and the floor to the ones it does not, and all
        //     four checks above would pass. No legitimate ruleset can express a
        //     decay that varies between moderators inside one case: `trackDecay` is
        //     per case and H-11 pins it. Binding it here makes per-target selection
        //     unrepresentable while leaving a replacement logic free to pick its
        //     own decay. Zero is not a legal factor (check 4), so zero means unset
        //     and no existence flag is needed.
        bytes32 ck = keccak256(abi.encode(authEpoch[msg.sender], msg.sender, caseRef));
        uint256 bound = caseTrackDecay[ck];
        if (bound == 0) caseTrackDecay[ck] = decayFactor;
        else if (bound != decayFactor) revert TrackDecayNotUniform();

        o.trackRecorded = true;
        Moderator storage m = moderators[moderator];
        uint256 next = (m.track * decayFactor) / WAD + coherentUnits * WAD;
        m.track = next;
        emit ParticipationRecorded(moderator, msg.sender, caseRef, coherentUnits, decayFactor, next);
    }

    /// Stake-weighted draw over the currently eligible set (read-only preview).
    function draw(uint256 rand) external view returns (address) {
        return stakeTree.draw(rand);
    }

    /// @notice Draw a panel of `count` seats, RESERVING one duty unit per seat
    ///         (H-07).
    ///
    ///         Sampling is stake-weighted WITH REPLACEMENT over the epoch-start
    ///         tree, under a live rejection filter: an address that cannot escrow a
    ///         seat right now is SKIPPED and its attempt is spent. It is not removed
    ///         from the tree, so it may be drawn again — that is what the attempt
    ///         budget (`ATTEMPTS_PER_SEAT × count`) pays for, and it is what makes
    ///         the address mapping independent of anything an actor can change after
    ///         the seed is public (M2.6-P0-3d).
    ///
    ///         Seats therefore land only where collateral exists, and a panel can
    ///         come back SHORT — of the target, and of `count` — when capacity is
    ///         scarce. Short panels are a liveness path, not an error (D-14).
    /// @return seats The drawn addresses, one entry per seat (duplicates possible).
    /// @return attempts Draws performed, including rejected ones. The caller MUST
    ///         advance its cursor by this and not by `seats.length`: batches are
    ///         contiguous segments of one fixed walk, and a seat-based cursor would
    ///         make a later batch's addresses depend on this one's acceptances.
    function drawPanel(uint256 count, bytes32 seed, uint256 offset, uint256 caseRef)
        external
        onlyLogic
        returns (address[] memory seats, uint256 attempts)
    {
        // The eligible set for this epoch must be complete before we sample it.
        //
        // M2.6-P0-3b: a PRECONDITION, never a drain-then-check. This used to run
        // `_drainEpochs(DRAIN_BUDGET)` first and revert if that was not enough —
        // and the revert unwound the drain it had just done. Every draw redid the
        // same first 64 items and threw them away again, so any epoch staging more
        // than the budget halted every draw in the protocol until somebody made a
        // separate `advanceEpoch` call, whose progress survives because it does not
        // revert. Ordinary traffic reaches that: `_stageSeated` deliberately skips
        // the dedupe flag, so one 48-seat panel plus normal staking activity passes
        // 64 entries inside a single 256-block epoch with no attacker involved.
        //
        // Raising the budget would only move the cliff. Doing no rollback-able work
        // here removes it: the caller drains through `advanceEpoch`, which commits.
        if (!epochSettled()) revert EpochNotSettled();

        // No drawable capacity anywhere. A PRECONDITION since M2.6-P0-3d rather than
        // the per-attempt check it used to be: nothing writes the tree during a
        // draw, so it cannot empty part-way through.
        if (stakeTree.total() == 0) return (new address[](0), 0);

        seats = new address[](count);
        uint256 drawn;
        uint256 maxAttempts = ATTEMPTS_PER_SEAT * count;
        while (drawn < count && attempts < maxAttempts) {
            // M2.6-P0-3d: THE INVARIANT. Nothing in this loop writes `stakeTree`,
            // so `addr(i) = draw(keccak(seed, offset + i))` is a pure function of
            // the seed, the attempt index, and the epoch-start tree — all fixed
            // before the seed became public. Everything below may only ACCEPT or
            // DENY the address this hands back. A decision cannot move a mapping it
            // does not write.
            address seat = stakeTree.draw(uint256(keccak256(abi.encode(seed, offset + attempts))));
            attempts++;
            Moderator storage m = moderators[seat];
            // M2.6-P0-2 (bypass 4): a seat is only issued if its collateral can be
            // ESCROWED right now. This read is deliberately LIVE, and that is safe
            // precisely because it only denies — see the invariant above.
            uint256 reserved = m.pending + m.exitAmount;
            uint256 usable = m.free > reserved ? m.free - reserved : 0;
            if (block.timestamp < m.frozenUntil || m.dutyUnits <= m.dutyReserved || usable < riskPerSeat) {
                continue; // denied; the attempt is spent, the tree is untouched
            }
            m.dutyReserved += 1;
            m.free -= riskPerSeat;
            m.dutyBonded += riskPerSeat;
            totalFreeStake -= riskPerSeat;
            totalDutyBondedStake += riskPerSeat;
            // M2.6-P0-5: the seat and its escrow belong to THIS case.
            Obligation storage ob = _ob(seat, caseRef);
            ob.dutyUnits += 1;
            // M2.6-K-5: the permanent record that this obligation came from a draw.
            // `dutyUnits` is the OUTSTANDING count and `settleDuty` consumes it;
            // this one is never decremented, so `recordParticipation` can test
            // existence and bound magnitude without depending on running first.
            ob.drawnUnits += 1;
            ob.dutyBonded += uint104(riskPerSeat);
            logicDutyReserved[msg.sender] += 1;
            seats[drawn++] = seat;
            // The persistent weight shrink is STAGED for the next epoch. Applying
            // it now would be a tree write, which is the thing this must not do.
            _stageSeated(seat);
        }
        if (drawn < count) {
            // Shrink to what was actually seated.
            assembly {
                mstore(seats, drawn)
            }
        }
    }

    /// @dev Discharge committed stake from THIS case's obligation. Reverts rather
    ///      than reaching into another case's or another logic's — the failure this
    ///      replaces succeeded here and underflowed in the rightful owner's
    ///      settlement later, where the cause was no longer visible.
    function _debit(Obligation storage o, uint256 amount) internal {
        if (o.committed < amount) revert NotYourObligation();
        o.committed -= uint104(amount);
        logicCommitted[msg.sender] -= amount;
    }

    /// @notice True when `logic` holds no live obligation, so revoking it cannot
    ///         strand a case.
    /// @dev The on-chain drain signal revocation previously lacked. Governance had
    ///      to BELIEVE the outgoing logic had finished; `openPotsTotal` in the game
    ///      contract could not tell it, because that is decremented at settlement
    ///      INIT rather than completion.
    function canRevoke(address logic) public view returns (bool) {
        return logicCommitted[logic] == 0 && logicDutyReserved[logic] == 0;
    }

    /// @notice Settle `units` finished assignments in ONE step: freeze `penalty` of
    ///         the escrow those seats still hold as the no-show cost, and return
    ///         the remainder to free stake.
    /// @dev THE only way duty escrow is discharged. This exists because penalising
    ///      and releasing must share a single clamp against the same balance. The
    ///      two separate calls it replaced (`penalizeNoShow` then `releaseDuty`)
    ///      read `dutyBonded` twice, and `dutyBonded` is a pool shared by every
    ///      case a moderator is currently seated in — so a seat whose bond had
    ///      already been partly frozen would still release a full `riskPerSeat`,
    ///      draining escrow belonging to a DIFFERENT case's outstanding seat and
    ///      silently un-bonding it. Nothing is minted (the conservation identity
    ///      still holds), which is exactly why the leak is invisible without this
    ///      being one operation.
    ///
    ///      Both are now gone: `releaseDuty` folded into this, and `penalizeNoShow`
    ///      deleted in M2.6-P0-5c. It had lost its caller but kept a live selector
    ///      writing the pooled `dutyBonded` with no `caseRef`, so the cross-case
    ///      drain this function exists to prevent stayed reachable by any
    ///      authorized logic through it.
    ///
    ///      Bounding both parts by `seatBond` makes over-draw unrepresentable.
    ///      Per-obligation accounting (P0-5) replaces the pooling entirely.
    function settleDuty(address moderator, uint256 caseRef, uint256 units, uint256 penalty, uint256 until)
        external
        onlyLogic
    {
        Moderator storage m = moderators[moderator];
        Obligation storage o = _ob(moderator, caseRef);
        // M2.6-P0-5: bounded by what THIS case reserved and escrowed. Bounding by
        // the moderator's pooled totals is what let a settlement hand back escrow
        // belonging to another case's outstanding seat.
        uint256 rel = units > o.dutyUnits ? o.dutyUnits : units;
        o.dutyUnits -= uint16(rel);
        logicDutyReserved[msg.sender] -= rel;
        m.dutyReserved -= rel;

        uint256 seatBond = rel * riskPerSeat;
        if (seatBond > o.dutyBonded) seatBond = o.dutyBonded;
        if (seatBond == 0) {
            _syncTree(moderator, m);
            return;
        }
        o.dutyBonded -= uint104(seatBond);
        m.dutyBonded -= seatBond;
        totalDutyBondedStake -= seatBond;

        uint256 p = penalty > seatBond ? seatBond : penalty;
        if (p > 0) {
            m.frozen += p;
            totalFrozenStake += p;
            if (until > m.frozenUntil) m.frozenUntil = until;
            emit NoShowPenalized(moderator, p, m.frozenUntil);
        }
        uint256 back = seatBond - p;
        if (back > 0) {
            m.free += back;
            totalFreeStake += back;
        }
        _syncTree(moderator, m);
    }

    // M2.6-P0-5c: `penalizeNoShow` was DELETED here.
    //
    // It was the H-07/H-10 no-show penalty before `settleDuty` replaced it, and by
    // M2.6 it had no caller — `Moderation._settleDuty` routes every disposal
    // through `settleDuty`, which is atomic (penalise and release share one clamp
    // against one balance) and obligation-scoped.
    //
    // What made removal a P0 rather than cleanup is that it wrote the POOLED
    // `m.dutyBonded` with no `caseRef`:
    //
    //     uint256 penalty = amount > m.dutyBonded ? m.dutyBonded : amount;
    //     m.dutyBonded -= penalty;
    //
    // `dutyBonded` pools a moderator's escrow across every case it is currently
    // seated in, so any authorized logic could freeze collateral posted for a
    // DIFFERENT case's outstanding seat — the exact class P0-5a made
    // unrepresentable everywhere else, still reachable through one live selector.
    // "No production caller" is not a defence: it is precisely the argument that
    // failed for `settleDuty`'s own double-release, which is why obligations are
    // keyed per case rather than per logic.
    //
    // Deleted rather than given a `caseRef`, because a scoped version would be
    // dead code with a live selector — the same hazard in a shape that reads as
    // safe. `NoShowPenalized` survives: `settleDuty` emits it, so the event
    // signature clients index is unchanged.

    // =========================================================================
    // Governance: may name the logic contract, and nothing else
    // =========================================================================

    function proposeLogic(address logic) external onlyGovernance {
        if (logic == address(0)) revert ZeroAddress();
        pendingLogic = PendingLogic({logic: logic, eta: block.timestamp + timelockDelay, exists: true});
        emit LogicProposed(logic, block.timestamp + timelockDelay);
    }

    /// @notice Authorize the proposed logic contract after the timelock. The
    ///         previously authorized logic is NOT revoked here: both stay
    ///         authorized so in-flight cases can settle under the old rules
    ///         (handover window, trust model #3). Governance revokes the old one
    ///         explicitly once it has drained.
    /// @dev M2.6-P0-5d: re-authorizing a logic that is ALREADY authorized and has
    ///      not drained is refused.
    ///
    ///      `authEpoch` is part of every obligation handle (`_ob`), so bumping it
    ///      renames the whole namespace. Done to a logic with live obligations, every
    ///      existing handle is orphaned in one transaction: `_debit` then reverts
    ///      `NotYourObligation` on the rightful owner's own settlement, forever, so
    ///      committed stake is stranded, escrow cannot be released, and
    ///      `logicCommitted`/`logicDutyReserved` never reach zero — `canRevoke` stays
    ///      false permanently and the contract can never even be retired out.
    ///      Nothing is minted and conservation still holds, which is why it would be
    ///      invisible.
    ///
    ///      Governance must not be able to reach an unfinalizable state — the same
    ///      standard `MAX_PANEL` and the freeze bounds are held to. A FIRST
    ///      authorization (from `NONE`) is unaffected, which is the only case where
    ///      the bump has a job to do: revocation requires `canRevoke`, so a logic at
    ///      `NONE` has no live handles and the fresh namespace exists to stop a
    ///      re-authorized contract inheriting the dead ones from its previous life.
    ///
    ///      Consequence worth naming: a SETTLE_ONLY logic cannot be un-retired while
    ///      it still holds obligations. That is deliberate — the alternative is a
    ///      governance action whose effect silently depends on drain state, which is
    ///      strictly worse than one that fails loudly. Authorize a fresh deployment,
    ///      or wait for the drain.
    function executeLogic() external onlyGovernance {
        PendingLogic memory pl = pendingLogic;
        if (!pl.exists) revert NoPendingProposal();
        if (block.timestamp < pl.eta) revert TimelockNotElapsed();
        if (logicState[pl.logic] != LogicState.NONE && !canRevoke(pl.logic)) {
            revert LogicStillHasObligations();
        }
        logicState[pl.logic] = LogicState.OPEN_AND_SETTLE;
        authEpoch[pl.logic] += 1; // M2.6-P0-5: fresh handle namespace
        delete pendingLogic;
        emit LogicAuthorized(pl.logic);
    }

    function cancelLogic() external onlyGovernance {
        delete pendingLogic;
    }

    /// Revoke a drained logic contract. Immediate: revocation only ever REDUCES
    /// privilege, so it needs no timelock.
    /// @notice Stop a logic opening new cases while it settles the ones it has.
    function retireLogic(address logic) external onlyGovernance {
        if (logicState[logic] != LogicState.OPEN_AND_SETTLE) revert NotLogic();
        logicState[logic] = LogicState.SETTLE_ONLY;
        emit LogicRetiring(logic);
    }

    /// @dev Refuses while the logic still holds obligations. Revocation used to
    ///      rely on governance BELIEVING the old logic had drained; `canRevoke` is
    ///      the on-chain fact. (`openPotsTotal` in the game contract is not one —
    ///      it is decremented at settlement init.)
    function revokeLogic(address logic) external onlyGovernance {
        if (!canRevoke(logic)) revert LogicStillHasObligations();
        logicState[logic] = LogicState.NONE;
        emit LogicRevoked(logic);
    }

    // Two-step governance transfer (L-series): no accidental hand-off to a
    // mistyped or zero address.
    address public pendingGovernance;

    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernance = next;
        emit GovernanceTransferProposed(next);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotGovernance();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(msg.sender);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function moderatorInfo(address a)
        external
        view
        returns (
            uint256 free,
            uint256 pending,
            uint256 committed,
            uint256 frozen,
            uint256 frozenUntil,
            uint256 activatesAt,
            uint256 exitAmount,
            uint256 exitClaimableAt,
            uint256 track
        )
    {
        Moderator storage m = moderators[a];
        return (
            m.free, m.pending, m.committed, m.frozen, m.frozenUntil, m.activatesAt, m.exitAmount, m.exitClaimableAt, m.track
        );
    }

    function totalStakeOf(address a) external view returns (uint256) {
        return _total(moderators[a]);
    }

    function trackOf(address a) external view returns (uint256) {
        return moderators[a].track;
    }

    function dutyOf(address a) external view returns (uint256 units, uint256 reserved, uint256 bonded) {
        Moderator storage m = moderators[a];
        return (m.dutyUnits, m.dutyReserved, m.dutyBonded);
    }

    /// Escrow currently posted against outstanding draw assignments (M2.6-P0-2).
    /// Single-word: the logic contract reads this on the commit path and is the
    /// EIP-170-bound side of the boundary.
    function dutyBondedOf(address a) external view returns (uint256) {
        return moderators[a].dutyBonded;
    }

    function eligibleWeightOf(address a) external view returns (uint256) {
        return _eligibleWeight(moderators[a]);
    }

    function totalEligibleWeight() external view returns (uint256) {
        return stakeTree.total();
    }

    /// Conservation: every token held is somebody's stake, in exactly one bucket.
    function stakeBuckets() external view returns (uint256) {
        return totalFreeStake + totalCommittedStake + totalFrozenStake + totalDutyBondedStake;
    }

    // --- internals -----------------------------------------------------------

    function _total(Moderator storage m) internal view returns (uint256) {
        return m.free + m.committed + m.frozen + m.dutyBonded;
    }

    /// @notice The epoch containing `block.number`. A fixed cadence: no
    ///         participant, and no volume of activity, can move a boundary.
    function currentEpoch() public view returns (uint256) {
        return block.number / epochBlocks;
    }

    /// First block of the epoch AFTER the current one — where a seed that cannot
    /// fit inside this epoch is deferred to.
    function nextEpochStart() external view returns (uint256) {
        return (currentEpoch() + 1) * epochBlocks;
    }

    /// @notice True once every change staged in earlier epochs has been applied,
    ///         i.e. the eligible set for this epoch is complete and will not move
    ///         again until the next boundary.
    function epochSettled() public view returns (bool) {
        return appliedEpoch == currentEpoch();
    }

    /// @notice Apply staged weight changes for elapsed epochs. Permissionless and
    ///         batched, and the ONLY place the drain happens (M2.6-P0-3b):
    ///         `drawPanel` treats a settled epoch as a precondition rather than
    ///         draining inside a call that may then revert and discard the work.
    ///         `Moderation.realizeSeats` calls this itself when it finds the epoch
    ///         unsettled and returns, so a draw makes drain progress every poke and
    ///         recovers on its own — no external keeper is required.
    /// @dev Timing is not a lever. The set applied here was fixed before this
    ///      epoch began, and applying it is all-or-nothing per epoch, so nobody
    ///      can choose to reveal a change after seeing a seed's entropy.
    /// @param maxItems Bound on staged entries processed. Progress persists across
    ///        calls through `drainCursor`, so any bound eventually completes.
    function advanceEpoch(uint256 maxItems) external {
        _drainEpochs(maxItems);
    }

    function _drainEpochs(uint256 maxItems) internal {
        uint256 target = currentEpoch();
        uint256 applied = appliedEpoch;
        uint256 budget = maxItems;
        while (applied < target && budget > 0) {
            uint256 e = applied + 1; // the epoch whose stages become effective
            address[] storage list = stagedByEpoch[e - 1];
            uint256 n = list.length;
            uint256 i = drainCursor;
            while (i < n && budget > 0) {
                address a = list[i];
                delete isStaged[e - 1][a];
                uint256 w = _eligibleWeight(moderators[a]);
                epochWeight[a] = w;
                stakeTree.set(a, w);
                unchecked {
                    ++i;
                    --budget;
                }
            }
            if (i < n) {
                drainCursor = i;
                appliedEpoch = applied;
                return; // out of budget mid-epoch; a keeper finishes it
            }
            drainCursor = 0;
            applied = e;
        }
        appliedEpoch = applied;
    }

    /// @dev Record that `a`'s draw-eligible weight has changed. The moderator's
    ///      own accounting is already live; only the SORTITION TREE is deferred,
    ///      to the start of the next epoch. That deferral is the whole of P0-3:
    ///      within an epoch the eligible set cannot move, so a draw armed and
    ///      realized inside one epoch cannot be reshaped after its entropy is
    ///      public — in either direction, by anyone.
    function _stage(address a) internal {
        uint256 e = currentEpoch();
        if (isStaged[e][a]) return;
        isStaged[e][a] = true;
        stagedByEpoch[e].push(a);
    }

    /// @dev As `_stage`, without the dedupe flag. The drain recomputes weight from
    ///      live state, so a duplicate entry is idempotent — it only costs the
    ///      drain an extra recompute. Used on the DRAW path, where the flag's cold
    ///      SSTORE is paid once per seated moderator and the 47-seat panel is
    ///      already the most expensive transaction in the protocol. Callers that a
    ///      griefer could invoke repeatedly must use `_stage`, which bounds list
    ///      growth; a seat cannot be repeated for free.
    function _stageSeated(address a) internal {
        stagedByEpoch[currentEpoch()].push(a);
    }

    /// Draw-eligible weight (H-07): free, unreserved stake CAPPED by remaining
    /// pledged duty capacity, and zero while frozen.
    function _eligibleWeight(Moderator storage m) internal view returns (uint256) {
        if (block.timestamp < m.frozenUntil) return 0; // fully excluded while frozen
        uint256 reserved = m.pending + m.exitAmount;
        if (m.free <= reserved) return 0;
        if (m.dutyUnits <= m.dutyReserved) return 0; // capacity fully in use
        uint256 usable = m.free - reserved;
        uint256 capacity = (m.dutyUnits - m.dutyReserved) * riskPerSeat;
        return usable < capacity ? usable : capacity;
    }

    /// @dev Was an immediate `stakeTree.set`. Since M2.6-P0-3 the tree is only
    ///      written at epoch boundaries (`_drainEpochs`) or transiently inside a
    ///      draw, so every other caller stages instead. The moderator struct is
    ///      still updated immediately by its caller — the struct is the authority
    ///      for what may be seated (P0-2's escrow check reads it), the tree is
    ///      only the sampling distribution.
    function _syncTree(address moderator, Moderator storage m) internal {
        m; // weight is recomputed at drain time from live state
        _stage(moderator);
    }
}
