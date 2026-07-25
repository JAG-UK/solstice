// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Epoch, currentEpoch} from "../src/lib/Epoch.sol";
import {AddressXorSet, EMPTY_SET} from "../src/lib/AddressXorSet.sol";
import {PendingTask, PendingTaskLibrary} from "../src/lib/PendingTask.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";
import {TwoSafeRuler} from "../src/lib/TwoSafeRule.sol";

// wraps the internal modifier with two administrator actions so vm.expectRevert/vm.expectEmit
// have a real call frame to target. Mirrors planned usage: each action's hold is a constant
// baked into its `unanimous` invocation, and the taskId is just keccak256(msg.data), i.e. the
// method selector plus its parameters.
contract TwoSafeRuleHarness is TwoSafeRuler {
    Epoch public constant ADD_OWNER_HOLD = Epoch.wrap(0);
    Epoch public constant REMOVE_OWNER_HOLD = Epoch.wrap(10);

    // test-only bootstrap: seeds the owner set without going through the unanimous modifier
    function seedOwner(address owner) external {
        OwnersLibrary.addOwner(owner);
    }

    function isOwner(address someone) external view returns (bool) {
        return OwnersLibrary.isOwner(someone);
    }

    // exposes raw pending-task state so tests can assert on it directly,
    // rather than only inferring it from events or final owner-set membership
    function getPendingTask(bytes32 taskId) external view returns (Epoch modified, AddressXorSet approvals) {
        PendingTask memory task = PendingTaskLibrary.getTasksSlot()[taskId].task;
        return (task.modified, task.approvals);
    }

    function addOwnerTaskId(address owner) public pure returns (bytes32) {
        return keccak256(abi.encodeWithSelector(this.addOwner.selector, owner));
    }

    function removeOwnerTaskId(address owner, uint256 ownersRosterIndex) public pure returns (bytes32) {
        return keccak256(abi.encodeWithSelector(this.removeOwner.selector, owner, ownersRosterIndex));
    }

    function addOwner(address owner) external unanimous(keccak256(msg.data), ADD_OWNER_HOLD) {
        OwnersLibrary.addOwner(owner);
    }

    function removeOwner(address owner, uint256 ownersRosterIndex)
        external
        unanimous(keccak256(msg.data), REMOVE_OWNER_HOLD)
    {
        OwnersLibrary.removeOwner(owner, ownersRosterIndex);
    }

    function vetoAddOwner(address owner) external {
        _veto(addOwnerTaskId(owner));
    }

    function vetoRemoveOwner(address owner, uint256 ownersRosterIndex) external {
        _veto(removeOwnerTaskId(owner, ownersRosterIndex));
    }
}

