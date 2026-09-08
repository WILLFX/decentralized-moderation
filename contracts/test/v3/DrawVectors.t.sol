// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Moderation, IIndexRegistry} from "../../src/v3/Moderation.sol";
import {StakeRegistry} from "../../src/v3/StakeRegistry.sol";
import {IndexRegistry} from "../../src/v3/IndexRegistry.sol";
import {MockBZZ} from "../mocks/MockBZZ.sol";

/// @title Draw vectors — the emitting half of the two-implementation differential
///
/// @notice §4.5's ticket derivation, exported for `simulation/v3` to reproduce.
///
/// @dev **Why the closed-form check was not enough.** `DrawProperties.t.sol`
///      compares the empirical approval rate against `f(â) = 3â² − 2â³`. That
///      constrains the RATE and nothing else. A domain-separation mistake — say
///      dropping `caseId` from the preimage — leaves `u` uniform, leaves the rate
///      exactly `f(â)`, passes every statistical test in that file, and makes two
///      different cases share a draw. The rate cannot see it; only re-deriving
///      `u` independently can.
///
///      The vectors are swept, not hand-picked: every tally in a grid crossed
///      with entropies neither side chose. A vector set curated to agree proves
///      that the curator understood both implementations, which is not the claim.
contract DrawVectorsTest is Test {
    MockBZZ internal token;
    StakeRegistry internal reg;
    IndexRegistry internal idx;
    Moderation internal mod;

    address internal gov;

    uint256 internal constant UNIT = 1e16;
    uint256 internal constant TIMELOCK = 2 days;

    function setUp() public {
        gov = makeAddr("gov");
        token = new MockBZZ();
        vm.prank(gov);
        reg = new StakeRegistry(IERC20(address(token)), 10 * UNIT, 5 * UNIT, 3 days, 7 days, TIMELOCK, 0.5e18);
        vm.prank(gov);
        idx = new IndexRegistry(TIMELOCK);
        mod = new Moderation(IERC20(address(token)), reg, IIndexRegistry(address(idx)), gov);
    }

    /// @dev Writes `test/vectors/draw_vectors.json`. Run with
    ///      `forge test --match-test test_emitDrawVectors`, then
    ///      `python3 simulation/v3/check_draw_vectors.py`.
    function test_emitDrawVectors() public {
        // A grid, not a selection. Tallies span the tie, both lopsided ends, and
        // the small-N region where â moves fastest.
        uint32[10] memory approves = [uint32(0), 1, 1, 2, 3, 5, 8, 13, 20, 40];
        uint32[10] memory rejects = [uint32(1), 0, 1, 5, 3, 2, 13, 8, 1, 40];

        string memory out = "[";
        bool first = true;

        for (uint256 t; t < approves.length; ++t) {
            for (uint256 e; e < 12; ++e) {
                bytes32 entropy = keccak256(abi.encode("vector", t, e));
                uint256 caseId = 1 + t * 12 + e;

                (uint8 verdict, uint8 tickets) = _decideAt(caseId, entropy, approves[t], rejects[t]);

                string memory row = string.concat(
                    first ? "" : ",",
                    '{"caseId":',
                    vm.toString(caseId),
                    ',"entropy":"',
                    vm.toString(entropy),
                    '","approve":',
                    vm.toString(uint256(approves[t])),
                    ',"reject":',
                    vm.toString(uint256(rejects[t])),
                    ',"u":["',
                    vm.toString(_u(caseId, 0, entropy)),
                    '","',
                    vm.toString(_u(caseId, 1, entropy)),
                    '","',
                    vm.toString(_u(caseId, 2, entropy)),
                    '"],"tickets":',
                    vm.toString(uint256(tickets)),
                    ',"verdict":',
                    vm.toString(uint256(verdict)),
                    "}"
                );
                out = string.concat(out, row);
                first = false;
            }
        }

        out = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"contract":"',
            vm.toString(address(mod)),
            '","vectors":',
            out,
            "]}"
        );
        vm.writeFile("test/vectors/draw_vectors.json", out);
    }

    /// @dev The contract's own `_decide`, reached by writing the tally into the
    ///      case and calling the real `decideAt`. Nothing here reimplements the
    ///      draw — that is the whole point.
    function _decideAt(uint256 caseId, bytes32 entropy, uint32 approve, uint32 reject)
        internal
        returns (uint8 verdict, uint8 tickets)
    {
        _setTally(caseId, approve, reject);
        return mod.decideAt(caseId, entropy);
    }

    /// @dev `u_i` as the contract computes it, recomputed here from the SAME
    ///      constants rather than read out — `_decide` does not expose it. This is
    ///      the one place the Solidity side is restated, and it is restated in
    ///      Solidity against `Moderation`'s own live address and chainid, so a
    ///      disagreement with Python is a disagreement about the SPEC, not about
    ///      which contract instance was hashed.
    function _u(uint256 caseId, uint256 i, bytes32 entropy) internal view returns (uint256) {
        return uint128(
            uint256(
                keccak256(
                    abi.encode(keccak256("v3.outcome"), block.chainid, address(mod), caseId, i, entropy)
                )
            )
        );
    }

    /// @dev Writes `pooledApprove` / `pooledReject` directly. Slot 3 of the case,
    ///      offsets 96 and 128 — the same write `DrawProperties.t.sol` makes, and
    ///      it asserts the write landed so a storage reorder fails loudly rather
    ///      than silently producing vectors for a tally of zero.
    function _setTally(uint256 caseId, uint32 approve, uint32 reject) internal {
        bytes32 base = keccak256(abi.encode(caseId, uint256(3)));
        bytes32 slot = bytes32(uint256(base) + 3);
        uint256 w = uint256(vm.load(address(mod), slot));
        uint256 mask = ~((uint256(type(uint32).max) << 96) | (uint256(type(uint32).max) << 128));
        w = (w & mask) | (uint256(approve) << 96) | (uint256(reject) << 128);
        vm.store(address(mod), slot, bytes32(w));

        Moderation.Case memory c = mod.caseInfo(caseId);
        assertEq(c.pooledApprove, approve, "fixture: pooledApprove not where expected");
        assertEq(c.pooledReject, reject, "fixture: pooledReject not where expected");
    }
}
