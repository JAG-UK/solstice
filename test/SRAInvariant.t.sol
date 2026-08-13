// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// SRA invariant tests (P1) — random operation sequences + persistent invariant verification
//
// 3 core invariants:
//   I1 Share conservation: after any operation sequence (the most recent successful submitShares),
//      the f02 share map Σ is always == 1e18
//   I2 Binding uniqueness: any (payer, operator) pair always has at most 1 valid bound orchestrator;
//      the handler-recorded last binder (resolved along the replace chain) must == sra.bindingOf()
//      — the T6 bug (third-party grab after replace) is exactly the kind of invariant this breaks
//   I3 Governance consistency: the approved bitmask is consistent with orchestrator state —
//      parked tasks (two votes, not executed) have a non-zero bitmask and state not landed;
//      executed tasks have a zeroed bitmask (deleted after execution); handler-expected state == sra actual
//
// Handler design:
//   - inherits SRATestBase (auto-deploys SRA + Safe owners + service stream 2)
//   - 14 random operations (fuzzer targets): admit/remove/freeze/unfreeze/replace/
//     reassignBinding/registerPairs/postVolume/correctVolume/finalizeConversion/
//     submitShares/parkAdmit/completeParked/rollForward
//   - time model: governance operations internally roll(block.number + SRA_CANCEL_HOLD) to complete the three phases;
//     business operations explicitly roll to the target quarter window (posting/verification/post-bound)
//   - every operation's precondition check keeps the "expected success" path reachable (invalid calls return directly, no state pollution)
//
// Run: forge test --match-contract SRAInvariant (default 256 runs)
// ============================================================================

import {Test} from "forge-std/Test.sol";

import {Share} from "../src/lib/FVMRewardTypes.sol";
import {ServiceRewardsActor, FPV, Pair} from "../src/ServiceRewardsActor.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {SRATestBase} from "./SRATestBase.sol";

/// @dev ERC-7201 storage slot of PendingTask (see src/lib/PendingTask.sol: Solstice.PendingTasks).
///     Hardcoded on the test side to read the approved bitmask (invariant I3).
bytes32 constant PENDING_TASKS_SLOT = 0x635f64a8ec66823e68578973f5bc466fd4e0eadd655f760cfc91e860524aa300;

