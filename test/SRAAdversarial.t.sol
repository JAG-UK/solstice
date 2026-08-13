// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// Adversarial input matrix for the external write surface (S1, QA system fix)
//
// Background: the V1/V2/V3 overflow audit (docs/sra-design.md §4.3.10) exposed a
// structural QA gap — every verification layer (deterministic/fuzz/invariant/
// differential) exercised inputs inside the "business domain" and none probed
// malicious extreme inputs. This suite is the adversarial layer (S1): for each
// external write function it enumerates the boundary values of every numeric /
// address / array parameter and asserts the exact revert (or acceptance) —
// locking the code-enforced input domain as executable behavior.
//
// Principles:
//   * every revert assertion uses an exact error selector (no bare expectRevert)
//   * existing coverage is NOT duplicated: V1/V2/V3 max-value rejects live in
//     SRAOverflowDoS.t.sol; B1 minLot upper bound in SRAQuarter; C1/F2 array
//     length bounds in SRARegistry/SRAGovernance; E1/E2 in SRAGovernance.
//     This file adds: q-parameter window boundaries, fpv exact-limit accept /
//     limit+1 reject, zero-address probes, setPricingParams full boundary grid,
//     empty-array semantics, and the multi-orchestrator aggregate bound.
// ============================================================================

import {Share} from "../src/lib/FVMRewardTypes.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Pair, PricePeriod} from "../src/lib/SraTypes.sol";
import {IsASafe} from "../src/lib/IsASafe.sol";
import {SRATestBase} from "./SRATestBase.sol";

