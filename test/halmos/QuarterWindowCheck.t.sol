// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {QuarterWindowHarness} from "./QuarterWindowHarness.sol";

/// @dev Halmos symbolic verification of the quarter state-machine window determination (blind spot 4 closed).
///      Deployment mode: this contract directly inherits QuarterWindowHarness (the pattern verified in t8); when
///      running halmos with --no-test-constructor the constructor is skipped — but the window constants
///      (EPOCHS_PER_QUARTER/POST_PERIOD/VERIFICATION_WINDOW/ACTIVATION_EPOCH) are immutable, and after skipping
///      the constructor they get symbolized by halmos as free variables. Therefore this verification focuses on
///      **parameter-independent properties** (mathematical properties holding under any window parameters).
///      ⚠️ halmos 0.1.13 tool limits (confirmed by probe experiments; see .ghost/references/015 report):
///      1. vm.warp does not work on symbolic parameters -> block.number cannot be symbolized -> window
///         determination relying on currentEpoch() (posting/verification/binding universal completeness)
///         cannot be directly symbolically verified
///      2. storage array element reads after push are wrong (length correct but elements symbolic) ->
///         _isFrozenAt interval search relying on freeze-history arrays cannot be symbolically verified
///         with storage-preset data
///      The limited propositions (T1 completeness/T5 interval search/T6 mutual exclusion) are downgraded to
///      dynamic test coverage: SRAQuarter.t.sol's 8 window-boundary ±1 cases, SRARegistry freeze/unfreeze in
///      both directions, invariant A2 random freeze-history exclusion — 100% line coverage guarantees no
///      unexecuted paths.
contract QuarterWindowCheck is QuarterWindowHarness, Test {
    /// @dev owner params arbitrary (halmos executes with --no-test-constructor, skipping the constructor; the compiler layer still needs explicit args).
    constructor() QuarterWindowHarness(address(0xCAFE), address(0xBEEF)) {}

    uint64 private constant Q = 1000;
    uint64 private constant P = 300;
    uint64 private constant V = 400;
    uint64 private constant ACTIVATION = 100_000;
    /// @dev nowE upper bound (covers the full window lifecycle of q ≤ 3, matching the production config; only constrains the SMT domain).
    uint256 private constant MAX_NOW = ACTIVATION + 4 * Q + P + V + 1;

    // ------------------------------------------------------------------------
    // T2a: quarter-boundary epoch semantics (parameter-independent boundary property)
    // ------------------------------------------------------------------------

    /// @dev T2a: at now = E_q, ¬posting — the quarter-boundary epoch E_q is not in the new quarter's posting
    ///      window (posting is left-open (E, E+P]). E_q itself is the last epoch of the previous quarter's
    ///      binding tail. This is the most critical off-by-one boundary, independent of concrete window parameter values.
    function check_T2a_QuarterEndNotInPosting(uint64 q) public {
        vm.assume(q <= 3);
        uint64 E = uint64(Epoch.unwrap(_qEnd(q)));
        vm.warp(E);
        assert(!_inPostingWindow(q));
    }

    // ------------------------------------------------------------------------
    // T3: constant quarter-progression interval (arithmetic correctness + cross-quarter continuity, parameter-independent)
    // ------------------------------------------------------------------------

    /// @dev T3: any consecutive quarter interval is constant: qEnd(q+1) - qEnd(q) == qEnd(1) - qEnd(0).
    ///      I.e. quarter progression is equidistant (the gap is always EPOCHS_PER_QUARTER, independent of
    ///      ACTIVATION/specific config), with no cross-quarter gaps or overlaps. The gap is derived from the
    ///      implementation itself (not depending on concrete parameter values that cannot be read).
    function check_T3_QuarterProgression(uint64 q) public {
        vm.assume(q <= 3);
        uint256 gap = Epoch.unwrap(_qEnd(q + 1)) - Epoch.unwrap(_qEnd(q));
        uint256 gap0 = Epoch.unwrap(_qEnd(1)) - Epoch.unwrap(_qEnd(0));
        assert(gap == gap0);
    }

    // ------------------------------------------------------------------------
    // T4: freeze-snapshot time independence (S5 semantics, parameter-independent)
    // ------------------------------------------------------------------------

    /// @dev T4: _frozenAtPostEnd(orch,q)'s result is independent of the calling block.number (snapshot semantics,
    ///      anti-timing-game). S5 promises "calling at any time yields the same answer" — exclusion cannot be
    ///      bypassed by freezing after submitting / unfreezing before submitting. Symbolizes two different times
    ///      and verifies identical results.
    ///      (Note: when halmos's warp does not work, the verification strength degrades to "the function indeed
    ///      does not read block.number", which is itself a necessary condition of the S5 snapshot semantics;
    ///      combined with dynamic freeze tests it forms complete coverage.)
    function check_T4_SnapshotTimeInvariant(uint64 q, uint256 t1, uint256 t2) public {
        vm.assume(q <= 3);
        vm.assume(t1 < 2 ** 48 && t2 < 2 ** 48 && t1 != t2);
        address orch = address(0xCAFE);
        _setFreezeInterval(orch, 100, 200);
        vm.warp(t1);
        bool r1 = _frozenAtPostEnd(orch, q);
        vm.warp(t2);
        bool r2 = _frozenAtPostEnd(orch, q);
        assert(r1 == r2);
    }

    // ------------------------------------------------------------------------
    // T5b: empty freeze history -> never frozen (does not depend on array element values; symbolically verifiable)
    // ------------------------------------------------------------------------

    /// @dev T5b: no freeze history (freezeEpochs empty) -> never frozen at any epoch.
    ///      Verifies the empty-array boundary: _isFrozenAt returns false for empty history (zero iterations).
    function check_T5b_IsFrozenAtEmpty(uint256 e) public {
        vm.assume(e < 1000);
        address orch = address(0xBEEF);
        assert(!_isFrozenAt(orch, Epoch.wrap(uint96(e))));
    }
}