/// @notice Invariant handler: encapsulates random operations and maintains "expected state" for invariant assertions.
contract SRAInvariantHandler is SRATestBase {
    uint256 internal constant ORCH_POOL = 20;
    uint256 internal constant PAYER_POOL = 5;
    uint256 internal constant OPERATOR_POOL = 5;
    uint256 internal constant MAX_Q = 2; // explores quarters 0/1/2

    // ---- orchestrator pool and handler-side expected state ----
    address[] internal _orchPool;
    mapping(address => bool) internal _admitted; // expected admitted
    mapping(address => bool) internal _frozen; // expected frozen
    mapping(address => address) internal _successor; // replace chain (handler side)

    // ---- pair pool and binding records ----
    address[] internal _payers;
    address[] internal _operators;

    struct PairRecord {
        address payer;
        address operator;
        address boundOrch; // handler-recorded last successful binder
    }
    PairRecord[] internal _pairs;
    mapping(bytes32 => uint256) internal _pairIdx; // pairId → _pairs index + 1

    // ---- quarterly posting records (avoid invalid AlreadyPosted calls) ----
    mapping(uint64 => mapping(address => bool)) internal _posted;

    // ---- governance task tracking (invariant I3) ----
    /// @dev taskState: 0=none 1=parked (two votes, not executed; pending across operations) 2=executed 3=cleared (reverted but deleted)
    mapping(bytes32 => uint8) internal _taskState;
    mapping(bytes32 => address) internal _parkedOrch;
    mapping(bytes32 => uint64) internal _parkedEpoch;
    bytes32[] internal _parkedTasks;
    bytes32[] internal _executedTasks;
    /// @dev set of parked governance target addresses: while parked, the target must not be pre-admitted/replaced by atomic ops (I3 consistency)
    mapping(address => bool) internal _parkedTarget;

    bool internal _everSubmitted;

    // ---- A2/A3: POST-instant freeze snapshot + usdValue tracking (aligned with the implementation's freezeEpochs/unfreezeEpochs semantics) ----
    /// @dev freeze effective epoch list (implementation freeze pushes currentEpoch()); paired with _unfreezeAt as half-open intervals.
    mapping(address => uint64[]) internal _freezeAt;
    /// @dev unfreeze effective epoch list (implementation unfreeze pushes currentEpoch()).
    mapping(address => uint64[]) internal _unfreezeAt;

    /// @dev quarter and POST-instant snapshot of the most recent successful submitShares (read by invariants A2/A3).
    bool internal _hasLastSubmit;
    uint64 internal _lastSubmitQ;
    address[] internal _lastFrozenWallets; // resolved addresses of active orchestrators frozen at the POST instant
    uint256 internal _lastTotal; // Σ usdValue of non-frozen with usdValue>0 at the POST instant
    uint256 internal _lastActiveCount; // corresponding orchestrator count

    constructor() {
        for (uint256 i = 0; i < ORCH_POOL; i++) {
            _orchPool.push(makeAddr(string.concat("inv-orch-", vm.toString(i))));
        }
        for (uint256 i = 0; i < PAYER_POOL; i++) {
            _payers.push(makeAddr(string.concat("inv-payer-", vm.toString(i))));
        }
        for (uint256 i = 0; i < OPERATOR_POOL; i++) {
            _operators.push(makeAddr(string.concat("inv-operator-", vm.toString(i))));
        }
    }

    // ========================================================================
    // Governance operations (unanimous + hold three phases: owner1 vote -> owner2 vote -> roll(hold) -> third execution)
    // Precondition checks guarantee the third call succeeds (no concurrent insertion between the two votes; operation is atomic)
    // ========================================================================

    /// @notice Atomic admit: two votes + hold + execution, completed within one call.
    function admit(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (sra.isAdmitted(orch) || sra.admittedCount() >= 64) return;
        if (_parkedTarget[orch]) return; // must not preempt a parked governance target (I3)
        bytes32 taskId = _taskId(sra.admit.selector, abi.encode(orch));
        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch); // permissionless execution
        _admitted[orch] = true;
        // A2 sync: the implementation's admit identity reset (clears successor/frozen/freeze history) -> the handler-side
        // expected state is cleared in sync, otherwise I3c (isFrozen consistency) and A2 (freeze-interval tracking) false-positive.
        _frozen[orch] = false;
        _successor[orch] = address(0);
        delete _freezeAt[orch];
        delete _unfreezeAt[orch];
        _recordExecuted(taskId);
    }

    /// @notice Atomic remove: releases the slot and frozen state; the implementation's remove explicitly clears successor, the handler must sync (I2).
    function remove(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (!sra.isAdmitted(orch)) return;
        bytes32 taskId = _taskId(sra.remove.selector, abi.encode(orch));
        vm.prank(owner1);
        sra.remove(orch);
        vm.prank(owner2);
        sra.remove(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.remove(orch);
        _admitted[orch] = false;
        _frozen[orch] = false;
        _successor[orch] = address(0); // implementation remove: r.orchestrators[orch].successor = 0
        delete _freezeAt[orch]; // implementation remove deletes freezeEpochs/unfreezeEpochs
        delete _unfreezeAt[orch];
        _recordExecuted(taskId);
    }

    /// @notice Atomic freeze.
    function freeze(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (!sra.isAdmitted(orch) || sra.isFrozen(orch)) return;
        bytes32 taskId = _taskId(sra.freeze.selector, abi.encode(orch));
        vm.prank(owner1);
        sra.freeze(orch);
        vm.prank(owner2);
        sra.freeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.freeze(orch);
        _frozen[orch] = true;
        _freezeAt[orch].push(uint64(block.number)); // implementation freeze pushes currentEpoch()
        _recordExecuted(taskId);
    }

    /// @notice Atomic unfreeze.
    function unfreeze(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (!sra.isAdmitted(orch) || !sra.isFrozen(orch)) return;
        bytes32 taskId = _taskId(sra.unfreeze.selector, abi.encode(orch));
        vm.prank(owner1);
        sra.unfreeze(orch);
        vm.prank(owner2);
        sra.unfreeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.unfreeze(orch);
        _frozen[orch] = false;
        _unfreezeAt[orch].push(uint64(block.number)); // implementation unfreeze pushes currentEpoch()
        _recordExecuted(taskId);
    }

    /// @notice Identity transfer: old invalidated (successor=new); frozen state transfers to new via struct copy.
    function replace(uint256 oldIdx, uint256 newIdx) external {
        address oldOrch = _pickOrch(oldIdx);
        address newOrch = _pickOrch(newIdx);
        if (oldOrch == newOrch) return;
        if (!sra.isAdmitted(oldOrch) || sra.isAdmitted(newOrch)) return;
        if (_parkedTarget[newOrch]) return; // must not preempt a parked governance target (I3)
        bytes32 taskId = _taskId(sra.replace.selector, abi.encode(oldOrch, newOrch));
        vm.prank(owner1);
        sra.replace(oldOrch, newOrch);
        vm.prank(owner2);
        sra.replace(oldOrch, newOrch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.replace(oldOrch, newOrch);
        _admitted[oldOrch] = false;
        _successor[oldOrch] = newOrch;
        _successor[newOrch] = address(0); // implementation fully overwrites the newOrch struct (successor zeroed) — key for I2
        _admitted[newOrch] = true;
        _frozen[newOrch] = _frozen[oldOrch];
        // freeze-history deep copy: the implementation's replace fully overwrites the struct (freezeEpochs/unfreezeEpochs
        // transfer with the identity; newOrch's original history is overwritten) — the key alignment for A2 freeze-snapshot determination
        delete _freezeAt[newOrch];
        delete _unfreezeAt[newOrch];
        for (uint256 i = 0; i < _freezeAt[oldOrch].length; i++) {
            _freezeAt[newOrch].push(_freezeAt[oldOrch][i]);
        }
        for (uint256 i = 0; i < _unfreezeAt[oldOrch].length; i++) {
            _unfreezeAt[newOrch].push(_unfreezeAt[oldOrch][i]);
        }
        _recordExecuted(taskId);
    }

    /// @notice Disputed pair reassignment: the target orchestrator must be admitted.
    function reassignBinding(uint256 pairIdx, uint256 orchIdx) external {
        (address payer, address operator) = _pickPair(pairIdx);
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch)) return;
        bytes32 taskId = _taskId(sra.reassignBinding.selector, abi.encode(payer, operator, orch));
        vm.prank(owner1);
        sra.reassignBinding(payer, operator, orch);
        vm.prank(owner2);
        sra.reassignBinding(payer, operator, orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.reassignBinding(payer, operator, orch);
        _setBound(payer, operator, orch);
        _recordExecuted(taskId);
    }

    /// @notice An orchestrator declares binding pairs itself (no governance).
    function registerPairs(uint256 orchIdx, uint256 pairIdx) external {
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch) || sra.isFrozen(orch)) return;
        (address payer, address operator) = _pickPair(pairIdx);
        if (!_claimable(orch, payer, operator)) return;
        Pair[] memory pairs = new Pair[](1);
        pairs[0] = Pair({payer: payer, operator: operator});
        vm.prank(orch);
        sra.registerPairs(pairs);
        _setBound(payer, operator, orch);
    }

    // ========================================================================
    // Business operations (posting / verification / bound windows, explicit roll)
    // ========================================================================

    /// @notice An orchestrator posts a pure-stablecoin FPV (no FIL periods, bypassing PRICE_BAND complexity).
    function postVolume(uint256 q, uint256 orchIdx, uint256 usd) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch) || sra.isFrozen(orch) || _posted[qq][orch]) return;
        // S3: bound(1, 1e30) aligns with the code-enforced MAX_STABLE_USD (postVolume rejects > 1e30) —
        // the invariant's sampling domain equals the contract's enforced input domain.
        uint256 stableUsd = bound(usd, 1, 1e30);
        vm.roll(_qEnd(qq) + 1 + uint64(bound(usd, 0, POST_PERIOD - 1)));
        vm.prank(orch);
        sra.postVolume(qq, _fpv(stableUsd));
        _posted[qq][orch] = true;
    }

    /// @notice Dual-Safe correction/backfill (unanimousNoHold: the second vote executes).
    function correctVolume(uint256 q, uint256 orchIdx, uint256 usd) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch)) return;
        // S3: bound(1, 1e30) aligns with the code-enforced MAX_STABLE_USD (correctVolume rejects > 1e30).
        uint256 stableUsd = bound(usd, 1, 1e30);
        vm.roll(_qPostEnd(qq) + 1 + uint64(bound(usd, 0, VERIFICATION_WINDOW - 1)));
        FPV memory fpv = _fpv(stableUsd);
        vm.prank(owner1);
        sra.correctVolume(orch, qq, fpv);
        vm.prank(owner2);
        sra.correctVolume(orch, qq, fpv);
        _posted[qq][orch] = true;
    }

    /// @notice Finalize conversion (permissionless, idempotent after bound).
    function finalizeConversion(uint256 q) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        vm.roll(_qVerifyEnd(qq) + 1 + uint64(bound(q, 0, 50)));
        sra.finalizeConversion(qq);
    }

    /// @notice Submit shares (permissionless, auto-triggers conversion).
    function submitShares(uint256 q) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        vm.roll(_qVerifyEnd(qq) + 1 + uint64(bound(q, 0, 50)));
        // A3: trigger finalize first (idempotent with submitShares's internal _finalizeConversion),
        // so fpv.usdValue is computed — the snapshot and submitShares traverse read the same data source.
        // ⚠️ the fuzzer's vm.roll can rewind time, possibly constructing a pseudo-timeline where
        // "correctVolume/postVolume write after finalize" (here the implementation's usdValue keeps the
        // finalized value, not recomputed) — reading fpvOf directly makes the handler exactly match the
        // implementation, avoiding the simulation bias of manual usdValue tracking.
        sra.finalizeConversion(qq);
        _snapshotPostEnd(qq); // A2/A3: POST-instant snapshot (frozen set + non-frozen usdValue aggregation)
        sra.submitShares(qq);
        _everSubmitted = true;
        _hasLastSubmit = true;
        _lastSubmitQ = qq;
    }

    // ========================================================================
    // Governance "slow path": parked tasks exist across operations (simulating mid-governance state, invariant I3 verification)
    // ========================================================================

    /// @notice Only two votes (no execution): the admit task enters pending state, existing across operations.
    function parkAdmit(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (sra.isAdmitted(orch) || sra.admittedCount() >= 64) return;
        bytes32 taskId = _taskId(sra.admit.selector, abi.encode(orch));
        if (_taskState[taskId] != 0) return;
        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);
        _taskState[taskId] = 1;
        _parkedOrch[taskId] = orch;
        _parkedEpoch[taskId] = uint64(block.number);
        _parkedTarget[orch] = true;
        _parkedTasks.push(taskId);
    }

    /// @notice Completes all parked tasks (roll to hold-elapsed, then permissionless execution).
    function completeParked() external {
        if (_parkedTasks.length == 0) return;
        uint64 maxTarget = 0;
        for (uint256 i = 0; i < _parkedTasks.length; i++) {
            bytes32 taskId = _parkedTasks[i];
            if (_taskState[taskId] != 1) continue;
            uint64 target = _parkedEpoch[taskId] + SRA_CANCEL_HOLD;
            if (target > maxTarget) maxTarget = target;
        }
        if (block.number < maxTarget) vm.roll(maxTarget);
        bytes32[] memory parked = _parkedTasks; // snapshot then clear
        delete _parkedTasks;
        for (uint256 i = 0; i < parked.length; i++) {
            bytes32 taskId = parked[i];
            if (_taskState[taskId] != 1) continue;
            address orch = _parkedOrch[taskId];
            try sra.admit(orch) {
                _admitted[orch] = true;
                // A2 sync: the implementation's admit identity reset -> handler expected state cleared in sync (same as atomic admit).
                _frozen[orch] = false;
                _successor[orch] = address(0);
                delete _freezeAt[orch];
                delete _unfreezeAt[orch];
                _parkedTarget[orch] = false;
                _recordExecuted(taskId);
            } catch {
                // orch was pre-admitted by an atomic admit -> AlreadyAdmitted revert; the task was already deleted
                _parkedTarget[orch] = false;
                _taskState[taskId] = 3;
            }
        }
    }

    /// @notice Small random time advance (keeps time flowing, explores different window phases).
    function rollForward(uint256 bump) external {
        vm.roll(block.number + uint64(bound(bump, 1, 500)));
    }

    // ========================================================================
    // Query interface (read by the invariant test contract)
    // ========================================================================

    function sraInstance() external view returns (ServiceRewardsActor) {
        return sra;
    }

    function getServiceShares() external view returns (Share[] memory) {
        return rewardActor().getShares(SERVICE_STREAM_ID);
    }

    function everSubmitted() external view returns (bool) {
        return _everSubmitted;
    }

    function hasLastSubmit() external view returns (bool) {
        return _hasLastSubmit;
    }

    function lastSubmitQ() external view returns (uint64) {
        return _lastSubmitQ;
    }

    function lastFrozenCount() external view returns (uint256) {
        return _lastFrozenWallets.length;
    }

    function lastFrozenWallet(uint256 i) external view returns (address) {
        return _lastFrozenWallets[i];
    }

    /// @dev A3: POST-instant aggregation of the most recent submit quarter (total / active count).
    function lastTotals() external view returns (uint256 total, uint256 count) {
        return (_lastTotal, _lastActiveCount);
    }

    function orchPoolLength() external view returns (uint256) {
        return _orchPool.length;
    }

    function orchAt(uint256 i) external view returns (address) {
        return _orchPool[i];
    }

    function expectedAdmitted(address orch) external view returns (bool) {
        return _admitted[orch];
    }

    function expectedFrozen(address orch) external view returns (bool) {
        return _frozen[orch];
    }

    /// @dev Handler-side resolution along the replace chain (same semantics as the implementation's _resolve).
    function resolveHandled(address orch) external view returns (address) {
        address cur = orch;
        while (cur != address(0) && _successor[cur] != address(0)) {
            cur = _successor[cur];
        }
        return cur;
    }

    function knownPairsLength() external view returns (uint256) {
        return _pairs.length;
    }

    function pairRecordAt(uint256 i) external view returns (address payer, address operator, address boundOrch) {
        return (_pairs[i].payer, _pairs[i].operator, _pairs[i].boundOrch);
    }

    function parkedCount() external view returns (uint256) {
        return _parkedTasks.length;
    }

    function parkedTaskId(uint256 i) external view returns (bytes32) {
        return _parkedTasks[i];
    }

    function parkedOrch(uint256 i) external view returns (address) {
        return _parkedOrch[_parkedTasks[i]];
    }

    function executedCount() external view returns (uint256) {
        return _executedTasks.length;
    }

    function executedTaskId(uint256 i) external view returns (bytes32) {
        return _executedTasks[i];
    }

    /// @dev Reads the PendingTask approved bitmask (PendingTask{modified:uint96, approvals:uint160} packed into one slot).
    function approvalsOf(bytes32 taskId) external view returns (uint160) {
        bytes32 slot = keccak256(abi.encode(taskId, PENDING_TASKS_SLOT));
        return uint160(uint256(vm.load(address(sra), slot)) >> 96);
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    function _pickOrch(uint256 idx) internal view returns (address) {
        return _orchPool[bound(idx, 0, ORCH_POOL - 1)];
    }

    function _pickPair(uint256 idx) internal view returns (address payer, address operator) {
        uint256 i = bound(idx, 0, PAYER_POOL * OPERATOR_POOL - 1);
        payer = _payers[i / OPERATOR_POOL];
        operator = _operators[i % OPERATOR_POOL];
    }

    function _taskId(bytes4 selector, bytes memory args) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(selector, args));
    }

    function _recordExecuted(bytes32 taskId) internal {
        _taskState[taskId] = 2;
        _executedTasks.push(taskId);
    }

    /// @dev A2/A3: records the POST-instant snapshot of quarter qq — the set of active orchestrators frozen at the POST
    ///      instant, and the Σ and count of non-frozen with usdValue>0 (consistent with the implementation's submitShares
    ///      admittedList traversal exclusion semantics). Freeze determination uses the handler-recorded freeze intervals
    ///      (not depending on the current block.number); usdValue reads the implementation's fpvOf directly (post-finalize),
    ///      the same data source as the submitShares traversal.
    function _snapshotPostEnd(uint64 qq) internal {
        uint64 postEnd = _qPostEnd(qq);
        delete _lastFrozenWallets;
        _lastTotal = 0;
        _lastActiveCount = 0;
        for (uint256 i = 0; i < _orchPool.length; i++) {
            address orch = _orchPool[i];
            if (!sra.isAdmitted(orch)) continue;
            bool frozenAtPost = _isFrozenAtHandled(orch, postEnd);
            if (frozenAtPost) {
                // the implementation excludes the orch itself (_frozenAtPostEnd continue, producing no wallet)
                _lastFrozenWallets.push(orch);
                continue;
            }
            uint256 usd = sra.fpvOf(qq, orch).usdValue; // post-finalize, reads the same field as submitShares
            if (usd > 0) {
                _lastTotal += usd;
                _lastActiveCount++;
            }
        }
    }

    /// @dev Determines whether the epoch falls inside any [freezeAt[i], unfreezeAt[i]) freeze interval (same semantics as the implementation's _isFrozenAt).
    function _isFrozenAtHandled(address orch, uint64 e) internal view returns (bool) {
        uint256 n = _freezeAt[orch].length;
        for (uint256 i = 0; i < n; i++) {
            if (e >= _freezeAt[orch][i]) {
                if (i < _unfreezeAt[orch].length && e >= _unfreezeAt[orch][i]) {
                    continue; // this interval already unfrozen; check the next
                }
                return true;
            }
            return false; // freezeAt is increasing; later ones are even larger
        }
        return false;
    }

    /// @dev Whether a pair is claimable: unbound, or its binder has been removed (unclaimed).
    function _claimable(address orch, address payer, address operator) internal view returns (bool) {
        address cur = sra.bindingOf(payer, operator);
        if (cur == address(0)) return true;
        if (cur == orch) return false; // already bound to self -> AlreadyBound
        return !sra.isAdmitted(cur); // binder removed -> claimable
    }

    function _setBound(address payer, address operator, address orch) internal {
        bytes32 pairId = keccak256(abi.encode(payer, operator));
        uint256 idx = _pairIdx[pairId];
        if (idx == 0) {
            _pairs.push(PairRecord({payer: payer, operator: operator, boundOrch: orch}));
            _pairIdx[pairId] = _pairs.length;
        } else {
            _pairs[idx - 1].boundOrch = orch;
        }
    }
}

