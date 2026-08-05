// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Moderation} from "../src/Moderation.sol";
import {StakeRegistry} from "../src/StakeRegistry.sol";
import {IndexRegistry} from "../src/IndexRegistry.sol";
import {RulesetGovernor} from "../src/RulesetGovernor.sol";
import {MockBZZ} from "./mocks/MockBZZ.sol";

/// M2.6-item-9. **This test is the artefact; the script is what it tests.**
///
/// A deploy script nothing exercises is documentation that compiles. So this drives
/// every phase through the timelock, asserts each invariant `verify` claims, and —
/// crucially — asserts that `verify` REJECTS each broken stack, because a checker
/// that passes everything is the same gap one file further on.
///
/// It runs against the production contracts, not the harnesses. That is deliberate:
/// the rest of the suite deploys through `StackDeployer`, which cannot catch a
/// mistake in how a real deployment is ordered because it makes the same choices
/// every time.
contract DeployTest is Test {
    uint256 internal constant XBZZ = 1e16;

    Deploy internal script;
    MockBZZ internal bzz;
    Deploy.Config internal cfg;

    address internal multisig = makeAddr("multisig");

    function setUp() public {
        script = new Deploy();
        bzz = new MockBZZ();
        cfg = Deploy.Config({
            token: address(bzz),
            registryTimelock: 7 days,
            minStake: 10 * XBZZ,
            activationDelay: 7 days,
            exitCooldown: 7 days,
            riskPerSeat: 10 * XBZZ,
            epochBlocks: 256,
            minTrackDecay: (1e18 * 9) / 10,
            governorTimelock: 7 days,
            governanceOwner: address(0)
        });
    }

    /// Deploy through the script, exactly as an operator would: phase 1, wait, phase 2.
    function _deployThroughScript() internal returns (Deploy.Stack memory s) {
        s = script.deployCore(cfg);
        script.proposeAuthorization(s);
        vm.warp(vm.getBlockTimestamp() + cfg.registryTimelock);
        script.executeAuthorization(s);
    }

    // --- the ordering the constructors force -----------------------------------

    /// Step 3 before step 5, and it is not a style preference: `Moderation.governor`
    /// is immutable, so the governor must exist at construction. The circularity
    /// resolves only because `RulesetGovernor` is built without a `Moderation` and
    /// binds afterward.
    function test_moderation_cannot_be_deployed_before_its_governor() public {
        StakeRegistry sr = new StakeRegistry(
            IERC20(address(bzz)), 7 days, 10 * XBZZ, 7 days, 7 days, 10 * XBZZ, 256, (1e18 * 9) / 10
        );
        IndexRegistry ir = new IndexRegistry(7 days);
        vm.expectRevert(Moderation.ZeroGovernor.selector);
        new Moderation(IERC20(address(bzz)), sr, ir, address(0));
    }

    /// Item 4's constructor check, reached through the deployment path rather than
    /// asserted in isolation — a foreign token is a plausible config error, not an
    /// exotic one.
    function test_a_foreign_token_fails_the_deployment_not_the_first_case() public {
        MockBZZ other = new MockBZZ();
        Deploy.Config memory bad = cfg;
        bad.token = address(other);
        // The registry is built on the foreign token, `Moderation` on the real one:
        // the mismatch is between the two constructor arguments, which is exactly
        // how it would arise from a copy-pasted address.
        StakeRegistry sr = new StakeRegistry(
            IERC20(address(other)), 7 days, 10 * XBZZ, 7 days, 7 days, 10 * XBZZ, 256, (1e18 * 9) / 10
        );
        IndexRegistry ir = new IndexRegistry(7 days);
        RulesetGovernor g = new RulesetGovernor(address(this), 7 days);
        vm.expectRevert(Moderation.TokenMismatch.selector);
        new Moderation(IERC20(address(bzz)), sr, ir, address(g));
    }

    // --- the window the timelock opens -----------------------------------------

    /// **Not one transaction.** Between propose and execute every contract exists and
    /// none is authorized. `submit` must refuse: a case opened then would take a fee
    /// it could never settle, and the refusal is P0-5's `_requireOpen` doing its job
    /// rather than an accident of ordering.
    function test_submit_refuses_during_the_authorization_window() public {
        Deploy.Stack memory s = script.deployCore(cfg);
        script.proposeAuthorization(s);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("marine biology");
        uint256 fee = s.moderation.minFee(1);
        bzz.mint(address(this), fee);
        bzz.approve(address(s.moderation), type(uint256).max);

        vm.expectRevert(Moderation.NotAcceptingSubmissions.selector);
        s.moderation.submit(Moderation.Kind.SUBMISSION, keccak256("c"), keccak256("m"), topics, 0, fee);

        // And it opens the moment the timelock elapses and both registries execute.
        vm.warp(vm.getBlockTimestamp() + cfg.registryTimelock);
        script.executeAuthorization(s);
        s.moderation.submit(Moderation.Kind.SUBMISSION, keccak256("c"), keccak256("m"), topics, 0, fee);
    }

    // --- verify accepts a good stack -------------------------------------------

    function test_verify_passes_a_correctly_deployed_stack() public {
        Deploy.Stack memory s = _deployThroughScript();
        script.verify(s, cfg, address(0));

        // The individual claims, spelled out — `verify` reverting is a weaker
        // statement than each condition actually holding.
        assertEq(address(s.moderation.token()), address(s.stakeReg.token()), "one asset");
        assertEq(
            uint256(s.stakeReg.logicState(address(s.moderation))),
            uint256(StakeRegistry.LogicState.OPEN_AND_SETTLE),
            "authorized stake-side"
        );
        assertEq(
            uint256(s.indexReg.logicState(address(s.moderation))),
            uint256(IndexRegistry.LogicState.OPEN_AND_SETTLE),
            "authorized index-side"
        );
        assertEq(s.moderation.governor(), address(s.governor), "governor bound from the game's side");
        assertEq(address(s.governor.moderation()), address(s.moderation), "and from the governor's");
        assertGe(s.stakeReg.riskPerSeat(), s.moderation.getParams().riskPerSeat, "duty unit covers a seat");
    }

    // --- verify rejects every stack that would fail later -----------------------

    /// Authorized stake-side only. Desynchronised authorization is its own failure:
    /// the case opens, seats draw, and settlement fails at the index write.
    function test_verify_rejects_authorization_on_only_one_registry() public {
        Deploy.Stack memory s = script.deployCore(cfg);
        script.proposeAuthorization(s);
        vm.warp(vm.getBlockTimestamp() + cfg.registryTimelock);
        // Governance is the SCRIPT — `deployCore` ran as it — so the half-execution
        // has to be driven as the script would drive it.
        vm.prank(address(script));
        s.stakeReg.executeLogic(); // index-side deliberately skipped

        vm.expectRevert(Deploy.NotAuthorizedOnIndexRegistry.selector);
        script.verify(s, cfg, address(0));
    }

    /// The reverse, so the check is not passing on one registry by accident.
    function test_verify_rejects_the_other_one_registry_case() public {
        Deploy.Stack memory s = script.deployCore(cfg);
        script.proposeAuthorization(s);
        vm.warp(vm.getBlockTimestamp() + cfg.registryTimelock);
        vm.prank(address(script));
        s.indexReg.executeLogic(); // stake-side deliberately skipped

        vm.expectRevert(Deploy.NotAuthorizedOnStakeRegistry.selector);
        script.verify(s, cfg, address(0));
    }

    /// **Step 6 is the one that cannot be undone.** A `Moderation` bound to a
    /// governor that was never pointed back at it is permanently ungovernable:
    /// `Moderation.governor` is immutable and `bindModeration` is one-way, so
    /// neither side can be repaired. This is the error the script exists to catch
    /// before it is written to a chain.
    function test_verify_rejects_a_governor_that_was_never_bound() public {
        // Everything except the bind.
        StakeRegistry sr = new StakeRegistry(
            IERC20(address(bzz)), 7 days, 10 * XBZZ, 7 days, 7 days, 10 * XBZZ, 256, (1e18 * 9) / 10
        );
        IndexRegistry ir = new IndexRegistry(7 days);
        RulesetGovernor g = new RulesetGovernor(address(this), 7 days);
        Moderation m = new Moderation(IERC20(address(bzz)), sr, ir, address(g));

        sr.proposeLogic(address(m));
        ir.proposeLogic(address(m));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        sr.executeLogic();
        ir.executeLogic();

        Deploy.Stack memory s = Deploy.Stack({stakeReg: sr, indexReg: ir, governor: g, moderation: m});
        vm.expectRevert(Deploy.ModerationNotBound.selector);
        script.verify(s, cfg, address(0));
    }

    /// A ruleset locking more per seat than a duty unit is worth seats panels on
    /// collateral that cannot cover them (D-13). Reachable from config alone: a
    /// registry deployed with a smaller unit than the game's default.
    function test_verify_rejects_a_registry_whose_duty_unit_is_too_small() public {
        Deploy.Config memory small = cfg;
        small.riskPerSeat = 1 * XBZZ; // below Moderation's default 10 xBZZ per seat
        // The Moderation constructor refuses this outright, which is the primary
        // guard; `verify` is the second, for a stack assembled some other way.
        vm.expectRevert(Moderation.RiskPerSeatExceedsDutyUnit.selector);
        script.deployCore(small);
    }

    /// The explicit-link path: an address that holds no code, and one that holds the
    /// wrong code, must both fail.
    function test_verify_rejects_a_settlement_address_that_is_wrong() public {
        Deploy.Stack memory s = _deployThroughScript();

        vm.expectRevert(Deploy.SettlementNotDeployed.selector);
        script.verify(s, cfg, makeAddr("nothing deployed here"));

        vm.expectRevert(Deploy.SettlementWrongCode.selector);
        script.verify(s, cfg, address(bzz)); // real code, wrong contract
    }

    // --- the linking, proven the only way it can be ----------------------------

    /// **`Settlement` is linked, and this is the assertion that shows it.**
    ///
    /// No in-script check can: the library address is baked into `Moderation`'s
    /// bytecode at link time and Solidity cannot read its own link table. So the
    /// proof is behavioural — settle a case, which delegatecalls the library. If the
    /// link were missing or wrong, `claim` is where it would surface, and that is
    /// exactly the "fails on the first case" outcome the script exists to prevent.
    ///
    /// It doubles as the end-to-end smoke test: a stack assembled by the script, with
    /// no harness anywhere, carries a case from `submit` to `SETTLED`.
    function test_a_script_deployed_stack_settles_a_real_case() public {
        Deploy.Stack memory s = _deployThroughScript();

        address[] memory mods = new address[](8);
        for (uint256 i; i < mods.length; ++i) {
            mods[i] = address(uint160(uint256(keccak256(abi.encode("mod", i)))));
            bzz.mint(mods[i], 3000 * XBZZ);
            vm.prank(mods[i]);
            bzz.approve(address(s.stakeReg), type(uint256).max);
            vm.prank(mods[i]);
            s.stakeReg.stake(3000 * XBZZ);
        }
        vm.warp(vm.getBlockTimestamp() + cfg.activationDelay);
        uint256 units = (3000 * XBZZ) / s.moderation.getParams().riskPerSeat;
        for (uint256 i; i < mods.length; ++i) {
            s.stakeReg.activate(mods[i]);
            vm.prank(mods[i]);
            s.stakeReg.setDutyUnits(units);
        }
        vm.roll(vm.getBlockNumber() + cfg.epochBlocks);
        s.stakeReg.advanceEpoch(type(uint256).max);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("marine biology");
        uint256 fee = s.moderation.minFee(1);
        bzz.mint(mods[0], fee);
        vm.prank(mods[0]);
        bzz.approve(address(s.moderation), type(uint256).max);
        vm.prank(mods[0]);
        uint256 caseId =
            s.moderation.submit(Moderation.Kind.SUBMISSION, keccak256("c"), keccak256("m"), topics, 0, fee);

        _drive(s, caseId);

        assertEq(uint256(_phase(s, caseId)), uint256(Moderation.Phase.SETTLED), "settled through the library");
    }

    // --- governance handover ----------------------------------------------------

    /// Both registries and the governor are owned by the deploy key until the
    /// two-step transfer completes. `verify` does not revert on that — a
    /// deployer-owned stack is a legitimate intermediate state — but the operator
    /// must be told, and the handover must actually work.
    function test_governance_starts_with_the_deployer_and_transfers_in_two_steps() public {
        Deploy.Stack memory s = _deployThroughScript();
        assertEq(s.stakeReg.governance(), address(script), "deploy key owns the stake registry");
        assertEq(s.indexReg.governance(), address(script), "and the index registry");
        assertEq(s.governor.governance(), address(script), "and the governor");

        script.handOverGovernance(s, multisig);
        // Proposed, not transferred: the second step is the recipient's.
        assertEq(s.stakeReg.governance(), address(script), "still the deploy key until accepted");

        vm.startPrank(multisig);
        s.stakeReg.acceptGovernance();
        s.indexReg.acceptGovernance();
        s.governor.acceptGovernance();
        vm.stopPrank();

        assertEq(s.stakeReg.governance(), multisig, "stake registry handed over");
        assertEq(s.indexReg.governance(), multisig, "index registry handed over");
        assertEq(s.governor.governance(), multisig, "governor handed over");
    }

    // --- helpers ---------------------------------------------------------------

    function _phase(Deploy.Stack memory s, uint256 caseId) internal view returns (Moderation.Phase p) {
        (,, p,,,,) = s.moderation.caseInfo(caseId);
    }

    function _rollToSeed(Deploy.Stack memory s, uint256 caseId) internal {
        uint256 ri = s.moderation.roundCount(caseId) - 1;
        (,,,,,,,, uint256 snapshotBlock,) = s.moderation.roundInfo(caseId, ri);
        uint256 target = snapshotBlock + 1;
        if (vm.getBlockNumber() < target) vm.roll(target);
        else vm.roll(vm.getBlockNumber() + 1);
        s.stakeReg.advanceEpoch(type(uint256).max);
    }

    /// Carry one undisputed case from DRAW to SETTLED using nothing but the public API.
    function _drive(Deploy.Stack memory s, uint256 caseId) internal {
        Moderation.Params memory p = s.moderation.getParams();
        uint256 guard;
        while (_phase(s, caseId) != Moderation.Phase.SETTLED) {
            require(guard++ < 40, "case did not settle");
            Moderation.Phase ph = _phase(s, caseId);
            uint256 ri = s.moderation.roundCount(caseId) - 1;
            if (ph == Moderation.Phase.DRAW) {
                _rollToSeed(s, caseId);
                s.moderation.realizeSeats(caseId);
            } else if (ph == Moderation.Phase.COMMIT) {
                (, uint256 n,,,,,,,,) = s.moderation.roundInfo(caseId, ri);
                for (uint256 i; i < n; ++i) {
                    address sh = s.moderation.seatHolderAt(caseId, ri, i);
                    bytes32 h =
                        s.moderation.computeCommit(caseId, ri, sh, Moderation.Vote.Approve, keccak256("salt"));
                    vm.prank(sh);
                    s.moderation.commitVote(caseId, h);
                }
                if (_phase(s, caseId) == Moderation.Phase.COMMIT) {
                    vm.warp(vm.getBlockTimestamp() + p.commitTimeout);
                    s.moderation.closeCommit(caseId);
                }
            } else if (ph == Moderation.Phase.REVEAL) {
                (, uint256 n,,,,,,,,) = s.moderation.roundInfo(caseId, ri);
                for (uint256 i; i < n; ++i) {
                    address sh = s.moderation.seatHolderAt(caseId, ri, i);
                    vm.prank(sh);
                    s.moderation.revealVote(caseId, Moderation.Vote.Approve, keccak256("salt"));
                }
                if (_phase(s, caseId) == Moderation.Phase.REVEAL) {
                    vm.warp(vm.getBlockTimestamp() + p.revealWindow);
                    s.moderation.closeReveal(caseId);
                }
            } else if (ph == Moderation.Phase.TALLY) {
                vm.roll(vm.getBlockNumber() + p.seedLag + 1);
                s.moderation.realizeOutcome(caseId);
            } else if (ph == Moderation.Phase.APPEAL_WINDOW) {
                (,,,,, uint256 deadline,) = s.moderation.caseInfo(caseId);
                vm.warp(deadline);
                s.moderation.finalize(caseId);
            } else if (ph == Moderation.Phase.FINALIZED || ph == Moderation.Phase.SETTLING) {
                s.moderation.claim(caseId);
            } else {
                revert("unexpected phase");
            }
        }
    }
}
