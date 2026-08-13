// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// Overflow DoS regression tests — V1/V2/V3 (TDD Red phase, audit findings)
//
// Background: the SRA audit (PR #24 review, probe-verified) found 3 overflow-DoS
// vulnerabilities sharing one root cause: the FPV input fields (stableUSD / lotUsd /
// claimFil / attoFil) have no business-domain upper-bound validation, while the
// security review (docs/sra-design.md §5.5) "Integer overflow ✅ Safe" conclusion
// relies on an unenforced "business domain ~1e6" assumption.
//
//   V1 — Anchor pollution → network-wide permanent DoS:
//        a cold-start quarter (no anchor yet) accepts any print; a print with
//        lotUsd = type(uint256).max becomes the anchor at finalize; afterwards every
//        postVolume's _checkPriceBand computes lower = anchorLotUsd * claimFil * 8000
//        which overflows -> all later postVolume revert forever (the anchor never
//        updates again and there is no governance reset). Probe: Q0 pollute -> Q1
//        normal postVolume reverts with arithmetic overflow.
//   V2 — finalizeConversion overflow → quarterly settlement stuck:
//        attoFil * lotUsd (2^200 × 2^200) overflows in
//        usd += p.attoFil * p.lotUsd / p.claimFil -> finalizeConversion reverts
//        forever -> submitShares (auto-finalize) also reverts -> the quarter's
//        shares can never be submitted.
//   V3 — Huge stableUSD → _computeShares overflow → quarterly settlement stuck:
//        stableUSD = type(uint256).max passes posting (no bound check); at
//        submitShares, usds[i] * SHARE_TOTAL (max × 1e18) overflows -> revert.
//
// Expected fix behavior (locked by these tests, TDD):
//   - V1: extreme prints (lotUsd/claimFil beyond a business bound) are rejected by
//         postVolume/correctVolume, or never become the anchor; a normal Q1 print
//         must pass the band check (system stays operational).
//   - V2: prints whose attoFil * lotUsd would overflow are rejected (or skipped at
//         finalize); finalizeConversion must complete and submitShares settle.
//   - V3: stableUSD beyond the business bound is rejected; submitShares must settle.
//
// Test shape: each vulnerability has two tests —
//   * *_SystemStaysOperational: the malicious post is wrapped in try/catch (so both
//     fix shapes — reject-at-post vs never-anchor/skip-at-finalize — keep the test
//     Green) and asserts the system keeps working (band check / finalize / shares).
//   * *_RejectedByPostVolume: locks the task-given fix direction (reject at the
//     postVolume/correctVolume entry point with a business-domain bound).
// All 6 tests are Red against the current implementation (audit probe-verified).
// ============================================================================

import {Share} from "../src/lib/FVMRewardTypes.sol";
import {PricePeriod} from "../src/ServiceRewardsActor.sol";
import {SRATestBase} from "./SRATestBase.sol";

