// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ----------------------------------------------------------------------------
// Top-level SRA types (test files import from this file: Pair / FPV)
// ----------------------------------------------------------------------------

/// @notice (payer, operator) binding pair. C1: the design's §2.3.1 inline tuple-array signature is
///         illegal in Solidity 0.8.36 (Error 3546); replaced with a named struct (ABI encoding is still a tuple array).
struct Pair {
    address payer;
    address operator;
}

// forge-lint: disable-next-item(pascal-case-struct) — FPV is the FIP-0118 spec term (public ABI-facing type)
/// @notice Quarterly FPV: a single USD-denominated total (FIP-0118 §2.3, FIPs#1275: FIL→USD conversion moved
///         off-chain, so the SRA no longer stores pricing periods). `usd` is the face-USD stablecoin volume plus
///         the off-chain-converted FIL volume; `posted` is the at-most-once-per-quarter flag.
/// @dev uint128: storage-packing optimization — MAX_FPV_USD(1e30) < uint128.max(3.4e38), so `usd` packs with
///      `posted` into one storage slot (2 -> 1). ABI unchanged (static 32-byte right-aligned encoding is
///      identical for uint128/uint256); spec defines only "single USD total" semantics, no width.
struct FPV {
    uint128 usd; // single USD total for the quarter (FPV_i(Q))
    bool posted; // posted flag (at most once per quarter)
}