/// @notice Invariant test entry: targetContract(handler), 3 core invariants.
contract SRAInvariantTest is Test {
    SRAInvariantHandler internal handler;

    function setUp() public {
        handler = new SRAInvariantHandler();
        handler.setUp(); // deploy SRA + Safe owners + service stream 2
        targetContract(address(handler));
        // explicitly limit the handler's operation function set — excluding setUp() (public; otherwise the fuzzer would
        // treat it as a target and randomly call it, resetting the sra instance and diverging the handler's expected state
        // from reality; also the root cause of non-contract mock errors)
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = SRAInvariantHandler.admit.selector;
        selectors[1] = SRAInvariantHandler.remove.selector;
        selectors[2] = SRAInvariantHandler.freeze.selector;
        selectors[3] = SRAInvariantHandler.unfreeze.selector;
        selectors[4] = SRAInvariantHandler.replace.selector;
        selectors[5] = SRAInvariantHandler.reassignBinding.selector;
        selectors[6] = SRAInvariantHandler.registerPairs.selector;
        selectors[7] = SRAInvariantHandler.postVolume.selector;
        selectors[8] = SRAInvariantHandler.correctVolume.selector;
        selectors[9] = SRAInvariantHandler.finalizeConversion.selector;
        selectors[10] = SRAInvariantHandler.submitShares.selector;
        selectors[11] = SRAInvariantHandler.parkAdmit.selector;
        selectors[12] = SRAInvariantHandler.completeParked.selector;
        selectors[13] = SRAInvariantHandler.rollForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// I1 Share conservation: after any operation sequence, the share Σ written by the most recent successful submitShares is always == 1e18.
    /// Catches: wrong share top-up direction causing Σ≠1e18, freeze-exclusion omission, recipient omission, all-zero burn path breakage.
    function invariant_SumShares_IsShareTotal() public {
        if (!handler.everSubmitted()) return; // never successfully submitted; no shares to query
        Share[] memory shares = handler.getServiceShares();
        if (shares.length == 0) return;
        uint256 sum;
        for (uint256 i = 0; i < shares.length; i++) {
            sum += shares[i].share;
        }
        assertEq(sum, 1e18, "I1: sum of shares must equal SHARE_TOTAL");
    }

    /// I2 Binding uniqueness: every pair's bindingOf must == the handler-recorded last binder (resolved along the replace chain).
    /// Catches: the T6 bug (third-party grabbing the same pair after replace, overwriting the binding),
    ///        registerPairs bypassing the uniqueness check, reassignBinding writes inconsistent with the record.
    function invariant_OneBindingPerPair() public view {
        uint256 n = handler.knownPairsLength();
        for (uint256 i = 0; i < n; i++) {
            (address payer, address operator, address boundOrch) = handler.pairRecordAt(i);
            address expected = handler.resolveHandled(boundOrch);
            assertEq(
                handler.sraInstance().bindingOf(payer, operator),
                expected,
                "I2: bindingOf must match handler-recorded binder"
            );
        }
    }

    /// I3 Governance consistency:
    ///   a) parked tasks (two votes, not executed) have a non-zero bitmask, and the orchestrator state has not landed (task not executed);
    ///   b) executed tasks have a zeroed bitmask (taskInfo.task deleted after execution);
    ///   c) handler-expected orchestrator state == sra actual (governance task execution results land correctly).
    /// Catches: un-cleared state after governance task execution (bitmask residue), function-body state changes
    ///        diverging from the governance flow, replace/remove identity-transfer state not synchronized.
    function invariant_GovernanceTasks_Consistent() public view {
        // a) parked tasks
        uint256 p = handler.parkedCount();
        for (uint256 i = 0; i < p; i++) {
            bytes32 taskId = handler.parkedTaskId(i);
            uint160 approvals = handler.approvalsOf(taskId);
            assertTrue(approvals != 0, "I3a: parked task approvals must be non-zero");
            // task not executed -> orchestrator state not landed
            address orch = handler.parkedOrch(i);
            assertFalse(handler.sraInstance().isAdmitted(orch), "I3a: parked admit must not be applied");
        }
        // b) executed tasks bitmask cleared
        uint256 e = handler.executedCount();
        for (uint256 i = 0; i < e; i++) {
            bytes32 taskId = handler.executedTaskId(i);
            assertEq(handler.approvalsOf(taskId), 0, "I3b: executed task approvals must be cleared");
        }
        // c) handler expected state == sra actual
        uint256 n = handler.orchPoolLength();
        for (uint256 i = 0; i < n; i++) {
            address orch = handler.orchAt(i);
            assertEq(
                handler.sraInstance().isAdmitted(orch), handler.expectedAdmitted(orch), "I3c: admitted state mismatch"
            );
            assertEq(handler.sraInstance().isFrozen(orch), handler.expectedFrozen(orch), "I3c: frozen state mismatch");
        }
    }

    /// A2 Freeze snapshot: in the most recent submit quarter, active orchestrators frozen at the POST instant (the address
    /// itself — the implementation's _frozenAtPostEnd continue excludes that orchestrator, producing no wallet) must not
    /// appear in the share map (S5 strict snapshot: in-window unfreeze/freeze changes do not affect the quarter).
    /// Catches: freeze-exclusion omission (_frozenAtPostEnd determination error, freeze-interval pairing misalignment),
    ///        frozen identity not transferring with the struct after replace (A2 is the only machine verification covering this semantics).
    function invariant_FrozenAtPostEnd_ExcludedFromShares() public {
        if (!handler.hasLastSubmit()) return;
        Share[] memory shares = handler.getServiceShares();
        uint256 n = handler.lastFrozenCount();
        for (uint256 i = 0; i < n; i++) {
            address frozenWallet = handler.lastFrozenWallet(i);
            for (uint256 j = 0; j < shares.length; j++) {
                assertTrue(
                    shares[j].wallet != frozenWallet, "A2: frozen-at-POST-end orchestrator must not receive shares"
                );
            }
        }
    }

    /// A3 All-zero burn (D1): in the most recent submit quarter, if the Σ of non-frozen with usdValue>0 at the POST instant
    /// is 0 -> the share map is a single BURN_ADDRESS record (share == SHARE_TOTAL); if Σ>0 -> the map is a non-empty subset
    /// of the active orchestrators (zero-share entries trimmed), all entries non-zero, size <= active count.
    /// usdValue reads the implementation's fpvOf directly (finalized before the snapshot), the same data source as the
    /// submitShares traversal — covering the boundary semantics that usdValue keeps the finalized value after correctVolume/postVolume writes.
    /// Catches: the D1 burn branch missing/wrong (not burned at total==0, or burned to the wrong address),
    ///        usdValue aggregation omission (an poster miscounted causing a false total-zero determination), freeze-exclusion count misalignment.
    function invariant_ZeroTotal_BurnsToBurnAddress() public {
        if (!handler.hasLastSubmit()) return;
        Share[] memory shares = handler.getServiceShares();
        (uint256 total, uint256 count) = handler.lastTotals();
        if (total == 0) {
            assertEq(shares.length, 1, "A3: zero total must produce a single burn entry");
            assertEq(shares[0].wallet, BURN_ADDRESS, "A3: burn entry wallet must be BURN_ADDRESS");
            assertEq(shares[0].share, 1e18, "A3: burn entry share must be SHARE_TOTAL");
        } else {
            // The implementation trims zero-share entries (largest-remainder can floor a tiny
            // usdValue to 0 when the residue top-up round count is smaller than the active count),
            // so the map holds a non-empty subset of the active orchestrators, all non-zero.
            assertGt(shares.length, 0, "A3: non-zero total must produce at least one share");
            assertLe(shares.length, count, "A3: share count must not exceed active orchestrator count");
            for (uint256 i = 0; i < shares.length; i++) {
                assertGt(shares[i].share, 0, "A3: trimmed map must contain only non-zero shares");
            }
        }
    }
}
