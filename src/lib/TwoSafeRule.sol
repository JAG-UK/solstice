// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch, currentEpoch} from "./Epoch.sol";
import {AddressXorSet} from "./AddressXorSet.sol";
import {PendingTask, PendingTaskInfo, PendingTaskLibrary} from "./PendingTask.sol";
import {OwnersLibrary} from "./Owners.sol";

contract TwoSafeRuler {
    using OwnersLibrary for address;

    Epoch constant NO_HOLD = Epoch.wrap(0);
    Epoch constant NEVER = Epoch.wrap(0);

    event Submitted(bytes32 indexed taskId);
    event Approved(bytes32 indexed taskId, address indexed owner);
    event Rejected(bytes32 indexed taskId, address indexed owner);

    error HoldUntil(Epoch until);
    error NotOwner(address account);

    modifier unanimous(bytes32 taskId, Epoch hold) {
        // load
        PendingTaskInfo storage taskInfo = PendingTaskLibrary.getTasksSlot()[taskId];
        PendingTask memory loaded = taskInfo.task;
        AddressXorSet allOwners = OwnersLibrary.getAllOwners();

        // modify
        if (loaded.approvals == allOwners) {
            // already approved: permissionless completion
            require(currentEpoch() - loaded.modified >= hold, HoldUntil(loaded.modified + hold));
            // execute
            delete taskInfo.task;
            _;
        } else {
            // approve
            require(msg.sender.isOwner(), NotOwner(msg.sender));
            if (loaded.modified == NEVER) {
                emit Submitted(taskId);
            } else {
                // NOTE we can just assume they won't do this:
                // require(!loaded.approvals.contains(msg.sender, OwnersLibrary.loadOwnersRoster()), AlreadyApproved());
            }
            loaded.modified = currentEpoch();
            loaded.approvals = loaded.approvals.add(msg.sender);

            // store result
            emit Approved(taskId, msg.sender);
            if (hold == NO_HOLD && loaded.approvals == allOwners) {
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
