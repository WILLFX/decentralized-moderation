"""Regression checks for the production N−4 eligibility threshold.

Run from the project root with:

    python3 -m unittest discover -s simulation -p test_eligibility.py -v

These literal expectations do not need generated Solidity vectors. The vector
checker must still run after Forge emits fresh vectors from the changed contract.
Historical simulations keep their own population policies.
"""

from __future__ import annotations

import unittest

from check_eligibility_vectors import _check_threshold
from eligibility import elig_bits


class EligibilityThresholdTest(unittest.TestCase):
    def test_approved_threshold_at_registry_boundaries(self) -> None:
        # N is floor(log2(S)), clamped to zero for S <= 1. These values pin the
        # point where narrowing begins and both sides of later power-of-two steps.
        expected = {
            0: 0,
            1: 0,
            2: 0,
            15: 0,
            16: 0,
            17: 0,
            31: 0,
            32: 1,
            33: 1,
            63: 1,
            64: 2,
            65: 2,
            100: 2,
            511: 4,
            512: 5,
            1000: 5,
            1023: 5,
            1024: 6,
            65536: 12,
            (1 << 256) - 1: 251,
        }
        for count, bits in expected.items():
            with self.subTest(staked_count=count):
                self.assertEqual(elig_bits(count), bits)

    def test_negative_registry_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            elig_bits(-1)

    def test_vector_checker_accepts_n4_and_rejects_old_n5_threshold(self) -> None:
        self.assertIsNone(_check_threshold({"stakedCount": 1000, "eligBits": 5}))
        problem = _check_threshold({"stakedCount": 1000, "eligBits": 4})
        self.assertIsNotNone(problem)
        self.assertIn("solidity eligBits: 4", problem)
        self.assertIn("python   eligBits: 5", problem)


if __name__ == "__main__":
    unittest.main()