contract TwoSafeRuleTest is Test {
    TwoSafeRuleHarness harness;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    address newOwner = makeAddr("newOwner");

    function setUp() public {
        harness = new TwoSafeRuleHarness();
    }

    function test_addOwner_singleOwner_executesImmediately() public {
        harness.seedOwner(alice);
        bytes32 taskId = harness.addOwnerTaskId(newOwner);

        vm.expectEmit(true, false, false, false, address(harness));
        emit TwoSafeRuler.Submitted(taskId);
        vm.expectEmit(true, true, false, false, address(harness));
        emit TwoSafeRuler.Approved(taskId, alice);
        vm.expectEmit(true, false, false, false, address(harness));
        emit OwnersLibrary.OwnerAdded(newOwner);

        vm.prank(alice);
        harness.addOwner(newOwner);

        assertTrue(harness.isOwner(newOwner));
    }

    function test_addOwner_twoOwners_requiresBothApprovals() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        bytes32 taskId = harness.addOwnerTaskId(newOwner);

        vm.expectEmit(true, false, false, false, address(harness));
        emit TwoSafeRuler.Submitted(taskId);
        vm.expectEmit(true, true, false, false, address(harness));
        emit TwoSafeRuler.Approved(taskId, alice);
        vm.prank(alice);
        harness.addOwner(newOwner);

        // only one of two owners has approved: not yet executed
        assertFalse(harness.isOwner(newOwner));
        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET.add(alice));

        vm.expectEmit(true, true, false, false, address(harness));
        emit TwoSafeRuler.Approved(taskId, bob);
        vm.expectEmit(true, false, false, false, address(harness));
        emit OwnersLibrary.OwnerAdded(newOwner);
        vm.prank(bob);
        harness.addOwner(newOwner);

        assertTrue(harness.isOwner(newOwner));
        // executed: the task record is deleted
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);
    }

    function test_addOwner_threeOwners_partialApprovalDoesNotExecute() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        harness.seedOwner(carol);
        bytes32 taskId = harness.addOwnerTaskId(newOwner);

        vm.prank(alice);
        harness.addOwner(newOwner);
        vm.prank(bob);
        harness.addOwner(newOwner);
        assertFalse(harness.isOwner(newOwner));
        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET.add(alice).add(bob));

        vm.prank(carol);
        harness.addOwner(newOwner);
        assertTrue(harness.isOwner(newOwner));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);
    }

    function test_addOwner_nonOwner_cannotApprove() public {
        harness.seedOwner(alice);

        vm.expectRevert(abi.encodeWithSelector(TwoSafeRuler.NotOwner.selector, stranger));
        vm.prank(stranger);
        harness.addOwner(newOwner);
    }

    function test_removeOwner_withHold_delaysExecutionUntilPermissionlessFinalize() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        bytes32 taskId = harness.removeOwnerTaskId(bob, 1);

        // unanimous requires every current owner to approve, including the
        // one being removed, so bob must approve his own removal
        vm.prank(alice);
        harness.removeOwner(bob, 1);

        Epoch approvalEpoch = currentEpoch();
        vm.prank(bob);
        harness.removeOwner(bob, 1);

        // both owners approved, but the hold delays execution
        assertTrue(harness.isOwner(bob));
        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == approvalEpoch);
        assertTrue(approvals == EMPTY_SET.add(alice).add(bob));

        // too early: reverts even for an owner
        Epoch until = approvalEpoch + harness.REMOVE_OWNER_HOLD();
        vm.expectRevert(abi.encodeWithSelector(TwoSafeRuler.HoldUntil.selector, until));
        vm.prank(alice);
        harness.removeOwner(bob, 1);

        // the revert left the pending task untouched
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == approvalEpoch);
        assertTrue(approvals == EMPTY_SET.add(alice).add(bob));

        vm.roll(Epoch.unwrap(approvalEpoch + harness.REMOVE_OWNER_HOLD()));

        // permissionless: a non-owner can finalize once the hold has elapsed
        vm.expectEmit(true, false, false, false, address(harness));
        emit OwnersLibrary.OwnerRemoved(bob);
        vm.prank(stranger);
        harness.removeOwner(bob, 1);

        assertFalse(harness.isOwner(bob));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);
    }

    function test_veto_duringHoldingPeriod_cancelsBeforeFinalize() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        bytes32 taskId = harness.removeOwnerTaskId(bob, 1);

        vm.prank(alice);
        harness.removeOwner(bob, 1);
        Epoch approvalEpoch = currentEpoch();
        vm.prank(bob);
        harness.removeOwner(bob, 1);

        // fully approved, but still within the hold: veto is still possible
        assertTrue(harness.isOwner(bob));
        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == approvalEpoch);
        assertTrue(approvals == EMPTY_SET.add(alice).add(bob));

        vm.expectEmit(true, true, false, false, address(harness));
        emit TwoSafeRuler.Rejected(taskId, alice);
        vm.prank(alice);
        harness.vetoRemoveOwner(bob, 1);

        assertTrue(harness.isOwner(bob));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);

        // even once the original hold window would have elapsed, the task
        // was cleared, so finalizing now just restarts approval from scratch
        vm.roll(Epoch.unwrap(currentEpoch() + harness.REMOVE_OWNER_HOLD()));

        vm.expectEmit(true, false, false, false, address(harness));
        emit TwoSafeRuler.Submitted(taskId);
        vm.prank(alice);
        harness.removeOwner(bob, 1);

        assertTrue(harness.isOwner(bob));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET.add(alice));
    }

    function test_veto_resetsPendingTask() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        bytes32 taskId = harness.addOwnerTaskId(newOwner);

        vm.prank(alice);
        harness.addOwner(newOwner);
        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET.add(alice));

        vm.expectEmit(true, true, false, false, address(harness));
        emit TwoSafeRuler.Rejected(taskId, bob);
        vm.prank(bob);
        harness.vetoAddOwner(newOwner);

        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);

        // the task was cleared: a fresh Submitted event fires on the next approval
        vm.expectEmit(true, false, false, false, address(harness));
        emit TwoSafeRuler.Submitted(taskId);
        vm.prank(alice);
        harness.addOwner(newOwner);

        assertFalse(harness.isOwner(newOwner));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET.add(alice));
    }

    function test_veto_onlyOwnerCanVeto() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);

        vm.prank(alice);
        harness.addOwner(newOwner);

        vm.expectRevert(abi.encodeWithSelector(TwoSafeRuler.NotOwner.selector, stranger));
        vm.prank(stranger);
        harness.vetoAddOwner(newOwner);
    }

    function test_doubleApproval_byOwner_cancelsPreviousApproval() public {
        harness.seedOwner(alice);
        harness.seedOwner(bob);
        harness.seedOwner(carol);
        bytes32 taskId = harness.addOwnerTaskId(newOwner);

        // alice approves, then approves again before the others: the xor-set
        // approval accounting cancels her first approval out (see the NOTE
        // in TwoSafeRule.sol acknowledging this is not guarded against)
        vm.prank(alice);
        harness.addOwner(newOwner);
        vm.prank(alice);
        harness.addOwner(newOwner);

        (Epoch modified, AddressXorSet approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == currentEpoch());
        assertTrue(approvals == EMPTY_SET);

        vm.prank(bob);
        harness.addOwner(newOwner);
        vm.prank(carol);
        harness.addOwner(newOwner);

        // alice's approval was cancelled out, so only bob and carol are
        // recorded: the task is not yet fully approved
        assertFalse(harness.isOwner(newOwner));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(approvals == EMPTY_SET.add(bob).add(carol));

        vm.prank(alice);
        harness.addOwner(newOwner);

        assertTrue(harness.isOwner(newOwner));
        (modified, approvals) = harness.getPendingTask(taskId);
        assertTrue(modified == Epoch.wrap(0));
        assertTrue(approvals == EMPTY_SET);
    }
}
