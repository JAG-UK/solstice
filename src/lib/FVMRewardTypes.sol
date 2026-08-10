// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

/// @notice A stream's Distribution kind (FIP-1270 Section 2.4).
/// @dev IMPLICIT streams store no writer (f02 resolves the recipient from protocol state).
///      EXPLICIT streams are paid out per a wallet-to-share map written by their designated writer.
enum DistributionKind {
    IMPLICIT,
    EXPLICIT
}

/// @notice A stream's weight schedule: clamp(vStart + slope * (epoch - tStart), floor, cap).
/// @dev WAD-scaled (1e18 == 1.0 == 100%); fields must fit int64 to be wire-encodable.
struct WeightRecord {
    int256 vStart;
    int256 slope;
    uint64 tStart;
    int256 floor;
    int256 cap;
}

/// @notice One entry in an EXPLICIT stream's wallet-to-share map.
/// @dev Shares across a stream's map must sum to SHARE_TOTAL (1e18); a single share must
///      therefore fit uint64.
struct Share {
    address wallet;
    uint256 share;
}

/// @notice The kinds of queueable SWA discretionary writes a pending slot may hold.
enum PendingOp {
    SET_WEIGHT,
    STEP_WEIGHT,
    REGISTER,
    REMOVE,
    SET_DISTRIBUTION
}
