// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Moderation} from "./Moderation.sol";

/// @title RulesetGovernor (v3) — the fourth contract
/// @notice Closes the governance asymmetry §10 names: `StakeRegistry` timelocks
///         everything a governor can do, while `Moderation.applyParams` is
///         `onlyGovernor` and takes effect immediately — no pending record, no
///         `eta`, nothing for anyone to observe or exit ahead of.
///
/// @dev **This contract is `Moderation`'s governor, not its host.** The naive
///      reading of "timelock `applyParams`" puts a `PendingParams` struct and a
///      propose/cancel/execute trio inside `Moderation`, and `Params` is a wide
///      struct — 21 fields across seven slots. `Moderation` had 3,148 bytes of
///      EIP-170 headroom when this was written, so that reading risks the limit for
///      a property that does not need to live there. The timelock is a governance
///      concern and governance is a separate contract; `Moderation`'s delta for
///      this milestone is zero.
///
///      **What stays in `Moderation`, deliberately.** `applyParams` validates its
///      own arguments, including §10's one hard bound
///      (`commitBlocks <= SEED_LAG + BLOCKHASH_HORIZON`, §3.1). This contract
///      validates the same things at PROPOSE time so a bad ruleset fails in the
///      transaction that proposes it rather than after the full delay — but it
///      validates *as well as*, never *instead of*. A check that lives only in the
///      governor is a check that a replacement governor removes.
///
///      **Why I27 makes this a risk asymmetry and not a correctness defect.** A
///      case pins its parameter version at submission and every debit it produces
///      is computed from that block. So a parameter change never moves a live case;
///      it moves the next one. What the timelock buys is not case safety — that is
///      already held — but the ability for a moderator to see a change coming and
///      decline to commit under it.
contract RulesetGovernor {
    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The contract this governor governs. Bound once, never rebound.
    Moderation public moderation;

    address public governance;
    address public pendingGovernance;

    uint256 public immutable timelockDelay;

    /// @notice A queued parameter change, stored as a HASH of the parameters.
    /// @dev Storing the hash rather than the struct does two things at once. It is
    ///      the §3 swap defence — `executeParams` takes the parameters and checks
    ///      them against this — and it keeps a 21-field struct out of storage, so
    ///      queueing a ruleset costs one slot instead of seven.
    ///
    ///      The full parameters travel in `ParamsProposed`, so anyone watching logs
    ///      can reconstruct exactly what is queued. The chain holds the commitment;
    ///      the log holds the content.
    struct Pending {
        bytes32 hash;
        uint40 eta;
        bool exists;
    }

    Pending public pendingParams;
    Pending public pendingGuidelines;

    /// @notice §4.1's guidelines version, monotonic and never reused.
    /// @dev It lives HERE and not in `Moderation` because `Moderation` has no
    ///      guidelines surface in v3 — see the reported finding. Version 0 means
    ///      "no guidelines have ever been published", which is distinct from any
    ///      published version, on the same reasoning §8.2 gives for `Status.NONE`.
    uint32 public guidelinesVersion;

    /// @notice `version -> keccak256(guideline text)`.
    mapping(uint32 => bytes32) public guidelinesHashOf;

    /// @notice `version -> the block at which it took effect`.
    /// @dev This is what makes "which text was this case decided under" answerable
    ///      by a contract and not only by a log reader. `measurement/prior` must
    ///      partition cases by the guidelines in force at submission, and with no
    ///      per-case pin in `Moderation` (see the finding) that partition is a join
    ///      between a case's submission block and this map. Recording the block is
    ///      what makes the join well-defined rather than a guess from timestamps.
    mapping(uint32 => uint40) public guidelinesBlockOf;

    // =========================================================================
    // Events
    // =========================================================================

    /// @dev Carries the FULL parameter block, not just the hash. The hash is the
    ///      commitment `executeParams` checks against; the body is what lets a
    ///      reviewer see what they are approving without an archive node.
    event ParamsProposed(bytes32 indexed hash, uint256 eta, Moderation.Params params);
    event ParamsCancelled(bytes32 indexed hash);
    event ParamsExecuted(bytes32 indexed hash, uint32 indexed version);

    /// @notice §4 of the M2.11 order — version AND hash, in one log line.
    /// @dev The measurement reads logs, not storage. A version bump that is
    ///      invisible in the logs silently splits the dataset along
    ///      `guidelinesVersion`, and the split is only discovered when the sample
    ///      turns out underpowered — long after the cases were decided and with no
    ///      way to re-run them.
    event GuidelinesProposed(bytes32 indexed hash, uint256 eta);
    event GuidelinesCancelled(bytes32 indexed hash);
    event GuidelinesExecuted(uint32 indexed version, bytes32 indexed hash, uint256 blockNumber);

    event ModerationBound(address indexed moderation);
    event GovernanceProposed(address indexed next);
    event GovernanceTransferred(address indexed next);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotGovernance();
    error NoPendingProposal();
    error TimelockNotElapsed();
    error ProposalMismatch();
    error BadParams();
    error CommitWindowExceedsSeedHorizon();
    error AlreadyBound();
    error NotBound();
    error BindingNotMutual();
    error ZeroAddress();
    error ZeroHash();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(address _governance, uint256 _timelockDelay) {
        if (_governance == address(0)) revert ZeroAddress();
        governance = _governance;
        timelockDelay = _timelockDelay;
    }

    // =========================================================================
    // Binding
    // =========================================================================

    /// @notice Point this governor at the `Moderation` it governs. One-way.
    /// @dev **The bind checks that the binding is MUTUAL** (M2.6-F3, carried over).
    ///      Without it a governor could bind to a `Moderation` that had never heard
    ///      of it: the bind succeeds, `proposeParams` succeeds, the timelock runs
    ///      its full course, and the failure surfaces at `executeParams` as a revert
    ///      out of `applyParams` — after the wait, from the call that looks like the
    ///      governance action landing. The check moves that failure to the
    ///      transaction that causes it.
    ///
    ///      **v1's permanence argument does not carry over unchanged, and this is
    ///      the reason `moderation` is never rebound.** In v1 `Moderation.governor`
    ///      was `immutable`, so a check at bind time was a permanent guarantee about
    ///      both sides. In v3 it is mutable through `Moderation.setGovernor`, which
    ///      is `onlyGovernor` — so once `Moderation.governor` is this contract, the
    ///      ONLY caller that could move it is this contract. This contract exposes
    ///      no path to `setGovernor`, so the field is frozen by omission and the
    ///      bind-time check is permanent again.
    ///
    ///      That is a deliberate trade and it is recorded in DEVIATIONS D3-20: it
    ///      buys back F3's guarantee at the cost of making this governor
    ///      unreplaceable for the life of the `Moderation` it governs. The migration
    ///      path is `proposeGovernance` — the governor contract stays, its owner
    ///      moves — which is the same shape v1 had when the field was immutable.
    function bindModeration(Moderation m) external onlyGovernance {
        if (address(moderation) != address(0)) revert AlreadyBound();
        if (address(m) == address(0)) revert ZeroAddress();
        if (m.governor() != address(this)) revert BindingNotMutual();
        moderation = m;
        emit ModerationBound(address(m));
    }

    // =========================================================================
    // Parameters
    // =========================================================================

    function proposeParams(Moderation.Params calldata p) external onlyGovernance {
        _validateParams(p);
        bytes32 h = keccak256(abi.encode(p));
        uint40 eta = uint40(block.timestamp + timelockDelay);
        pendingParams = Pending({hash: h, eta: eta, exists: true});
        emit ParamsProposed(h, eta, p);
    }

    /// @notice §3 of the M2.11 order — execute NAMES what it executes.
    /// @dev `executeCaps()` and `executeMaintenanceWithdrawal()` execute whatever is
    ///      pending. Inside a multisig that means one signer can queue a change, a
    ///      second replace it, and an approval given for the first execute the
    ///      second. The timelock defuses that rather than the signature does — a
    ///      replacement calls propose again and resets the `eta`, so the swap waits
    ///      the full delay in the open — but "defused by a different mechanism" is
    ///      not the same as "cannot happen", and this contract is new enough not to
    ///      have to inherit it.
    ///
    ///      The comparison is against a hash rather than a field-by-field struct
    ///      compare: same guarantee, one word of storage, and no risk of a compare
    ///      that silently omits a field somebody adds later.
    ///
    ///      `StakeRegistry`'s two are deliberately NOT retrofitted — they sit inside
    ///      a 33/33 mutation baseline. This is the pattern going forward.
    function executeParams(Moderation.Params calldata p) external onlyGovernance returns (uint32 version) {
        if (address(moderation) == address(0)) revert NotBound();
        Pending memory pp = pendingParams;
        if (!pp.exists) revert NoPendingProposal();
        if (block.timestamp < pp.eta) revert TimelockNotElapsed();
        if (keccak256(abi.encode(p)) != pp.hash) revert ProposalMismatch();

        delete pendingParams;
        version = moderation.applyParams(p);
        emit ParamsExecuted(pp.hash, version);
    }

    function cancelParams() external onlyGovernance {
        Pending memory pp = pendingParams;
        if (!pp.exists) revert NoPendingProposal();
        delete pendingParams;
        emit ParamsCancelled(pp.hash);
    }

    // =========================================================================
    // Guidelines (§4.1, and `measurement/prior`)
    // =========================================================================

    /// @dev A zero hash is refused for the same reason §8.2b refuses a zero topic
    ///      key: it would make "no guidelines recorded for this version" and "the
    ///      guidelines whose text hashes to zero" the same read, in the map whose
    ///      whole job is telling published versions apart.
    function proposeGuidelines(bytes32 hash) external onlyGovernance {
        if (hash == bytes32(0)) revert ZeroHash();
        uint40 eta = uint40(block.timestamp + timelockDelay);
        pendingGuidelines = Pending({hash: hash, eta: eta, exists: true});
        emit GuidelinesProposed(hash, eta);
    }

    /// @notice Publish the queued guidelines under the next version.
    /// @dev **Monotonic, and never reused.** `version` only ever increments, so two
    ///      different texts can never share a version and one text re-published gets
    ///      a new one. Cases decided under different guideline text are different
    ///      experiments and must not be pooled (`measurement/prior/README.md`); a
    ///      version that could be reused would silently merge two of them.
    function executeGuidelines(bytes32 hash) external onlyGovernance returns (uint32 version) {
        Pending memory pg = pendingGuidelines;
        if (!pg.exists) revert NoPendingProposal();
        if (block.timestamp < pg.eta) revert TimelockNotElapsed();
        if (hash != pg.hash) revert ProposalMismatch();

        version = ++guidelinesVersion;
        guidelinesHashOf[version] = hash;
        guidelinesBlockOf[version] = uint40(block.number);
        delete pendingGuidelines;
        emit GuidelinesExecuted(version, hash, block.number);
    }

    function cancelGuidelines() external onlyGovernance {
        Pending memory pg = pendingGuidelines;
        if (!pg.exists) revert NoPendingProposal();
        delete pendingGuidelines;
        emit GuidelinesCancelled(pg.hash);
    }

    /// @notice The guidelines version in force at `blockNumber`.
    /// @dev The on-chain half of the partition `measurement/prior` needs. Linear in
    ///      the number of guideline versions, which is a governance action behind a
    ///      timelock — not a quantity that grows with usage, unlike a topic listing
    ///      (§8.2b), so this does not need paging.
    ///
    ///      Returns 0 for a block before the first publication, which is the same
    ///      "no version" value `guidelinesVersion` starts at.
    function guidelinesVersionAt(uint256 blockNumber) external view returns (uint32) {
        uint32 n = guidelinesVersion;
        for (uint32 v = n; v > 0; --v) {
            if (guidelinesBlockOf[v] <= blockNumber) return v;
        }
        return 0;
    }

    // =========================================================================
    // Governance
    // =========================================================================

    /// @dev Two-step and zero-checked, matching both registries. This contract holds
    ///      the protocol's entire ruleset authority: a one-step transfer to a typo
    ///      loses it, and to `address(0)` bricks parameter and guidelines governance
    ///      permanently — with no recovery, because `Moderation` will accept
    ///      `applyParams` from nobody else.
    function proposeGovernance(address next) external onlyGovernance {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernance = next;
        emit GovernanceProposed(next);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotGovernance();
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(msg.sender);
    }

    function cancelGovernanceTransfer() external onlyGovernance {
        pendingGovernance = address(0);
    }

    // =========================================================================
    // Validation — as well as `Moderation`'s, never instead of it
    // =========================================================================

    /// @dev Every check here is also in `Moderation.applyParams`, and that is the
    ///      point. Duplicating them buys ONE thing: a bad ruleset fails in the
    ///      transaction that proposes it rather than after the whole timelock has
    ///      run. It buys no safety, because a replacement governor would not carry
    ///      these — which is exactly why §10's `BLOCK_TIME` bound belongs one layer
    ///      down, where replacing the governor cannot bypass it.
    function _validateParams(Moderation.Params calldata p) internal pure {
        if (p.blockTime == 0 || p.commitWindow == 0 || p.revealWindow == 0 || p.challengeWindow == 0) {
            revert BadParams();
        }
        if (p.blockhashHorizon == 0) revert BadParams();
        if (p.lateWidenAt > p.commitWindow) revert BadParams();
        if (p.lateWidenFactorBps < 10_000) revert BadParams();
        if (p.trackDecay == 0 || p.trackDecay >= 1e18) revert BadParams();
        if (uint256(p.drawBountyBps) + p.claimBountyBps + p.reserveBps + p.maintenanceBps >= 10_000) {
            revert BadParams();
        }

        // §10 / §3.1 — the eligibility seed must survive its own commit window.
        // Stated against the constraint itself, not against the 4.651 s wall-clock
        // consequence, which would drift if any of the three inputs moved.
        uint256 cb = (uint256(p.commitWindow) + p.blockTime - 1) / p.blockTime;
        if (cb > uint256(p.seedLag) + uint256(p.blockhashHorizon)) revert CommitWindowExceedsSeedHorizon();
    }

    // =========================================================================
    // Views
    // =========================================================================

    function pendingParamsProposal() external view returns (bytes32 hash, uint256 eta, bool exists) {
        Pending memory pp = pendingParams;
        return (pp.hash, pp.eta, pp.exists);
    }

    function pendingGuidelinesProposal() external view returns (bytes32 hash, uint256 eta, bool exists) {
        Pending memory pg = pendingGuidelines;
        return (pg.hash, pg.eta, pg.exists);
    }

    function paramsHash(Moderation.Params calldata p) external pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}
