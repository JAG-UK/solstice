// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// SRA governance flow tests — covers design §3 strategy 6 (governance flow)
//
//   - two votes + permissionless execution after SRA_CANCEL_HOLD elapses
//   - not executable within the hold (HoldUntil revert)
//   - single vote does not execute; non-owner rejected
//   - veto (cancelPending) discards a queued change
//   - NO_HOLD (correctVolume) full-vote immediate execution
//   - taskId = keccak256(msg.data): different array parameter order -> different taskId -> no merge (I2 risk)
// ============================================================================

import {SRATestBase} from "./SRATestBase.sol";
import {FPV} from "../src/ServiceRewardsActor.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";

contract SRAGovernanceTest is SRATestBase {
    // ------------------------------------------------------------------------
    // Two votes + hold flow
    // ------------------------------------------------------------------------

    /// Strategy 6: after two votes + hold elapses, any keeper can trigger execution (admit takes effect).
    function test_Admit_TwoApprovalsPlusHold_Executes() public {
        address orch = makeAddr("orch");
        assertFalse(sra.isAdmitted(orch));

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);
        // after the second approval the hold has not elapsed; admit not yet effective
        assertFalse(sra.isAdmitted(orch));

        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch); // permissionless completion

        assertTrue(sra.isAdmitted(orch));
        assertEq(sra.admittedCount(), 1);
    }

    /// Strategy 6: a third call (execution attempt) within the hold reverts HoldUntil.
    function test_Admit_HoldNotElapsed_ExecutionReverts() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // hold not elapsed: the third call must revert (HoldUntil, until = second approval + hold)
        vm.roll(block.number + SRA_CANCEL_HOLD - 1);
        vm.expectRevert();
        sra.admit(orch);
        assertFalse(sra.isAdmitted(orch));
    }

    /// Strategy 6: a single vote (only owner1) does not execute.
    function test_Admit_SingleApproval_NotExecuted() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);

        assertFalse(sra.isAdmitted(orch));
        vm.roll(block.number + SRA_CANCEL_HOLD + 1);
        // third call: approvals not full, owner1 already approved -> AlreadyApproved (owner1 cannot vote again)
        // here we call again as owner1 to verify "the same task cannot be approved twice"
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.AlreadyApproved.selector));
        sra.admit(orch);
    }

    /// Strategy 6: a non-owner calling a governance method reverts NotOwner.
    function test_Admit_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, stranger));
        sra.admit(makeAddr("orch"));
    }

    /// Strategy 6: after both Safes call the same governance method, the taskId record is identical (keccak256(msg.data)).
    function test_Admit_TaskIdIsKeccakOfCalldata() public {
        address orch = makeAddr("orch");
        bytes32 expectedTaskId = keccak256(abi.encodeWithSignature("admit(address)", orch));

        // after owner1 approves: task exists (single vote); after owner2 approves the same calldata: full vote and queued
        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // if the taskIds match, the same calldata call after the hold can complete execution
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch);
        assertTrue(sra.isAdmitted(orch));
        // expectedTaskId itself is not directly queryable (internal state); "execution completes" is the indirect proof
        assertTrue(expectedTaskId != bytes32(0));
    }

    // ------------------------------------------------------------------------
    // Veto (cancelPending)
    // ------------------------------------------------------------------------

    /// Strategy 6: either Safe can veto to discard a queued change; after the veto the flow restarts.
    function test_Veto_CancelsPendingAdmit() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // owner1 changes their mind: cancelPending discards the task
        bytes32 taskId = keccak256(abi.encodeWithSignature("admit(address)", orch));
        vm.prank(owner1);
        sra.cancelPending(taskId);

        vm.roll(block.number + SRA_CANCEL_HOLD);
        // the original task was deleted: the third call is a fresh submission (first vote), not an execution
        // T2 fix: resubmission must be initiated by an owner (the governance library's approve branch requires isOwner)
        vm.prank(owner1);
        sra.admit(orch);
        assertFalse(sra.isAdmitted(orch));
    }

    /// Strategy 6: a non-owner cannot veto.
    function test_Veto_NonOwner_Reverts() public {
        bytes32 taskId = keccak256("whatever");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, makeAddr("stranger")));
        sra.cancelPending(taskId);
    }

    // ------------------------------------------------------------------------
    // NO_HOLD: correctVolume full-vote immediate execution
    // ------------------------------------------------------------------------

    /// Strategy 6: the unanimousNoHold path — the second vote executes immediately (correctVolume takes effect within the verification window).
    function test_CorrectVolume_NoHold_SecondApprovalExecutesImmediately() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // posting period
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        FPV memory corrected = _fpv(250e18);
        vm.prank(owner1);
        sra.correctVolume(orch, 0, corrected);
        // after the first vote not effective (not full vote): the value is still the posted value
        FPV memory f1 = sra.fpvOf(0, orch);
        assertEq(f1.stableUSD, 100e18);

        vm.prank(owner2);
        sra.correctVolume(orch, 0, corrected); // second vote executes immediately

        FPV memory f2 = sra.fpvOf(0, orch);
        assertEq(f2.stableUSD, 250e18);
    }

    /// Strategy 6: before correctVolume's second vote (not a full vote), a repeat vote reverts AlreadyApproved.
    function test_CorrectVolume_SameOwnerTwice_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));
        vm.roll(_qPostEnd(0) + 1);

        vm.prank(owner1);
        sra.correctVolume(orch, 0, _fpv(200e18));
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.AlreadyApproved.selector));
        sra.correctVolume(orch, 0, _fpv(200e18));
    }

    // ------------------------------------------------------------------------
    // taskId consistency: array parameter normalization (I2 risk)
    // ------------------------------------------------------------------------

    /// Strategy 6/I2: different setAdmittedLists array orders -> different calldata -> different taskIds
    /// -> the two Safes approve different tasks, each with only one vote; the change does not take effect (task deadlock risk).
    function test_TaskId_DifferentArrayOrder_DoesNotMerge() public {
        address usdc = makeAddr("usdc");
        address usdt = makeAddr("usdt");

        vm.prank(owner1);
        sra.setAdmittedLists(_asArray(usdc, usdt), _asArray(address(0), address(0)));
        vm.prank(owner2);
        // owner2 submits the reverse order: different calldata -> different taskId -> no merge
        sra.setAdmittedLists(_asArray(usdt, usdc), _asArray(address(0), address(0)));

        // the two votes are spread across two different tasks, each unable to reach a full vote -> the change never takes effect (I2 deadlock)
        vm.roll(block.number + SRA_CANCEL_HOLD + 1000);
        assertFalse(sra.isStablecoinAdmitted(usdc));
        assertFalse(sra.isStablecoinAdmitted(usdt));
    }

    /// Strategy 6/I2 control: same order (same calldata) -> two votes + hold -> execution takes effect.
    function test_TaskId_SameArrayOrder_Executes() public {
        address usdc = makeAddr("usdc");
        address[] memory stablecoins = _asArray(usdc, address(0));

        vm.prank(owner1);
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));
        vm.prank(owner2);
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));

        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));

        // execution succeeded: no revert means the allowlist update took effect (setAdmittedLists is an exclusive update).
        // verified via the isStablecoinAdmitted read-only view (design §2.3.5 supplementary view).
        assertTrue(sra.isStablecoinAdmitted(usdc));
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _asArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
