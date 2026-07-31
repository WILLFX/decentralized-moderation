// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {RulesetGovernor} from "../src/RulesetGovernor.sol";

/// @title Deploy — the deployment and linking step (M2.6-item-9)
///
/// The repository had no `script/` at all. `Settlement` is a **linked library**: it
/// must be deployed and its address linked into `Moderation` before `Moderation` can
/// be deployed at all. Foundry does that automatically for tests, so nothing in the
/// suite could catch it being missed, and the requirement lived only in a README
/// table — the shape of gap this milestone keeps finding, one file over.
///
/// ## The deliverable is `verify`, not `deploy`
///
/// A script that deploys and stops is the same gap in a different place. Anything
/// that would make the stack unusable must fail HERE, not on the first case, so the
/// phases below are split and `verify` is the artefact. `Deploy.t.sol` drives all of
/// them through the timelock and asserts every invariant this claims.
///
/// ## The order, and why it is the only one
///
/// 1. `StakeRegistry` — governance is `msg.sender`.
/// 2. `IndexRegistry` — governance is `msg.sender`.
/// 3. `RulesetGovernor` — **before** `Moderation`, because `Moderation.governor` is
///    immutable and must be given at construction.
/// 4. `Settlement` deployed and linked (Foundry's job; see `verify`'s note).
/// 5. `Moderation` — reverts on a zero governor, and on
///    `token != stakeReg.token()` (item 4).
/// 6. `governor.bindModeration(moderation)` — **one-way and unrecoverable.** A wrong
///    bind leaves a governor that governs nothing and a `Moderation` whose immutable
///    `governor` points at it, with no path back from either side.
/// 7. `proposeLogic(moderation)` on BOTH registries, wait `timelockDelay`, then
///    `executeLogic()` on both.
///
/// The circularity — the governor needs the game, the game needs the governor —
/// resolves because `RulesetGovernor` is constructed without a `Moderation` reference
/// and binds afterward. That is what makes step 6 both necessary and irreversible.
///
/// ## Two things this deployment is, that a single `run()` would hide
///
/// **It is not one transaction.** The registry timelock sits between steps 7a and 7b,
/// so there is a window in which every contract exists and none of them is authorized.
/// `Moderation.submit` refuses during it (`_requireOpen`, M2.6-P0-5), which is correct
/// — a case opened then would take a fee it could never settle. The window is a
/// property of the design, not an accident of scripting, and `Deploy.t.sol` asserts
/// the refusal rather than waiting it out.
///
/// **Governance is the deployer until it is transferred.** Both registries set
/// `governance = msg.sender` at construction, and the governor takes it as an
/// argument. `handOverGovernance` performs the two-step transfer; if it is not
/// called, `verify` says so LOUDLY rather than passing quietly, because a deployment
/// whose registries are still owned by a deploy key is a finding, not a default.
contract Deploy is Script {
    /// Everything the stack needs that is not derivable. No defaults here on purpose:
    /// a deployment parameter with a default is a deployment parameter nobody reads.
    struct Config {
        address token;
        uint256 registryTimelock;
        uint256 minStake;
        uint256 activationDelay;
        uint256 exitCooldown;
        uint256 riskPerSeat; // the registry's DUTY UNIT
        uint256 epochBlocks;
        uint256 governorTimelock;
        /// Where registry + governor ownership goes. `address(0)` keeps the deployer,
        /// and `verify` will say so.
        address governanceOwner;
    }

    struct Stack {
        StakeRegistry stakeReg;
        IndexRegistry indexReg;
        RulesetGovernor governor;
        Moderation moderation;
    }

    error TokenMismatch();
    error NotAuthorizedOnStakeRegistry();
    error NotAuthorizedOnIndexRegistry();
    error GovernorNotBound();
    error ModerationNotBound();
    error SeatCollateralExceedsDutyUnit();
    error SettlementNotDeployed();
    error SettlementWrongCode();

    // --- phases ---------------------------------------------------------------

    /// Steps 1-6. Leaves the stack constructed and bound, and NOT yet authorized.
    function deployCore(Config memory cfg) public returns (Stack memory s) {
        s.stakeReg = new StakeRegistry(
            IERC20(cfg.token),
            cfg.registryTimelock,
            cfg.minStake,
            cfg.activationDelay,
            cfg.exitCooldown,
            cfg.riskPerSeat,
            cfg.epochBlocks
        );
        s.indexReg = new IndexRegistry(cfg.registryTimelock);

        // Before Moderation: `Moderation.governor` is immutable.
        s.governor = new RulesetGovernor(address(this), cfg.governorTimelock);

        // Linking happens here, invisibly — see `verify`.
        s.moderation = new Moderation(IERC20(cfg.token), s.stakeReg, s.indexReg, address(s.governor));

        // One-way. Nothing below this line can undo it.
        s.governor.bindModeration(s.moderation);
    }

    /// Step 7a. Starts the timelock on both registries.
    function proposeAuthorization(Stack memory s) public {
        s.stakeReg.proposeLogic(address(s.moderation));
        s.indexReg.proposeLogic(address(s.moderation));
    }

    /// Step 7b. Only valid once `registryTimelock` has elapsed since 7a.
    function executeAuthorization(Stack memory s) public {
        s.stakeReg.executeLogic();
        s.indexReg.executeLogic();
    }

    /// Two-step handover of both registries and the governor. The recipient must
    /// call `acceptGovernance()` on each; nothing here can do that for them, which
    /// is the point of the two-step.
    function handOverGovernance(Stack memory s, address next) public {
        s.stakeReg.proposeGovernance(next);
        s.indexReg.proposeGovernance(next);
        s.governor.proposeGovernance(next);
    }

    // --- the deliverable ------------------------------------------------------

    /// Every condition that would make the stack unusable. Reverts rather than
    /// logging, so a broken deployment fails the script and not the first case.
    ///
    /// @param expectedSettlement The library address, if the operator linked
    ///        explicitly (`--libraries src/lib/Settlement.sol:Settlement:0x...`).
    ///        Pass `address(0)` when Foundry auto-linked — see the note below.
    function verify(Stack memory s, Config memory cfg, address expectedSettlement) public view {
        // 1. One asset. A mismatch is not an accounting quirk: `reward()` pulls the
        //    REGISTRY's token from `Moderation`, which under a mismatch it does not
        //    hold, so `claim` reverts permanently and stake is locked (item 4). The
        //    constructor already refuses it; asserted here because a check that
        //    exists and a check that ran are different facts.
        if (address(s.moderation.token()) != address(s.stakeReg.token())) revert TokenMismatch();

        // 2. Authorized on BOTH registries. Desynchronised authorization is its own
        //    failure mode, not half of this one: a logic authorized on one can open
        //    cases it cannot settle. `logicState` rather than a boolean, because
        //    SETTLE_ONLY is a real third state and only OPEN_AND_SETTLE will do here.
        if (s.stakeReg.logicState(address(s.moderation)) != StakeRegistry.LogicState.OPEN_AND_SETTLE) {
            revert NotAuthorizedOnStakeRegistry();
        }
        if (s.indexReg.logicState(address(s.moderation)) != IndexRegistry.LogicState.OPEN_AND_SETTLE) {
            revert NotAuthorizedOnIndexRegistry();
        }

        // 3. The bind, from BOTH sides. Step 6 is irreversible, so a half-bind is
        //    the one error this script exists to catch before it is permanent.
        if (s.moderation.governor() != address(s.governor)) revert GovernorNotBound();
        if (address(s.governor.moderation()) != address(s.moderation)) revert ModerationNotBound();

        // 4. A case may never lock more per seat than a pledged duty unit is worth,
        //    or panels are seated on collateral that cannot cover them (D-13).
        if (s.stakeReg.riskPerSeat() < s.moderation.getParams().riskPerSeat) {
            revert SeatCollateralExceedsDutyUnit();
        }

        // 5. The linked library.
        //
        //    **Stated rather than faked: Solidity cannot read its own link table.**
        //    The library address is baked into `Moderation`'s bytecode at link time
        //    and there is no way to recover it from inside a contract, so no
        //    in-script assertion can prove that `Moderation` points at a live
        //    `Settlement`. What is checkable splits in two:
        //
        //      - if the operator linked explicitly, the address they linked is known
        //        here and this asserts it holds the RIGHT code, not merely some code;
        //      - that `Moderation` actually reaches it is behavioural, and
        //        `Deploy.t.sol` proves it the only way it can be proven — by driving
        //        a case through to SETTLED, which delegatecalls the library.
        //
        //    A deployment that skips both is not verified on this point, and the
        //    caller is told so rather than left with a green run.
        if (expectedSettlement != address(0)) {
            if (expectedSettlement.code.length == 0) revert SettlementNotDeployed();
            if (expectedSettlement.codehash != keccak256(vm.getDeployedCode("Settlement.sol:Settlement"))) {
                revert SettlementWrongCode();
            }
        } else {
            console2.log(
                "WARNING: Settlement link unverified. Foundry auto-linked it; re-run with"
                " --libraries, or smoke-test by settling one case before going live."
            );
        }

        // 6. Ownership. Not a revert: a deployer-owned stack is a legitimate
        //    intermediate state. It is loud because it is a finding if left.
        if (cfg.governanceOwner == address(0)) {
            console2.log("WARNING: governance NOT transferred. Both registries and the governor are");
            console2.log("         still owned by the deploy key:", s.stakeReg.governance());
        } else {
            console2.log("Governance handover PROPOSED to:", cfg.governanceOwner);
            console2.log("         Incomplete until that address calls acceptGovernance() on each of");
            console2.log("         StakeRegistry, IndexRegistry and RulesetGovernor.");
        }
    }

    // --- entry point ----------------------------------------------------------

    /// Phase 1 of 2. Deploys, binds, and starts the registry timelock. The window it
    /// opens is real: everything exists, nothing is authorized, and `submit` refuses.
    function run() external returns (Stack memory s) {
        Config memory cfg = _configFromEnv();
        vm.startBroadcast();
        s = deployCore(cfg);
        proposeAuthorization(s);
        vm.stopBroadcast();

        console2.log("StakeRegistry   ", address(s.stakeReg));
        console2.log("IndexRegistry   ", address(s.indexReg));
        console2.log("RulesetGovernor ", address(s.governor));
        console2.log("Moderation      ", address(s.moderation));
        console2.log("Authorization proposed. Wait", cfg.registryTimelock, "seconds, then run `finish`.");
    }

    /// Phase 2 of 2. Executes the authorization and verifies. Takes the addresses
    /// phase 1 printed, because the two phases are separate transactions on separate
    /// days and nothing in between can be assumed to have survived.
    function finish(Stack memory s, address expectedSettlement) external {
        Config memory cfg = _configFromEnv();
        vm.startBroadcast();
        executeAuthorization(s);
        if (cfg.governanceOwner != address(0)) handOverGovernance(s, cfg.governanceOwner);
        vm.stopBroadcast();
        verify(s, cfg, expectedSettlement);
    }

    function _configFromEnv() internal view returns (Config memory cfg) {
        cfg.token = vm.envAddress("TOKEN");
        cfg.registryTimelock = vm.envUint("REGISTRY_TIMELOCK");
        cfg.minStake = vm.envUint("MIN_STAKE");
        cfg.activationDelay = vm.envUint("ACTIVATION_DELAY");
        cfg.exitCooldown = vm.envUint("EXIT_COOLDOWN");
        cfg.riskPerSeat = vm.envUint("RISK_PER_SEAT");
        cfg.epochBlocks = vm.envUint("EPOCH_BLOCKS");
        cfg.governorTimelock = vm.envUint("GOVERNOR_TIMELOCK");
        cfg.governanceOwner = vm.envOr("GOVERNANCE_OWNER", address(0));
    }
}
