// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// SRA quarter state machine + FPV + FIL pricing tests
//   Covers design §3 strategies 2 (window boundaries) / 7 (CorrectVolume) / 8 (PRICE_BAND)
//   9 (FinalizeConversion) / 11 (AggregatedFPV)
//
// Time model: Epoch = block.number; windows (design §2.5.1):
//   posting:      E < now <= E+POST
//   verification: E+POST < now <= E+POST+VERIFY
//   post-binding: now > E+POST+VERIFY
// PRICE_BAND reference: the last bound qualifying print (anchor, updated at quarter binding); cold start (no reference) accepts.
// ============================================================================

import {SRATestBase} from "./SRATestBase.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {PricePeriod, FPV} from "../src/lib/SraTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";

contract SRAQuarterTest is SRATestBase {
    // ------------------------------------------------------------------------
    // Strategy 2: postVolume window boundaries
    // ------------------------------------------------------------------------

    /// Strategy 2: posting within the window (E < now <= E+POST) succeeds.
    function test_PostVolume_PostingWindow_Success() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // E+1
        _postAs(orch, 0, _fpv(100e18));
        FPV memory f = sra.fpvOf(0, orch);
        assertEq(f.stableUSD, 100e18);
    }

    /// Strategy 2: E itself is not in the posting window (E < now, strictly less).
    function test_PostVolume_AtQuarterEnd_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0)); // now == E: posting not yet open
        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, _fpv(100e18));
    }

    /// Strategy 2: the posting window's right boundary is inclusive of E+POST (<=).
    function test_PostVolume_AtPostEnd_Inclusive() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0)); // now == E+POST: allowed
        _postAs(orch, 0, _fpv(100e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 100e18);
    }

    /// Strategy 2: E+POST+1 enters verification; posting is rejected.
    function test_PostVolume_AfterPostingWindow_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, _fpv(100e18));
    }

    /// Strategy 2: at most once per quarter — the second posting reverts (posted flag).
    function test_PostVolume_SecondPosting_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, _fpv(200e18));
    }

    // ------------------------------------------------------------------------
    // Strategy 7: CorrectVolume (within the verification window)
    // ------------------------------------------------------------------------

    /// Strategy 7: an upward correction within the verification window succeeds.
    function test_CorrectVolume_VerificationWindow_Upward() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        _correctVolume(orch, 0, _fpv(250e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 250e18);
    }

    /// Strategy 7: bidirectional correction — downward succeeds.
    function test_CorrectVolume_Downward_Corrects() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1);
        _correctVolume(orch, 0, _fpv(40e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 40e18);
    }

    /// Strategy 7: multiple corrections within the window; the last one wins (whole replacement).
    function test_CorrectVolume_MultipleCorrections_LastWins() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1);
        _correctVolume(orch, 0, _fpv(200e18));
        _correctVolume(orch, 0, _fpv(300e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 300e18);
    }

    /// Strategy 7: an unposted orchestrator can be backfilled within the verification window (posted=false -> written).
    function test_CorrectVolume_BackfillUnposted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0) + 1); // unposted, straight into verification
        _correctVolume(orch, 0, _fpv(150e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 150e18);
        assertTrue(sra.fpvOf(0, orch).posted);
    }

    /// Strategy 7: the verification window's right boundary is inclusive of E+POST+VERIFY.
    function test_CorrectVolume_AtVerifyEnd_Inclusive() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // E+1: post within the posting window (E, E+POST]
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0)); // now == E+POST+VERIFY: allowed
        _correctVolume(orch, 0, _fpv(200e18));
        assertEq(sra.fpvOf(0, orch).stableUSD, 200e18);
    }

    /// Strategy 7: after the window closes (E+POST+VERIFY+1) CorrectVolume is rejected (value bound).
    function test_CorrectVolume_AfterVerificationWindow_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        vm.prank(owner1);
        sra.correctVolume(orch, 0, _fpv(200e18));
        vm.prank(owner2);
        vm.expectRevert(); // window closed
        sra.correctVolume(orch, 0, _fpv(200e18));
    }

    // ------------------------------------------------------------------------
    // Strategy 8: PRICE_BAND (validated at postVolume posting)
    // ------------------------------------------------------------------------

    /// Strategy 8: cold start (the system never had a qualifying print) — the first print is accepted.
    function test_PostVolume_PriceBand_ColdStartAccepts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory periods = new PricePeriod[](1);
        periods[0] = _period(5000, 1000, 1, 0.5e18); // rate 1000 USD/FIL, first print
        _postAs(orch, 0, _fpvWithPeriods(100e18, periods));
        assertEq(sra.fpvOf(0, orch).filPeriods.length, 1);
    }

    /// Strategy 8: a print deviating beyond band from the last bound qualifying print is rejected (cross-quarter anchored reference).
    function test_PostVolume_PriceBandExceeded_Reverts() public {
        // Quarter 0: orchestrator A posts print rate 1000 (cold start accepts, anchor = 1000)
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        // Quarter 1: orchestrator B posts print rate 1500 (deviation 50% vs 1000 > band 20% -> rejected)
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1500, 1, 0.5e18);
        vm.prank(orchB);
        vm.expectRevert();
        sra.postVolume(1, _fpvWithPeriods(100e18, p2));
    }

    /// Strategy 8: within-band deviation (<=20%) accepts.
    function test_PostVolume_PriceBand_WithinBand_Accepts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18); // rate 1000
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1100, 1, 0.5e18); // rate 1100 (+10% <= 20% -> accepted)
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));
        assertEq(sra.fpvOf(1, orchB).filPeriods.length, 1);
    }

    /// Strategy 8/10: an over-limit print within the same posting is rejected; filPeriods beyond MAX rejected.
    function test_PostVolume_TooManyPricePeriods_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);

        PricePeriod[] memory periods = new PricePeriod[](MAX_PRICE_PERIODS + 1);
        for (uint256 i = 0; i < periods.length; i++) {
            periods[i] = _period(uint64(5000 + i), 1000, 1, 1e18);
        }
        vm.prank(orch);
        vm.expectRevert(); // filPeriods.length > MAX_PRICE_PERIODS -> rejected
        sra.postVolume(0, _fpvWithPeriods(100e18, periods));
    }

    // ------------------------------------------------------------------------
    // Strategy 8 exact boundaries (G3): band exactly ±2000bps boundary-inclusive; 1bps over rejected
    //   _checkPriceBand uses lhs >= lower && lhs <= upper (boundary-inclusive) —
    //   exactly-band deviation accepts; band+1bps deviation rejects (G3 closure)
    // ------------------------------------------------------------------------

    /// Strategy 8/G3: deviation exactly +band (+2000bps, rate 1200 vs reference 1000) -> accepted (<= upper).
    function test_PostVolume_PriceBand_ExactlyPlusBand_Accepts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18); // reference = 1000 USD/FIL
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1200, 1, 0.5e18); // rate 1200 = reference +20% exactly = band upper
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));
        assertEq(sra.fpvOf(1, orchB).filPeriods.length, 1);
    }

    /// Strategy 8/G3: deviation exactly -band (-2000bps, rate 800 vs reference 1000) -> accepted (>= lower).
    function test_PostVolume_PriceBand_ExactlyMinusBand_Accepts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18); // reference = 1000
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 800, 1, 0.5e18); // rate 800 = reference -20% exactly = band lower
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));
        assertEq(sra.fpvOf(1, orchB).filPeriods.length, 1);
    }

    /// Strategy 8/G3: deviation +band+1bps (+2001bps, rate 1201) -> rejected (> upper).
    function test_PostVolume_PriceBand_JustOverBand_Reverts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18); // reference = 1000
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1201, 1, 0.5e18); // rate 1201 = +20.1% > band 20% -> rejected
        vm.prank(orchB);
        vm.expectRevert();
        sra.postVolume(1, _fpvWithPeriods(100e18, p2));
    }

    /// Strategy 8/G3: deviation -band-1bps (-2001bps, rate 799) -> rejected (< lower).
    function test_PostVolume_PriceBand_JustUnderBand_Reverts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18); // reference = 1000
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 799, 1, 0.5e18); // rate 799 = -20.1% < band 20% -> rejected
        vm.prank(orchB);
        vm.expectRevert();
        sra.postVolume(1, _fpvWithPeriods(100e18, p2));
    }

    // ------------------------------------------------------------------------
    // Strategy 8/10 exact boundary (G4): exactly MAX_PRICE_PERIODS (32) accepted (<=)
    // ------------------------------------------------------------------------

    /// Strategy 8/10/G4: filPeriods.length exactly == MAX_PRICE_PERIODS (32) -> accepted.
    /// The 33-rejection is already covered by test_PostVolume_TooManyPricePeriods_Reverts.
    function test_PostVolume_MaxPricePeriods_ExactlyAccepted() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);

        PricePeriod[] memory periods = new PricePeriod[](MAX_PRICE_PERIODS);
        for (uint256 i = 0; i < periods.length; i++) {
            // same rate 1000: cold start's first print establishes the anchor; the rest at the same price are within band -> all pass
            periods[i] = _period(uint64(5000 + i), 1000, 1, 1e18);
        }
        _postAs(orch, 0, _fpvWithPeriods(100e18, periods));
        assertEq(sra.fpvOf(0, orch).filPeriods.length, MAX_PRICE_PERIODS);
    }

    // ------------------------------------------------------------------------
    // Strategy 9: FinalizeConversion (post-binding, idempotent, integer precision)
    // ------------------------------------------------------------------------

    /// Strategy 9: finalizeConversion after binding completes the FIL→USD conversion and accumulates stableUSD.
    function test_FinalizeConversion_AfterBinding_Success() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory periods = new PricePeriod[](1);
        periods[0] = _period(5000, 1000, 1, 0.5e18); // rate 1000 USD/FIL
        _postAs(orch, 0, _fpvWithPeriods(200e18, periods));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        sra.finalizeConversion(0);

        assertTrue(sra.isFinalized(0));
        // usdValue = stableUSD + attoFil * lotUsd / claimFil = 200e18 + 0.5e18 * 1000 / 1 = 700e18
        assertEq(sra.fpvOf(0, orch).usdValue, 700e18);
    }

    /// Strategy 9: finalizeConversion is idempotent — a second call has no side effects (no re-accumulation).
    function test_FinalizeConversion_Idempotent() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory periods = new PricePeriod[](1);
        periods[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orch, 0, _fpvWithPeriods(200e18, periods));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0);
        uint256 first = sra.fpvOf(0, orch).usdValue;

        sra.finalizeConversion(0); // second call
        assertEq(sra.fpvOf(0, orch).usdValue, first);
    }

    /// Strategy 9: integer precision — attoFil × lotUsd / claimFil uses integer arithmetic, no floating-point rounding.
    function test_FinalizeConversion_IntegerPrecision() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        // rate = 1000/3 ≈ 333.33 USD/FIL (not divisible)
        PricePeriod[] memory periods = new PricePeriod[](1);
        periods[0] = _period(5000, 1000, 3, 1e18); // 1 FIL × 1000 / 3 = 333.333...e18
        _postAs(orch, 0, _fpvWithPeriods(0, periods));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0);

        // integer arithmetic: floor(1e18 * 1000 / 3) = 333333333333333333333
        assertEq(sra.fpvOf(0, orch).usdValue, 333_333_333_333_333_333_333);
    }

    /// Strategy 9: before binding (window not closed) finalizeConversion is rejected.
    function test_FinalizeConversion_BeforeBinding_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0)); // not yet bound (verification right boundary inclusive)
        vm.expectRevert();
        sra.finalizeConversion(0);
    }

    // ------------------------------------------------------------------------
    // Strategy 11: AggregatedFPV (read-only bound value)
    // ------------------------------------------------------------------------

    /// Strategy 11: aggregatedFPV returns 0 before the window closes (never reads unbound posted values).
    function test_AggregatedFPV_BeforeBinding_Zero() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        // 0 during posting/verification (not bound)
        assertEq(sra.aggregatedFPV(0), 0);
        vm.roll(_qVerifyEnd(0));
        assertEq(sra.aggregatedFPV(0), 0);
    }

    /// Strategy 11: after binding aggregatedFPV = Σ each orchestrator's usdValue (read auto-triggers finalize, aligned with spec §3.2/§4.1/§4.2).
    /// Note: reading aggregatedFPV auto-triggers the idempotent finalizeConversion — a pure-stablecoin FPV has no FIL
    /// periods, so after the trigger usdValue == stableUSD; FIL components are converted on the trigger (same path as submitShares).
    function test_AggregatedFPV_AfterBinding_SumOfValues() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));
        _postAs(orchB, 0, _fpv(250e18));

        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(sra.aggregatedFPV(0), 350e18);
    }

    /// Strategy 11: a frozen orchestrator's (frozen at the E+POST instant) FPV is excluded from the aggregate.
    function test_AggregatedFPV_FrozenExcluded() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));
        _postAs(orchB, 0, _fpv(250e18));

        // freeze B during posting (affects the quarter: B frozen at the E+POST instant)
        _freeze(orchB);

        vm.roll(_qVerifyEnd(0) + 1);
        // B excluded: the aggregate contains only A (read auto-triggers finalize; pure stableUSD usdValue == stableUSD)
        assertEq(sra.aggregatedFPV(0), 100e18);
    }

    // ------------------------------------------------------------------------
    // Strategy 8 parameter management (G1): setPricingParams / getPricingParams
    //   Governance: unanimous + hold (two votes + permissionless body execution after hold elapses)
    // ------------------------------------------------------------------------

    /// G1: governance updates the three params minLot/priceBand/maxPricePeriods; getPricingParams returns the new values.
    function test_SetPricingParams_UpdatesParams_GetReturns() public {
        vm.prank(owner1);
        sra.setPricingParams(2e18, 1500, 16);
        vm.prank(owner2);
        sra.setPricingParams(2e18, 1500, 16);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setPricingParams(2e18, 1500, 16); // third call: permissionless execution

        (uint256 minLot, uint256 priceBand, uint256 maxPricePeriods) = sra.getPricingParams();
        assertEq(minLot, 2e18);
        assertEq(priceBand, 1500); // 15%
        assertEq(maxPricePeriods, 16);
    }

    /// G1: a non-owner (third party) calling setPricingParams -> rejected on the first vote (NotOwner).
    function test_SetPricingParams_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        sra.setPricingParams(2e18, 1500, 16);
    }

    /// G1: invalid params (maxPricePeriods=0 / priceBand > 10000) -> InvalidParameter at the third body execution.
    function test_SetPricingParams_InvalidParams_Reverts() public {
        // maxPricePeriods = 0 is invalid
        vm.prank(owner1);
        sra.setPricingParams(MIN_LOT, PRICE_BAND, 0);
        vm.prank(owner2);
        sra.setPricingParams(MIN_LOT, PRICE_BAND, 0);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert();
        sra.setPricingParams(MIN_LOT, PRICE_BAND, 0);

        // priceBand > BASIS_POINTS(10000) is invalid
        vm.prank(owner1);
        sra.setPricingParams(MIN_LOT, 10001, MAX_PRICE_PERIODS);
        vm.prank(owner2);
        sra.setPricingParams(MIN_LOT, 10001, MAX_PRICE_PERIODS);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert();
        sra.setPricingParams(MIN_LOT, 10001, MAX_PRICE_PERIODS);
    }

    /// B1: setPricingParams with minLot above MAX_LOT_USD reverts InvalidParameter at body execution
    ///     (prevents silent FIL-pricing loss: minLot=max would skip every print with lotUsd <= MAX_LOT_USD).
    function test_SetPricingParams_MinLotTooLarge_Reverts() public {
        vm.prank(owner1);
        sra.setPricingParams(1e30 + 1, PRICE_BAND, MAX_PRICE_PERIODS);
        vm.prank(owner2);
        sra.setPricingParams(1e30 + 1, PRICE_BAND, MAX_PRICE_PERIODS);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.setPricingParams(1e30 + 1, PRICE_BAND, MAX_PRICE_PERIODS);
    }

    /// G1: the new priceBand applies to subsequent prints — a +20% deviation accepted under the old band ±20%
    ///      is rejected after the band changes to ±10% (reference 1000 unchanged; control is G3 ExactlyPlusBand).
    function test_SetPricingParams_NewBand_AppliesToNewPrints() public {
        // Reference: quarter 0 posts rate 1000 (cold start accepts)
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = quarter 0's last qualifying print (deviation D aligned: reference updates at quarter binding)

        // Governance updates priceBand = 1000 (±10%)
        vm.prank(owner1);
        sra.setPricingParams(MIN_LOT, 1000, MAX_PRICE_PERIODS);
        vm.prank(owner2);
        sra.setPricingParams(MIN_LOT, 1000, MAX_PRICE_PERIODS);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setPricingParams(MIN_LOT, 1000, MAX_PRICE_PERIODS);
        (, uint256 band,) = sra.getPricingParams();
        assertEq(band, 1000);

        // Quarter 1: +20% (1200 vs reference 1000) — accepted under the old band 2000 (G3 boundary), rejected under the new band 1000
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1200, 1, 0.5e18);
        vm.prank(orchB);
        vm.expectRevert(); // PriceBandExceeded: +20% > new band 10%
        sra.postVolume(1, _fpvWithPeriods(100e18, p2));
    }

    // ------------------------------------------------------------------------
    // P2 coverage closure (CV1): postVolume error branches + PRICE_BAND zero divisor
    // ------------------------------------------------------------------------

    /// Strategy 2/CV1: a non-admitted address calling postVolume -> NotAdmitted revert (within posting).
    /// (Existing postVolume tests all _admit first; the "gating failure" branch was uncovered — coverage line 312)
    function test_PostVolume_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.roll(_qEnd(0) + 1); // posting window
        vm.prank(stranger);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.postVolume(0, _fpv(100e18));
    }

    /// Strategy 8/CV1: a print with claimFil == 0 -> ZeroClaimFil revert (division guard).
    /// (_checkPriceBand's first line requires p.claimFil > 0 — coverage line 660 never hit the revert branch)
    function test_PostVolume_ZeroClaimFil_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);

        PricePeriod[] memory periods = new PricePeriod[](1);
        periods[0] = _period(5000, 1000, 0, 0.5e18); // claimFil = 0 -> rate division guard
        vm.prank(orch);
        vm.expectRevert(); // ZeroClaimFil
        sra.postVolume(0, _fpvWithPeriods(100e18, periods));
    }

    // ------------------------------------------------------------------------
    // P2 coverage closure (CV2): correctVolume error branches + FIL period copy
    // ------------------------------------------------------------------------

    /// Strategy 7/CV2: correctVolume's target not admitted -> NotAdmitted revert at the second vote's body execution.
    /// (coverage line 481 revert branch uncovered)
    function test_CorrectVolume_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.roll(_qPostEnd(0) + 1); // verification window
        FPV memory fpv = _fpv(100e18);
        vm.prank(owner1);
        sra.correctVolume(stranger, 0, fpv); // first vote approve
        vm.prank(owner2);
        vm.expectRevert(); // second vote executes the body -> NotAdmitted(stranger)
        sra.correctVolume(stranger, 0, fpv);
    }

    /// Strategy 7/CV2: correctVolume filPeriods beyond MAX_PRICE_PERIODS -> TooManyPricePeriods revert.
    /// (coverage line 482 revert branch uncovered; postVolume's same check was tested, the correctVolume path was missing)
    function test_CorrectVolume_TooManyPricePeriods_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0) + 1); // verification window
        PricePeriod[] memory periods = new PricePeriod[](MAX_PRICE_PERIODS + 1);
        for (uint256 i = 0; i < periods.length; i++) {
            periods[i] = _period(uint64(5000 + i), 1000, 1, 1e18);
        }
        FPV memory fpv = _fpvWithPeriods(100e18, periods);
        vm.prank(owner1);
        sra.correctVolume(orch, 0, fpv);
        vm.prank(owner2);
        vm.expectRevert(); // TooManyPricePeriods
        sra.correctVolume(orch, 0, fpv);
    }

    /// Strategy 7/CV2: correctVolume with FIL pricing periods — filPeriods copied wholesale, usdValue reset to 0.
    /// (All existing correctVolume tests used empty periods; coverage line 489's push loop body never executed)
    function test_CorrectVolume_WithFilPeriods_StoresAndResetsUsdValue() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // first post pure stablecoin in the posting window
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window correction: with FIL periods
        PricePeriod[] memory periods = new PricePeriod[](2);
        periods[0] = _period(5000, 1000, 1, 0.5e18); // rate 1000 USD/FIL
        periods[1] = _period(5001, 1200, 1, 0.25e18); // rate 1200 USD/FIL
        _correctVolume(orch, 0, _fpvWithPeriods(200e18, periods));

        FPV memory f = sra.fpvOf(0, orch);
        assertEq(f.stableUSD, 200e18); // stablecoin component replaced
        assertEq(f.filPeriods.length, 2); // FIL periods copied wholesale
        assertEq(Epoch.unwrap(f.filPeriods[0].printEpoch), 5000);
        assertEq(f.filPeriods[0].attoFil, 0.5e18);
        assertEq(f.filPeriods[1].attoFil, 0.25e18);
        assertEq(f.usdValue, 0); // cannot be finalized within the window; defensive reset
        assertTrue(f.posted); // marked posted after correction
    }

    // ------------------------------------------------------------------------
    // P2 coverage closure (CV7a): aggregatedFPV unposted exclusion
    // ------------------------------------------------------------------------

    /// Strategy 11/CV7: some orchestrators did not post -> aggregatedFPV skips them (!posted continue).
    /// (Existing aggregatedFPV tests all had "everyone posted"; coverage line 558's continue branch uncovered)
    function test_AggregatedFPV_UnpostedOrch_Excluded() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB"); // B admitted but does not post
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        // B unposted (posted=false) -> skipped; only A aggregated
        assertEq(sra.aggregatedFPV(0), 100e18);
    }

    // ------------------------------------------------------------------------
    // Deviation D alignment (anchored reference): band validation is against the
    // "qualifying print of the previous quarter's binding final state" (anchor);
    // the reference updates at quarter binding (finalize), not at posting —
    // preventing single-batch postVolume chained stepping from drifting the anchor.
    // ------------------------------------------------------------------------

    /// Strategy 8/D: within a single posting, the 2nd print is validated against the anchor (not the previous print) —
    /// the anchor reference prevents single-batch stepping drift.
    /// Under a chained implementation 1438 vs 1199 is only +19.9% and would pass; under the anchor it is +43.8% vs 1000, the whole batch reverts.
    function test_PostVolume_PriceBand_AnchorPreventsSameBatchDrift() public {
        // Quarter 0: anchor = 1000
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = 1000

        // Quarter 1: a single batch of two prints — 1199 (+19.9% vs anchor <= band, accepted),
        // 1438 (+43.8% vs anchor > band -> whole batch reverts; chained would pass at +19.9% vs 1199)
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory periods = new PricePeriod[](2);
        periods[0] = _period(6000, 1199, 1, 0.5e18);
        periods[1] = _period(6001, 1438, 1, 0.5e18);
        vm.prank(orchB);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PriceBandExceeded.selector, 6001)); // PriceBandExceeded(6001)
        sra.postVolume(1, _fpvWithPeriods(100e18, periods));
    }

    /// Strategy 8/D: cross-quarter anchor update — after quarter 0 finalize the anchor = that quarter's last qualifying print (1100);
    /// quarter 1 validates against the new anchor (1300 vs 1100 +18.2% accepted; if the anchor were still 1000, +30% would reject).
    function test_PostVolume_PriceBand_AnchorUpdatesOnFinalize() public {
        // Quarter 0: two prints (1000, 1100) all accepted on cold start (no anchor); after finalize the anchor = 1100
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](2);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        p1[1] = _period(5001, 1100, 1, 0.25e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = 1100

        // Quarter 1: 1300 vs anchor 1100 deviates +18.2% <= 20% -> accepted
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1300, 1, 0.5e18);
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));
        assertEq(sra.fpvOf(1, orchB).filPeriods.length, 1);
    }

    /// Strategy 8/D: correctVolume does not update the anchor — the anchor is set by the quarter's binding final state (finalize);
    /// corrections within the verification window do not affect the next quarter's reference (1300 vs anchor 1000 +30% still rejected).
    function test_PostVolume_PriceBand_CorrectVolumeDoesNotUpdateAnchor() public {
        // Quarter 0: anchor = 1000
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = 1000

        // Quarter 1 posting: 1100 (vs anchor +10% accepted)
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 1100, 1, 0.5e18);
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));

        // Quarter 1 verification: correctVolume changes to 1500 (rate 1500; does not update the anchor)
        vm.roll(_qPostEnd(1) + 1);
        PricePeriod[] memory p3 = new PricePeriod[](1);
        p3[0] = _period(6001, 1500, 1, 0.5e18);
        _correctVolume(orchB, 1, _fpvWithPeriods(100e18, p3));

        // Quarter 2: 1300 vs anchor 1000 deviates +30% > band -> rejected
        // (if correctVolume updated the anchor to 1500, 1300 vs -13% would accept — rejection proves the anchor unchanged)
        address orchC = makeAddr("orchC");
        _admit(orchC);
        vm.roll(_qEnd(2) + 1);
        PricePeriod[] memory p4 = new PricePeriod[](1);
        p4[0] = _period(7000, 1300, 1, 0.5e18);
        vm.prank(orchC);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PriceBandExceeded.selector, 7000)); // PriceBandExceeded(7000)
        sra.postVolume(2, _fpvWithPeriods(100e18, p4));
    }

    // ------------------------------------------------------------------------
    // Deviation B alignment (MIN_LOT filtering): prints below MIN_LOT do not participate in pricing —
    // band check skipped, never become the reference, finalize conversion does not count them (spec §3.3 qualifying-print semantics).
    // ------------------------------------------------------------------------

    /// Strategy 8/B: a sub-MIN_LOT print (lotUsd < MIN_LOT) skips the band check and is accepted, but does not update the reference —
    /// subsequent prints still validate against the original anchor (1300 vs anchor 1000 +30% rejected, proving the reference was not polluted).
    function test_MinLot_SubMinLotPrint_ExcludedFromPricing() public {
        // anchor = 1000 (quarter 0 post + finalize)
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = 1000

        // Quarter 1: sub-MIN_LOT print (lotUsd 50 < MIN_LOT 100) -> band check skipped, accepted; reference not updated
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 50, 1, 0.5e18); // rate 50 (-95% vs anchor), but sub-MIN_LOT -> check skipped
        _postAs(orchB, 1, _fpvWithPeriods(100e18, p2));
        assertEq(sra.fpvOf(1, orchB).filPeriods.length, 1);

        // Quarter 2: 1300 vs anchor 1000 +30% > band -> rejected (the sub-MIN_LOT print did not become the reference)
        address orchC = makeAddr("orchC");
        _admit(orchC);
        vm.roll(_qEnd(2) + 1);
        PricePeriod[] memory p3 = new PricePeriod[](1);
        p3[0] = _period(7000, 1300, 1, 0.5e18);
        vm.prank(orchC);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PriceBandExceeded.selector, 7000)); // PriceBandExceeded(7000)
        sra.postVolume(2, _fpvWithPeriods(100e18, p3));
    }

    /// Strategy 9/B: finalize conversion does not count the FIL amount of sub-MIN_LOT prints — usdValue contains only qualifying prints' components.
    function test_MinLot_SubMinLotPrint_NotCountedInConversion() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory periods = new PricePeriod[](2);
        periods[0] = _period(5000, 50, 1, 0.5e18); // lotUsd 50 < MIN_LOT 100 -> not counted (if counted +500e18)
        periods[1] = _period(5001, 1000, 1, 0.25e18); // qualifying -> 0.25e18×1000/1 = 250e18
        _postAs(orch, 0, _fpvWithPeriods(100e18, periods));

        vm.roll(_qVerifyEnd(0) + 1);
        // read auto-triggers finalize: usdValue = 100e18 (stable) + 250e18 (qualifying FIL component) = 350e18
        assertEq(sra.aggregatedFPV(0), 350e18);
    }

    /// Strategy 8/B: lotUsd == MIN_LOT is a qualifying print (>= semantics) — participates in band validation (not skipped).
    /// If filtered it would skip validation and be accepted; here the -90% deviation vs anchor exceeds band -> rejected,
    /// proving ==MIN_LOT participates in pricing.
    function test_MinLot_EqualToMinLot_Qualifies() public {
        // anchor = 1000 (quarter 0 post + finalize)
        address orchA = makeAddr("orchA");
        _admit(orchA);
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory p1 = new PricePeriod[](1);
        p1[0] = _period(5000, 1000, 1, 0.5e18);
        _postAs(orchA, 0, _fpvWithPeriods(100e18, p1));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // anchor = 1000

        // Quarter 1: lotUsd == MIN_LOT(100) -> qualifying, -90% vs anchor > band -> rejected
        address orchB = makeAddr("orchB");
        _admit(orchB);
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory p2 = new PricePeriod[](1);
        p2[0] = _period(6000, 100, 1, 0.5e18); // rate 100 == MIN_LOT face value, -90% vs 1000
        vm.prank(orchB);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PriceBandExceeded.selector, 6000)); // PriceBandExceeded(6000)
        sra.postVolume(1, _fpvWithPeriods(100e18, p2));
    }
}
