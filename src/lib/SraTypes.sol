// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";

// ----------------------------------------------------------------------------
// Top-level SRA types (test files import from this file: Pair / PricePeriod / FPV)
// Extracted from ServiceRewardsActor.sol so the storage library (SraStorage.sol) and
// the actor can share them without a source import cycle.
// ----------------------------------------------------------------------------

/// @notice (payer, operator) binding pair. C1: the design's §2.3.1 inline tuple-array signature is
///         illegal in Solidity 0.8.36 (Error 3546); replaced with a named struct (ABI encoding is still a tuple array).
struct Pair {
    address payer;
    address operator;
}

/// @notice A single FIL pricing period (fee-auction print). Implied rate = lotUsd / claimFil (USD per FIL).
/// @dev printEpoch uses the Epoch type (review: "use the Epoch type for epochs") instead of a bare uint64.
struct PricePeriod {
    Epoch printEpoch; // print settlement epoch
    uint256 lotUsd; // lot face value (USD, integer)
    uint256 claimFil; // claim FIL consumed (attoFIL)
    uint256 attoFil; // FIL amount settled in this period
}

// forge-lint: disable-next-item(pascal-case-struct) — FPV is the FIP-0118 spec term (public ABI-facing type)
/// @notice Quarterly FPV: stablecoin face value + FIL pricing-period vector; usdValue is the final value after finalizeConversion.
struct FPV {
    // forge-lint: disable-next-line(mixed-case-variable) — spec field name (StableUSD, FIP-0118)
    uint256 stableUSD; // stablecoin component (face USD)
    PricePeriod[] filPeriods; // FIL component, <= MAX_PRICE_PERIODS entries
    uint256 usdValue; // USD final value after FinalizeConversion (0 if unconverted)
    bool posted; // posted flag (at most once per quarter)
}