contract SRAAdversarial is SRATestBase {
    // ------------------------------------------------------------------------
    // 1. q-parameter window boundaries (exact selectors)
    // ------------------------------------------------------------------------

    /// q = a future quarter: posting window not yet open -> NotInPostingWindow(q).
    function test_PostVolume_FutureQuarter_NotInPostingWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // inside Q0's posting window
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInPostingWindow.selector, uint64(10)));
        sra.postVolume(10, _fpv(100e18));
    }

    /// q = uint64.max: with the default EPOCHS_PER_QUARTER(1000), uint64.max × 1000 still fits in the
    /// current uint96 Epoch width, so the _qEnd range guard does NOT fire; the wrapped epoch is huge
    /// and nowE < e -> NotInPostingWindow(q). (A dedicated guard test with a huge EPOCHS_PER_QUARTER
    /// simulates the upstream uint64 narrowing — see test_FinalizeConversion_MaxQuarter_RangeGuard.)
    function test_PostVolume_MaxQuarter_NotInPostingWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInPostingWindow.selector, type(uint64).max));
        sra.postVolume(type(uint64).max, _fpv(100e18));
    }

    /// correctVolume on a future quarter: verification window not open -> NotInVerificationWindow(q)
    /// (unanimousNoHold: the second approval executes the body and reverts).
    function test_CorrectVolume_FutureQuarter_NotInVerificationWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qVerifyEnd(0)); // inside Q0's verification window
        vm.prank(owner1);
        sra.correctVolume(orch, 10, _fpv(100e18));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInVerificationWindow.selector, uint64(10)));
        sra.correctVolume(orch, 10, _fpv(100e18));
    }

    /// q = uint64.max on correctVolume -> NotInVerificationWindow(q) (same reasoning as above: guard does not fire at uint96 width).
    function test_CorrectVolume_MaxQuarter_NotInVerificationWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qVerifyEnd(0));
        vm.prank(owner1);
        sra.correctVolume(orch, type(uint64).max, _fpv(100e18));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInVerificationWindow.selector, type(uint64).max));
        sra.correctVolume(orch, type(uint64).max, _fpv(100e18));
    }

    /// finalizeConversion on a future quarter (before its binding) -> NotBound(q).
    function test_FinalizeConversion_FutureQuarter_NotBound() public {
        vm.roll(_qVerifyEnd(0) + 1); // Q0 binding complete
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, uint64(10)));
        sra.finalizeConversion(10);
    }

    /// q = uint64.max on finalizeConversion -> NotBound(q) (guard does not fire at uint96 width).
    function test_FinalizeConversion_MaxQuarter_NotBound() public {
        vm.roll(_qVerifyEnd(0) + 1);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, type(uint64).max));
        sra.finalizeConversion(type(uint64).max);
    }

    /// q = uint64.max on submitShares -> NotBound(q) (its own first-line require).
    function test_SubmitShares_MaxQuarter_NotBound() public {
        vm.roll(_qVerifyEnd(0) + 1);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, type(uint64).max));
        sra.submitShares(type(uint64).max);
    }

    /// The _qEnd range guard itself: with EPOCHS_PER_QUARTER = 2^40, uint64.max × 2^40 ≈ 2^104
    /// exceeds the uint96 Epoch width -> end beyond type(uint96).max -> InvalidParameter.
    /// This simulates the upstream Epoch narrowing (uint96 -> uint64): once Epoch is uint64,
    /// even the default Q × 1000 overflows 2^64, so this guard (with its threshold bumped to
    /// type(uint64).max) becomes the rejection path — the four MaxQuarter tests above then flip
    /// from the window errors to InvalidParameter (see the sync note in ServiceRewardsActor._qEnd).
    function test_FinalizeConversion_MaxQuarter_RangeGuard_InvalidParameter() public {
        // finalizeConversion needs no admitted orchestrator; only the window check runs.
        ServiceRewardsActor big = new ServiceRewardsActor(
            owner1,
            owner2,
            1 << 40, // EPOCHS_PER_QUARTER: uint64.max × 2^40 ≈ 2^104 > 2^96
            POST_PERIOD,
            VERIFICATION_WINDOW,
            SRA_CANCEL_HOLD,
            ACTIVATION_EPOCH,
            MIN_LOT,
            PRICE_BAND,
            MAX_PRICE_PERIODS
        );
        vm.roll(1);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        big.finalizeConversion(type(uint64).max);
    }

    // ------------------------------------------------------------------------
    // 2. FPV field exact-limit boundaries (accept at limit / reject limit+1)
    //    Q0 cold start (no anchor) isolates _validateFpvBounds from the band check.
    // ------------------------------------------------------------------------

    /// stableUSD == MAX_STABLE_USD(1e30) is accepted (domain boundary).
    function test_Fpv_StableUsd_AtMax_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(1e30));
        assertEq(sra.fpvOf(0, orch).stableUSD, 1e30);
    }

    /// stableUSD == MAX_STABLE_USD + 1 is rejected with InvalidParameter.
    function test_Fpv_StableUsd_OverMax_Rejected() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(0, _fpv(1e30 + 1));
    }

    /// lotUsd == MAX_LOT_USD(1e30) is accepted (cold start: band check returns).
    function test_Fpv_LotUsd_AtMax_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), 1e30, 1, 1e18);
        _postAs(orch, 0, _fpvWithPeriods(0, ps));
        assertEq(sra.fpvOf(0, orch).filPeriods[0].lotUsd, 1e30);
    }

    /// lotUsd == MAX_LOT_USD + 1 is rejected with InvalidParameter.
    function test_Fpv_LotUsd_OverMax_Rejected() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), 1e30 + 1, 1, 1e18);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(0, _fpvWithPeriods(0, ps));
    }

    /// claimFil == MAX_CLAIM_FIL(1e30) is accepted (lotUsd = MIN_LOT keeps it a qualifying print).
    function test_Fpv_ClaimFil_AtMax_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), MIN_LOT, 1e30, 1e18);
        _postAs(orch, 0, _fpvWithPeriods(0, ps));
        assertEq(sra.fpvOf(0, orch).filPeriods[0].claimFil, 1e30);
    }

    /// claimFil == MAX_CLAIM_FIL + 1 is rejected with InvalidParameter.
    function test_Fpv_ClaimFil_OverMax_Rejected() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), MIN_LOT, 1e30 + 1, 1e18);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(0, _fpvWithPeriods(0, ps));
    }

    /// attoFil == MAX_ATTO_FIL(1e27 = 1e9 FIL) is accepted.
    function test_Fpv_AttoFil_AtMax_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), MIN_LOT, 1, 1e27);
        _postAs(orch, 0, _fpvWithPeriods(0, ps));
        assertEq(sra.fpvOf(0, orch).filPeriods[0].attoFil, 1e27);
    }

    /// attoFil == MAX_ATTO_FIL + 1 is rejected with InvalidParameter.
    function test_Fpv_AttoFil_OverMax_Rejected() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), MIN_LOT, 1, 1e27 + 1);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(0, _fpvWithPeriods(0, ps));
    }

    // ------------------------------------------------------------------------
    // 3. Zero-address probes (address-parameter adversarial cases)
    // ------------------------------------------------------------------------

    /// Governance may admit the zero address (no zero-address guard in admit);
    /// it becomes an admitted orchestrator that can never post (no caller can be 0).
    function test_Admit_ZeroAddress_Accepted() public {
        vm.prank(owner1);
        sra.admit(address(0));
        vm.prank(owner2);
        sra.admit(address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(address(0));
        assertTrue(sra.isAdmitted(address(0)));
    }

    /// freeze(0) on a never-admitted zero address -> NotAdmitted(0) at body execution.
    function test_Freeze_ZeroAddress_NotAdmitted() public {
        vm.prank(owner1);
        sra.freeze(address(0));
        vm.prank(owner2);
        sra.freeze(address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotAdmitted.selector, address(0)));
        sra.freeze(address(0));
    }

    /// A zero payer address is a legal binding pair (pairId = keccak(0, operator));
    /// no zero-address guard exists — the behavior is locked as accepted.
    function test_RegisterPairs_ZeroPayer_Accepted() public {
        address orch = makeAddr("orch");
        address operator = makeAddr("op");
        _admit(orch);

        Pair[] memory pairs = new Pair[](1);
        pairs[0] = Pair({payer: address(0), operator: operator});
        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(address(0), operator), orch);
    }

    /// replaceOwner with the zero address as newOwner -> NotSafeProxy(0) (EXTCODESIZE(0) = 0 <= 56).
    function test_ReplaceOwner_ZeroNewOwner_NotSafeProxy() public {
        vm.prank(owner1);
        sra.replaceOwner(owner1, address(0));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(IsASafe.NotSafeProxy.selector, address(0)));
        sra.replaceOwner(owner1, address(0));
    }

    /// reassignBinding to the zero address -> NotAdmitted(0) at body execution.
    function test_ReassignBinding_ZeroTarget_NotAdmitted() public {
        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        vm.prank(owner1);
        sra.reassignBinding(payer, operator, address(0));
        vm.prank(owner2);
        sra.reassignBinding(payer, operator, address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotAdmitted.selector, address(0)));
        sra.reassignBinding(payer, operator, address(0));
    }

    // ------------------------------------------------------------------------
    // 4. setPricingParams full parameter boundary grid
    //    (B1 already covers minLot = MAX_LOT_USD + 1 rejection; this adds the
    //     remaining accept edges of each parameter)
    // ------------------------------------------------------------------------

    function _setPricingParams(uint256 minLot, uint256 priceBand, uint256 maxPricePeriods) internal {
        vm.prank(owner1);
        sra.setPricingParams(minLot, priceBand, maxPricePeriods);
        vm.prank(owner2);
        sra.setPricingParams(minLot, priceBand, maxPricePeriods);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setPricingParams(minLot, priceBand, maxPricePeriods);
    }

    /// priceBand = 0 (tightest band) is a valid parameter — accepted.
    function test_SetPricingParams_PriceBandZero_Accepted() public {
        _setPricingParams(MIN_LOT, 0, MAX_PRICE_PERIODS);
        (uint256 minLot, uint256 priceBand,) = sra.getPricingParams();
        assertEq(minLot, MIN_LOT);
        assertEq(priceBand, 0);
    }

    /// priceBand = BASIS_POINTS (100%) is a valid parameter — accepted.
    function test_SetPricingParams_PriceBandFull_Accepted() public {
        _setPricingParams(MIN_LOT, 10_000, MAX_PRICE_PERIODS);
        (, uint256 priceBand,) = sra.getPricingParams();
        assertEq(priceBand, 10_000);
    }

    /// maxPricePeriods = 1 (smallest > 0) is accepted.
    function test_SetPricingParams_MaxPeriodsOne_Accepted() public {
        _setPricingParams(MIN_LOT, PRICE_BAND, 1);
        (,, uint256 maxPeriods) = sra.getPricingParams();
        assertEq(maxPeriods, 1);
    }

    /// minLot = MAX_LOT_USD (largest allowed) is accepted.
    function test_SetPricingParams_MinLotAtMax_Accepted() public {
        _setPricingParams(1e30, PRICE_BAND, MAX_PRICE_PERIODS);
        (uint256 minLot,,) = sra.getPricingParams();
        assertEq(minLot, 1e30);
    }

    /// minLot = 0 (no floor) is accepted.
    function test_SetPricingParams_MinLotZero_Accepted() public {
        _setPricingParams(0, PRICE_BAND, MAX_PRICE_PERIODS);
        (uint256 minLot,,) = sra.getPricingParams();
        assertEq(minLot, 0);
    }

    // ------------------------------------------------------------------------
    // 5. Array-parameter edges (empty arrays)
    //    (C1/F2 already cover the over-long side; the empty side locks the
    //     no-op / clear semantics)
    // ------------------------------------------------------------------------

    /// registerPairs with an empty array is a no-op and succeeds.
    function test_RegisterPairs_EmptyArray_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Pair[] memory empty = new Pair[](0);
        _registerPairsAs(orch, empty);
        assertEq(sra.admittedCount(), 1); // state unchanged
    }

    /// setAdmittedLists with two empty arrays clears both allowlists (exclusive-update semantics).
    function test_SetAdmittedLists_EmptyArrays_ClearAllowlists() public {
        address token = makeAddr("usdc");
        address payContract = makeAddr("pay");

        // populate
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory payContracts = new address[](1);
        payContracts[0] = payContract;
        vm.prank(owner1);
        sra.setAdmittedLists(tokens, payContracts);
        vm.prank(owner2);
        sra.setAdmittedLists(tokens, payContracts);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setAdmittedLists(tokens, payContracts);
        assertTrue(sra.isStablecoinAdmitted(token));

        // clear with empty arrays (the Filecoin Pay side has no public query;
        // the stablecoin side is observable and the two clears share one path)
        address[] memory empty = new address[](0);
        vm.prank(owner1);
        sra.setAdmittedLists(empty, empty);
        vm.prank(owner2);
        sra.setAdmittedLists(empty, empty);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setAdmittedLists(empty, empty);
        assertFalse(sra.isStablecoinAdmitted(token));
    }

    // ------------------------------------------------------------------------
    // 6. Multi-orchestrator aggregate boundary
    // ------------------------------------------------------------------------

    /// Two orchestrators each posting MAX_STABLE_USD: total = 2e30 stays far below
    /// 2^256 and _computeShares' usds[i] * 1e18 = 1e48 does not overflow — shares
    /// still sum to exactly 1e18 (multi-party V3 variant stays safe).
    function test_MultiOrchestrator_AtMaxStableUsd_ConservesShares() public {
        address a = makeAddr("agg-a");
        address b = makeAddr("agg-b");
        _admit(a);
        _admit(b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(1e30));
        _postAs(b, 0, _fpv(1e30));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += shares[i].share;
        }
    }
}
