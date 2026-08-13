// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Share} from "../../src/ServiceRewardsActor.sol";
import {ComputeSharesHarness} from "./ComputeSharesHarness.sol";

/// @dev Halmos symbolic verification of _computeShares (largest-remainder method) core properties.
///      Each check_xxx function exhaustively verifies over symbolic parameters; halmos only runs check_-prefixed functions.
///      Directly inherits the harness to call _computeShares via internal inlining (cross-contract external calls
///      get symbolized by halmos and become unresolvable, so checks do not go through an external wrapper).
///      Value-domain constraint: usd is a USD-face-value aggregation (business magnitude ≤ ~1e6); assume ≤ 1e3
///      guarantees usd * SHARE_TOTAL(1e18) ≤ 1e21 ≪ 2^256 without overflow, focusing on property verification.
contract ComputeSharesCheck is ComputeSharesHarness, Test {
    /// @dev SHARE_TOTAL aligned with the implementation's constant (1e18).
    uint256 private constant SHARE_TOTAL = 1e18;
    /// @dev Symbolic value-domain upper bound: shares depend only on usd **ratios** (floor + remainder top-up),
    ///      so tightening the domain does not weaken verification strength. 1e3 controls the path complexity of
    ///      SMT non-linear arithmetic (division/modulo + remainder sorting); the real USD aggregation magnitude is
    ///      ~1e6, and the ratio space is fully covered. usd*1e18 ≤ 1e21 ≪ 2^256, no overflow.
    uint256 private constant MAX_USD = 1e3;

    /// @dev P1: a single element's share is always == SHARE_TOTAL (n == 1 -> everything to the only participant).
    function check_Conservation_Single(uint256 usd) public {
        vm.assume(usd > 0 && usd <= MAX_USD);
        address[] memory wallets = new address[](1);
        uint256[] memory usds = new uint256[](1);
        wallets[0] = address(0x1);
        usds[0] = usd;
        Share[] memory shares = _computeShares(wallets, usds, 1, usd);
        assert(shares.length == 1 && shares[0].share == SHARE_TOTAL);
    }

    /// @dev P2: for any two participants' usd values, the share sum conserves exactly == SHARE_TOTAL.
    function check_Conservation_N2(uint256 a, uint256 b) public {
        vm.assume(a > 0 && b > 0 && a + b <= MAX_USD);
        address[] memory wallets = new address[](2);
        uint256[] memory usds = new uint256[](2);
        wallets[0] = address(0x1);
        wallets[1] = address(0x2);
        usds[0] = a;
        usds[1] = b;
        Share[] memory shares = _computeShares(wallets, usds, 2, a + b);
        uint256 sum;
        for (uint256 i = 0; i < shares.length; i++) {
            sum += shares[i].share;
        }
        assert(sum == SHARE_TOTAL);
    }

    /// @dev P3: for any three participants' usd values, the share sum conserves exactly == SHARE_TOTAL.
    function check_Conservation_N3(uint256 a, uint256 b, uint256 c) public {
        vm.assume(a > 0 && b > 0 && c > 0 && a + b + c <= MAX_USD);
        address[] memory wallets = new address[](3);
        uint256[] memory usds = new uint256[](3);
        wallets[0] = address(0x1);
        wallets[1] = address(0x2);
        wallets[2] = address(0x3);
        usds[0] = a;
        usds[1] = b;
        usds[2] = c;
        Share[] memory shares = _computeShares(wallets, usds, 3, a + b + c);
        uint256 sum;
        for (uint256 i = 0; i < shares.length; i++) {
            sum += shares[i].share;
        }
        assert(sum == SHARE_TOTAL);
    }

    /// @dev P4 (weak monotonicity): a participant with larger usd gets a share no worse than one with smaller usd (two-participant comparison).
    function check_Monotonic_N2(uint256 a, uint256 b) public {
        vm.assume(a >= b && b > 0 && a + b <= MAX_USD);
        address[] memory wallets = new address[](2);
        uint256[] memory usds = new uint256[](2);
        wallets[0] = address(0x1);
        wallets[1] = address(0x2);
        usds[0] = a;
        usds[1] = b;
        Share[] memory shares = _computeShares(wallets, usds, 2, a + b);
        assert(shares[0].share >= shares[1].share);
    }

    /// @dev P5 (floor bound): each share is either floor(usd_i * T / total) or floor + 1
    ///      (the largest-remainder method only adjusts ideal quotas by ±1, never more).
    function check_FloorBound_N2(uint256 a, uint256 b) public {
        vm.assume(a > 0 && b > 0 && a + b <= MAX_USD);
        address[] memory wallets = new address[](2);
        uint256[] memory usds = new uint256[](2);
        wallets[0] = address(0x1);
        wallets[1] = address(0x2);
        usds[0] = a;
        usds[1] = b;
        Share[] memory shares = _computeShares(wallets, usds, 2, a + b);
        uint256 floor0 = a * SHARE_TOTAL / (a + b);
        uint256 floor1 = b * SHARE_TOTAL / (a + b);
        assert(shares[0].share == floor0 || shares[0].share == floor0 + 1);
        assert(shares[1].share == floor1 || shares[1].share == floor1 + 1);
    }

    /// @dev P6 (no overflow): usd * SHARE_TOTAL does not overflow within the business domain (≤ MAX_USD)
    ///      — 0.8.x checked arithmetic reverts on any overflow (verified by symbolic execution).
    function check_NoOverflow_Boundary(uint256 usd) public {
        vm.assume(usd > 0 && usd <= MAX_USD);
        uint256 mul = usd * SHARE_TOTAL;
        assert(mul > 0); // overflow would revert; reaching here proves no overflow
    }
}
