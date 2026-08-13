// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// SRA integration contract tests — simulate the SWA QuarterlyGateCheck consumption chain of aggregatedFPV
// (spec-conformance alignment: deviation A eliminated; see .ghost/references/013-sra-spec-conformance.md)
//
// Background: FIP-0118 states in three places that "reading AggregatedFPV(Q) triggers FinalizeConversion(Q)"
// (§3.2/§4.1/§4.2). The implementation's aggregatedFPV is aligned: reading auto-triggers the idempotent finalize —
// after binding, a read before finalize triggers the conversion, returning the complete USD (incl. the FIL component),
// with the observable side effect isFinalized=true. src/StreamWeightActor.sol has no gating implementation,
// so this file uses a test contract as the "gating consumer", locking the contract "read yields the complete value,
// no divergence from submitShares".
// ============================================================================

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Share} from "../src/lib/FVMRewardTypes.sol";
import {PricePeriod} from "../src/ServiceRewardsActor.sol";
import {SRATestBase} from "./SRATestBase.sol";

contract SRAIntegrationTest is SRATestBase {
    uint256 private _filSalt;
    uint256 private _stableSalt;

    // ------------------------------------------------------------------------
    // Scenario 1 (core, verifies the spec's "execution order produces no divergent numbers"):
    // the gating consumer finalizes first -> aggregatedFPV complete -> submitShares's
    // SharesSubmitted.totalUsd strictly equals aggregatedFPV (no divergence).
    // ------------------------------------------------------------------------

    /// Orchestrator a: 100e18 stable + 0.5 FIL at 1000 USD/FIL -> FIL component 500e18, total 600e18;
    /// orchestrator b: pure stablecoin 300e18. total = 900e18.
    function test_Contract_FinalizeFirst_AggregatedMatchesSubmitTotal() public {
        PricePeriod[] memory pa = new PricePeriod[](1);
        pa[0] = _period(5000, 1000, 1, 0.5e18); // cold start, no reference; band check accepts
        _admitAndPostFil(100e18, pa);
        _admitAndPostStable(300e18);

        _rollTo(_qVerifyEnd(0) + 1); // post-binding

        // the gating consumer triggers conversion first (the spec requires the SWA gating to finalize before reading)
        sra.finalizeConversion(0);
        assertTrue(sra.isFinalized(0), "finalized after explicit call");
        assertEq(sra.aggregatedFPV(0), 900e18, "post-finalize aggregated includes FIL component");

        // no divergence: submitShares's internal total must == aggregatedFPV (expectEmit captures totalUsd)
        vm.expectEmit(true, false, false, true, address(sra));
        emit ServiceRewardsActor.SharesSubmitted(0, 2, 900e18);
        sra.submitShares(0);
    }

    // ------------------------------------------------------------------------
    // Scenario 2: after submitShares auto-finalizes, subsequent reads of aggregatedFPV are consistent.
    // ------------------------------------------------------------------------

    function test_Contract_SubmitSharesAutoFinalize_ThenReadConsistent() public {
        PricePeriod[] memory pa = new PricePeriod[](1);
        pa[0] = _period(5000, 1000, 1, 0.5e18);
        address a = _admitAndPostFil(100e18, pa);
        address b = _admitAndPostStable(300e18);

        _rollTo(_qVerifyEnd(0) + 1);

        // no manual finalize: submitShares auto-triggers the conversion (idempotent)
        sra.submitShares(0);

        assertTrue(sra.isFinalized(0), "submitShares auto-finalizes conversion");
        assertEq(sra.aggregatedFPV(0), 900e18, "post-submit aggregated matches final value");

        // shares proportional to USD: a:b = 600:300 = 2:1, Σ == 1e18 (largest-remainder tops up the larger remainder a)
        Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
        assertEq(shares.length, 2);
        assertEq(_sumShares(shares), 1e18);
        assertEq(_walletShare(shares, a), 666_666_666_666_666_667);
        assertEq(_walletShare(shares, b), 333_333_333_333_333_333);
    }

    // ------------------------------------------------------------------------
    // Scenario 3 (aligned with spec §3.2/§4.1/§4.2): reading aggregatedFPV auto-triggers finalize —
    // after binding without explicit finalize, calling aggregatedFPV yields the complete value (incl. the FIL
    // component), and isFinalized becomes true (the conversion side effect is observable).
    // ------------------------------------------------------------------------

    function test_Contract_ReadAutoFinalizes_ReturnsComplete() public {
        PricePeriod[] memory pa = new PricePeriod[](1);
        pa[0] = _period(5000, 1000, 1, 0.5e18);
        _admitAndPostFil(100e18, pa); // complete 600e18
        _admitAndPostStable(300e18);

        _rollTo(_qVerifyEnd(0) + 1); // post-binding, no explicit finalize

        // reading auto-triggers finalize: returns the complete value (incl. the FIL component) + isFinalized becomes true
        assertEq(sra.aggregatedFPV(0), 900e18, "read auto-finalizes: complete value with FIL component");
        assertTrue(sra.isFinalized(0), "read triggers conversion (aligned with spec)");
    }

    // ------------------------------------------------------------------------
    // Scenario 4: with no FIL component, stableUSD is the final value — the read auto-triggers (idempotent, no conversion work).
    // ------------------------------------------------------------------------

    function test_Contract_StableOnly_ViewCompleteWithoutFinalize() public {
        _admitAndPostStable(100e18);
        _rollTo(_qVerifyEnd(0) + 1); // post-binding, no finalize
        assertEq(sra.aggregatedFPV(0), 100e18, "stable-only: view equals final value");
    }

    // ------------------------------------------------------------------------
    // helpers (same pattern as SRAShares: increasing salt for unique addresses, roll back to the posting window before posting)
    // ------------------------------------------------------------------------

    /// @dev Admits and posts an orchestrator with FIL pricing periods (within q=0's posting window).
    function _admitAndPostFil(uint256 stableUsd, PricePeriod[] memory periods) internal returns (address orch) {
        orch = makeAddr(string.concat("fil-orch-", vm.toString(_filSalt++)));
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpvWithPeriods(stableUsd, periods));
    }

    /// @dev Admits and posts a pure-stablecoin orchestrator (within q=0's posting window).
    function _admitAndPostStable(uint256 stableUsd) internal returns (address orch) {
        orch = makeAddr(string.concat("stable-orch-", vm.toString(_stableSalt++)));
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(stableUsd));
    }

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += shares[i].share;
        }
    }

    function _walletShare(Share[] memory shares, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return shares[i].share;
        }
        return 0;
    }
}