contract SRAOverflowDoS is SRATestBase {
    uint256 private constant EXTREME = type(uint256).max; // V1/V3: anchor & stableUSD poison value
    uint256 private constant EXTREME_FIL = 2 ** 200; // V2: 2^200 × 2^200 = 2^400 > 2^256 → overflow

    // ------------------------------------------------------------------------
    // V1 — anchor pollution → network-wide permanent DoS
    // ------------------------------------------------------------------------

    /// V1 regression (operational): after an attacker tries to pollute the cold-start anchor
    /// with lotUsd = type(uint256).max, a normal Q1 print must still pass the PRICE_BAND check
    /// (the polluted anchor must not permanently DoS every later postVolume).
    /// Red: finalize Q0 accepts (max, 1e18) as anchor; Q1 postVolume reverts with
    /// arithmetic overflow in _checkPriceBand (lower = max * claimFil * (10000 - band)).
    function test_V1_ExtremePrint_SystemStaysOperational() public {
        address attacker = makeAddr("v1-attacker");
        address victim = makeAddr("v1-victim");
        _admit(attacker);
        _admit(victim);

        // Q0 cold start (no anchor yet): attacker posts an extreme-ratio print.
        // attoFil=1e18, lotUsd=max, claimFil=1e18 keeps finalize's usd += attoFil*lotUsd/claimFil
        // = max (no overflow), isolating the V1 anchor-pollution path from V2.
        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), EXTREME, 1e18, 1e18);
        vm.prank(attacker);
        try sra.postVolume(0, _fpvWithPeriods(0, ps)) {} catch {}

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // currently: anchor = (max, 1e18)

        // Q1: a normal print must pass the band check — it must NOT revert.
        vm.roll(_qEnd(1) + 1);
        PricePeriod[] memory ps1 = new PricePeriod[](1);
        ps1[0] = _period(uint64(block.number), 1000, 1, 1e18);
        vm.prank(victim);
        sra.postVolume(1, _fpvWithPeriods(0, ps1)); // Red: lower = max*1*8000 overflows → revert
    }

    /// V1 regression (reject-at-post): the extreme-ratio print itself must be rejected by
    /// postVolume (expected fix: business-domain upper bound on lotUsd/claimFil ratio).
    /// Red: cold start accepts any print (no bound check) → no revert.
    function test_V1_ExtremePrint_RejectedByPostVolume() public {
        address attacker = makeAddr("v1-reject");
        _admit(attacker);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), EXTREME, 1e18, 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        sra.postVolume(0, _fpvWithPeriods(0, ps));
    }

    // ------------------------------------------------------------------------
    // V2 — finalizeConversion overflow → quarterly settlement stuck
    // ------------------------------------------------------------------------

    /// V2 regression (operational): an attacker print with attoFil = 2^200, lotUsd = 2^200
    /// must not wedge finalizeConversion; the quarter must still finalize and submit shares.
    /// Red: _finalizeConversion's usd += 2^200 * 2^200 / 1 overflows → revert.
    function test_V2_ExtremeAttoFilLotUsd_SystemStaysOperational() public {
        address attacker = makeAddr("v2-attacker");
        address victim = makeAddr("v2-victim");
        _admit(attacker);
        _admit(victim);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), EXTREME_FIL, 1, EXTREME_FIL); // 2^200 × 2^200 overflows
        vm.prank(attacker);
        try sra.postVolume(0, _fpvWithPeriods(0, ps)) {} catch {}

        // victim's normal FIL print (healthy rate: 1000 USD per FIL)
        PricePeriod[] memory ps1 = new PricePeriod[](1);
        ps1[0] = _period(uint64(block.number), 1000, 1, 1e18);
        vm.prank(victim);
        sra.postVolume(0, _fpvWithPeriods(0, ps1));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0); // Red: attacker's period overflows → revert
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    /// V2 regression (reject-at-post): the extreme attoFil×lotUsd print must be rejected by
    /// postVolume (expected fix: bound the product or the single fields).
    /// Red: cold start accepts any print (no bound check) → no revert.
    function test_V2_ExtremeAttoFilLotUsd_RejectedByPostVolume() public {
        address attacker = makeAddr("v2-reject");
        _admit(attacker);

        vm.roll(_qEnd(0) + 1);
        PricePeriod[] memory ps = new PricePeriod[](1);
        ps[0] = _period(uint64(block.number), EXTREME_FIL, 1, EXTREME_FIL);
        vm.prank(attacker);
        vm.expectRevert();
        sra.postVolume(0, _fpvWithPeriods(0, ps));
    }

    // ------------------------------------------------------------------------
    // V3 — huge stableUSD → _computeShares overflow → quarterly settlement stuck
    // ------------------------------------------------------------------------

    /// V3 regression (operational): stableUSD = type(uint256).max must not wedge
    /// submitShares; the quarter must still settle.
    /// Red: the collect loop's total += usd (max + 100e18) or _computeShares's
    /// usds[i] * SHARE_TOTAL (max × 1e18) overflows → revert.
    function test_V3_HugeStableUSD_SystemStaysOperational() public {
        address attacker = makeAddr("v3-attacker");
        address victim = makeAddr("v3-victim");
        _admit(attacker);
        _admit(victim);

        vm.roll(_qEnd(0) + 1);
        vm.prank(attacker);
        try sra.postVolume(0, _fpv(EXTREME)) {} catch {}

        vm.prank(victim);
        sra.postVolume(0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.finalizeConversion(0);
        sra.submitShares(0); // Red: total / _computeShares overflow → revert

        Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    /// V3 regression (reject-at-post): huge stableUSD must be rejected by postVolume
    /// (expected fix: business-domain upper bound on stableUSD).
    /// Red: stableUSD has no bound check → no revert.
    function test_V3_HugeStableUSD_RejectedByPostVolume() public {
        address attacker = makeAddr("v3-reject");
        _admit(attacker);

        vm.roll(_qEnd(0) + 1);
        vm.prank(attacker);
        vm.expectRevert();
        sra.postVolume(0, _fpv(EXTREME));
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
