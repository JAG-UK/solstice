// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";

/// @dev Halmos symbolic-verification harness: inherits ServiceRewardsActor, exposing the internal _computeShares.
///      The check contract inherits this harness and calls _computeShares directly (internal inlining, avoiding
///      cross-contract external calls getting symbolized by halmos and becoming unresolvable).
contract ComputeSharesHarness is ServiceRewardsActor {
    constructor()
        ServiceRewardsActor(
            address(0xBADC0FFEE), // owner1 (EXTCODESIZE is a symbolic value under halmos symbolic execution)
            address(0xBADC0FFE), // owner2
            uint64(1), // epochsPerQuarter
            uint64(1), // postPeriod
            uint64(1), // verificationWindow
            uint64(0), // cancelHold
            uint64(0), // activationEpoch
            0, // minLot
            0 // priceBand
        )
    {}
}
