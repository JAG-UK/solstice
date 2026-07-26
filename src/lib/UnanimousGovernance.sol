// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch, currentEpoch} from "./Epoch.sol";
import {EMPTY_SET, OwnerSet} from "./OwnerSet.sol";
import {PendingTask, PendingTaskInfo, PendingTaskLibrary} from "./PendingTask.sol";
import {OwnersLibrary} from "./Owners.sol";

contract UnanimousGovernance {
    using OwnersLibrary for address;

    Epoch constant NO_HOLD = Epoch.wrap(0);
    Epoch constant UNSUBMITTED = Epoch.wrap(0);

    event Submitted(bytes32 indexed taskId);
    event Approved(bytes32 indexed taskId, address indexed owner);
    event Rejected(bytes32 indexed taskId, address indexed owner);

    error HoldUntil(Epoch until);
    error NotOwner(address account);
    error AlreadyApproved();

    modifier unanimous(bytes32 taskId, Epoch hold) {
        // load
        PendingTaskInfo storage taskInfo = PendingTaskLibrary.getTasksSlot()[taskId];
        PendingTask memory loaded = taskInfo.task;
        OwnerSet allOwners = OwnersLibrary.getAllOwners();

        // modify
        if (loaded.approvals & allOwners == allOwners) {
            // already approved: permissionless completion
            Epoch until = loaded.modified + hold;
            require(currentEpoch() >= until, HoldUntil(until));
            // execute
            delete taskInfo.task;
            _;
        } else {
            // approve
            require(msg.sender.isOwner(), NotOwner(msg.sender));
            OwnerSet sig = msg.sender.asOwnerSet();
            if (loaded.modified == UNSUBMITTED) {
                emit Submitted(taskId);
            } else {
                require(loaded.approvals & sig == EMPTY_SET, AlreadyApproved());
            }
            loaded.modified = currentEpoch();
            loaded.approvals = loaded.approvals | sig;

            // store result
            emit Approved(taskId, msg.sender);
            if (hold == NO_HOLD && loaded.approvals & allOwners == allOwners) {
                delete taskInfo.task;
                // execute now
                _;
            } else {
                // wait
                taskInfo.task = loaded;
            }
        }
    }

    function _veto(bytes32 taskId) internal {
        // load
        PendingTaskInfo storage taskInfo = PendingTaskLibrary.getTasksSlot()[taskId];

        // modify
        require(msg.sender.isOwner(), NotOwner(msg.sender));
        delete taskInfo.task;

        emit Rejected(taskId, msg.sender);
    }
}
