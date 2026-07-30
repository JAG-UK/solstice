// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";
import {OwnerSet} from "./OwnerSet.sol";

struct PendingTask {
    Epoch modified;
    OwnerSet approvals;
}

struct PendingTaskInfo {
    PendingTask task;
}

library PendingTaskLibrary {
    /// @custom:storage-location erc7201:Solstice.PendingTasks
    struct PendingTasks {
        mapping(bytes32 taskId => PendingTaskInfo) tasks;
    }

    // keccak256(abi.encode(uint256(keccak256("Solstice.PendingTasks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PENDING_TASKS_SLOT = 0x635f64a8ec66823e68578973f5bc466fd4e0eadd655f760cfc91e860524aa300;

    function getTasksSlot() internal pure returns (mapping(bytes32 taskId => PendingTaskInfo) storage tasks) {
        assembly ("memory-safe") {
            tasks.slot := PENDING_TASKS_SLOT
        }
    }
}
