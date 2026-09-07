// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../src/v3/Moderation.sol";
import {StakeRegistry} from "../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../src/v3/IndexRegistry.sol";
import {RulesetGovernor} from "../src/v3/RulesetGovernor.sol";

/// @title DeployV3 — the four-contract bring-up, as one executable unit
///
/// @notice v3 had no deploy script. The wiring order — construct, grant caps, grant
///         writer, bind the governor, apply the first ruleset — existed only as
///         `setUp()` in four test files, each of which happened to get it right.
///         A four-contract system whose bring-up sequence has never been executed
///         as a unit is a system nobody has actually run.
///
/// @dev **The order is forced, not chosen, and two constraints do the forcing.**
///
///      1. `Moderation` takes its governor as a CONSTRUCTOR argument, and
///         `RulesetGovernor.bindModeration` refuses a `Moderation` that does not
///         already name it (M2.6-F3). So the governor must exist before
///         `Moderation`, and the bind must come after it. There is no ordering in
///         which a governor is bound to a `Moderation` that was deployed first.
///
///      2. Both capability grants run behind their own timelocks —
///         `StakeRegistry.proposeCaps`/`executeCaps` and
///         `IndexRegistry.proposeWriter`/`executeWriter`. A deployment cannot
///         complete in one transaction, and pretending otherwise is how a
///         half-wired stack reaches a chain.
///
///      **`verify` is the deliverable, not `deploy`.** Anyone can write four `new`
///      expressions; what is worth having is a single call that says whether a
///      deployed stack is actually wired — because every one of these links fails
///      silently. A `Moderation` without `MAY_CREATE` reverts at the first commit,
///      not at deploy. A `Moderation` that is not an index writer reverts at the
///      first terminal, after a cohort has already voted. An unbound governor
///      reverts at `executeParams`, after the full timelock.
contract DeployV3 is Script {
    struct Stack {
        StakeRegistry reg;
        IndexRegistry idx;
        RulesetGovernor governor;
        Moderation mod;
    }

    struct Config {
        IERC20 token;
        address governance;
        uint256 minStake;
        uint256 bondMin;
        uint256 maturation;
        uint256 exitCooldown;
        uint256 timelockDelay;
        uint256 minTrackDecay;
    }

    error NotWired(string what);

    // =========================================================================
    // Phase 1 — construct
    // =========================================================================

    /// @notice Deploy the four contracts and queue both capability grants.
    /// @dev Ends with two proposals pending. It cannot do more: the timelocks are
    ///      the point, and a deploy script that could skip them would be evidence
    ///      the timelocks do not work.
    function deployAndPropose(Config memory c) public returns (Stack memory s) {
        if (address(c.token) == address(0)) revert NotWired("token");
        if (c.governance == address(0)) revert NotWired("governance");

        s.reg = new StakeRegistry(
            c.token, c.minStake, c.bondMin, c.maturation, c.exitCooldown, c.timelockDelay, c.minTrackDecay
        );
        s.idx = new IndexRegistry(c.timelockDelay);

        // The governor BEFORE Moderation — see the note above.
        //
        // It is constructed owned by the DEPLOYER, not by `c.governance`, and
        // handed over at the end. Bring-up is a governance action — the bind and
        // the first ruleset both are — so an owner set at construction would have
        // to co-sign every step of a deployment. The two registries already work
        // this way; the governor matching them is what makes `handOverGovernance`
        // one call instead of three different idioms.
        s.governor = new RulesetGovernor(address(this), c.timelockDelay);
        s.mod = new Moderation(c.token, s.reg, IIndexRegistry(address(s.idx)), address(s.governor));

        // Mutual by construction, and the bind proves it rather than assuming it.
        s.governor.bindModeration(s.mod);

        s.reg.proposeCaps(address(s.mod), s.reg.MAY_CREATE() | s.reg.MAY_DISCHARGE());
        s.idx.proposeWriter(address(s.mod), true);
    }

    /// @notice The last step: nominate the real owner on all three governed
    ///         contracts. Two-step everywhere, so the owner must claim it — which
    ///         is what proves the address is controlled before it holds authority.
    /// @dev Deliberately AFTER the ruleset. A handover before it would leave a
    ///      wired stack with no parameters that only the new owner could fix, and
    ///      `submit` reverts `BadParams` on version 0 — so the window between
    ///      handover and first ruleset is a window where the system is deployed,
    ///      owned, and unusable.
    function handOverGovernance(Stack memory s, address governance) public {
        if (governance == address(0)) revert NotWired("governance");
        s.reg.proposeGovernance(governance);
        s.idx.proposeGovernance(governance);
        s.governor.proposeGovernance(governance);
    }

    // =========================================================================
    // Phase 2 — after the timelock
    // =========================================================================

    /// @notice Execute both capability grants. Callable only once the delay has run.
    function executeGrants(Stack memory s) public {
        s.reg.executeCaps();
        s.idx.executeWriter();
    }

    // =========================================================================
    // Verification — the part worth having
    // =========================================================================

    /// @notice Assert every link in the stack, and revert naming the first missing
    ///         one. Every check here corresponds to a failure that would otherwise
    ///         surface late, in someone else's transaction.
    function verify(Stack memory s) public view {
        // The constructor references.
        if (address(s.mod.stakeReg()) != address(s.reg)) revert NotWired("Moderation.stakeReg");
        if (address(s.mod.index()) != address(s.idx)) revert NotWired("Moderation.index");
        if (s.mod.governor() != address(s.governor)) revert NotWired("Moderation.governor");

        // The bind, from the other side. Both directions are checked because F3's
        // whole finding was that one of them held while the other did not.
        if (address(s.governor.moderation()) != address(s.mod)) revert NotWired("RulesetGovernor.moderation");

        // §2.4's two capabilities. Missing MAY_CREATE reverts at the first commit;
        // missing MAY_DISCHARGE reverts at the first settlement, which is worse —
        // the bonds are already committed by then.
        uint8 caps = s.reg.caps(address(s.mod));
        if (caps & s.reg.MAY_CREATE() == 0) revert NotWired("StakeRegistry.MAY_CREATE");
        if (caps & s.reg.MAY_DISCHARGE() == 0) revert NotWired("StakeRegistry.MAY_DISCHARGE");

        // §8.1's writer capability. Missing, every terminal transition reverts —
        // after a cohort has voted and with the case unfinalizable.
        if (!s.idx.writers(address(s.mod))) revert NotWired("IndexRegistry.writer");

        // A ruleset must exist: `submit` reverts `BadParams` on version 0, so a
        // stack with no parameters is deployed, wired, and unusable.
        if (s.mod.paramsVersion() == 0) revert NotWired("Moderation.paramsVersion");

        // M2.12 — the governor must not have retired out of this stack. A retired
        // governor still reports the right `moderation`, so every check above
        // passes while nothing it does can reach `Moderation` any more.
        if (s.governor.retired()) revert NotWired("RulesetGovernor.retired");

        // §4.1's pin. The two sides are allocated by the governor and stored by
        // `Moderation`, so they can only diverge if a push was missed — and a
        // reader consulting the governor's log would then get an answer no case
        // agrees with. Guidelines are OPTIONAL at bring-up (version 0 is a legal
        // "none published yet"), so this checks agreement, not presence.
        if (s.mod.currentGuidelinesVersion() != s.governor.guidelinesVersion()) {
            revert NotWired("guidelinesVersion divergence");
        }
    }

    /// @notice Whether the stack is fully wired, as a bool rather than a revert.
    function isWired(Stack memory s) public view returns (bool) {
        try this.verify(s) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Apply the first ruleset, through the governor like every later one.
    /// @dev Separate from `executeGrants` because it waits on a DIFFERENT timelock —
    ///      the governor's — and a deployment that assumed one wait covered both
    ///      would fail at the last step with everything else already live.
    function applyFirstRuleset(Stack memory s, Moderation.Params memory p) public {
        s.governor.proposeParams(p);
    }

    function executeFirstRuleset(Stack memory s, Moderation.Params memory p) public {
        s.governor.executeParams(p);
    }

    /// @notice Publish the first guidelines version. Optional at bring-up.
    /// @dev Version 0 is a legal "none published yet" — `submit` does not require
    ///      one — so a stack may go live before any text exists. It is offered here
    ///      because doing it through the script is the only way the push into
    ///      `Moderation` is exercised as part of a deployment rather than as part
    ///      of a test.
    function proposeFirstGuidelines(Stack memory s, bytes32 hash) public {
        s.governor.proposeGuidelines(hash);
    }

    function executeFirstGuidelines(Stack memory s, bytes32 hash) public {
        s.governor.executeGuidelines(hash);
    }
}
