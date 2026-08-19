// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "../../src/lib/Epoch.sol";
import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";

/// @dev Halmos symbolic-verification harness: inherits ServiceRewardsActor, exposing the internal quarter-window
///      determination functions via public wrappers (_qEnd/_inPostingWindow/_inVerificationWindow/_afterBinding/
///      _isFrozenAt/_frozenAtPostEnd). The harness only forwards internal calls; it does not copy window logic —
///      what is verified is the implementation itself.
///      Constructor parameters match the production config in test/SRATestBase.sol (Q=1000/P=300/V=400/
///      ACTIVATION=100000), verifying the window semantics under the production config.
///      Deployment: the check contract directly inherits this harness (the pattern verified in t8); when running
///      halmos with --no-test-constructor the constructor is skipped — note: after skipping the constructor the
///      immutable window constants (Q/P/V/ACTIVATION) get symbolized by halmos as free variables (no concrete
///      values), so the propositions verified by this harness are all "parameter-independent properties"
///      (mathematical properties holding under any window config); absolute boundary membership depending on
///      concrete parameter values is covered by dynamic tests (see .ghost/references/015-sra-statemachine-verification.md §4 limitation 1).
contract QuarterWindowHarness is ServiceRewardsActor {
    constructor(address owner1, address owner2)
        ServiceRewardsActor(
            owner1,
            owner2,
            uint64(1000), // epochsPerQuarter
            uint64(300), // postPeriod
            uint64(400), // verificationWindow
            uint64(100), // cancelHold
            uint64(100_000), // activationEpoch
            1e18, // minLot
            2000 // priceBand (20%, basis points)
        )
    {}

    // qEnd moved to ServiceRewardsActor (review): the actor now exposes
    // `qEnd(uint64) external view returns (Epoch)` (IServiceRewardsActor interface);
    // this harness inherits it, and the check contract reads `_qEnd` inline.

    /// @dev posting window (E, E+POST].
    function inPostingWindow(uint64 q) external view returns (bool) {
        return _inPostingWindow(q);
    }

    /// @dev verification window (E+POST, E+POST+VERIFY].
    function inVerificationWindow(uint64 q) external view returns (bool) {
        return _inVerificationWindow(q);
    }

    /// @dev post-binding: now > E+POST+VERIFY.
    function afterBinding(uint64 q) external view returns (bool) {
        return _afterBinding(q);
    }

    /// @dev freeze-snapshot determination (S5: the E+POST instant).
    function frozenAtPostEnd(address orch, uint64 q) external view returns (bool) {
        return _frozenAtPostEnd(orch, q);
    }

    /// @dev interval-search determination (e passed as uint256 for easier arithmetic in the check contract).
    function isFrozenAt(address orch, uint256 e) external view returns (bool) {
        return _isFrozenAt(orch, Epoch.wrap(uint64(e)));
    }

    /// @dev test-precondition setup (internal; the check inherits and calls it inline — resolvable by halmos):
    ///      writes a freeze interval [freeze, unfreeze) (does not copy the implementation logic — the
    ///      determination logic under verification is still the implementation itself; this only sets test preconditions).
    function _setFreezeInterval(address orch, uint256 freeze, uint256 unfreeze) internal {
        _registry().orchestrators[orch].admitted = true;
        _registry().orchestrators[orch].freezeEpochs.push(Epoch.wrap(uint64(freeze)));
        _registry().orchestrators[orch].unfreezeEpochs.push(Epoch.wrap(uint64(unfreeze)));
    }
}
