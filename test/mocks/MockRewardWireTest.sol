// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {REWARD_ACTOR_ADDRESS} from "fvm-solidity/FVMActors.sol";

import {FVMCallActorByIdWithReward} from "./FVMCallActorByIdWithReward.sol";
import {FVMRewardParamsRecorder} from "./FVMRewardParamsRecorder.sol";

/// @notice Etches a params-recording stand-in for f02 rather than the full stateful mock: the
///         wire-format tests only need the exact bytes FVMRewards sent, not f02's business logic.
contract MockRewardWireTest is MockFVMTest {
    function setUp() public virtual override {
        super.setUp();
        vm.etch(REWARD_ACTOR_ADDRESS, address(new FVMRewardParamsRecorder()).code);
        vm.etch(CALL_ACTOR_BY_ID, address(new FVMCallActorByIdWithReward(vm)).code);
    }

    function rewardActor() internal pure returns (FVMRewardParamsRecorder) {
        return FVMRewardParamsRecorder(REWARD_ACTOR_ADDRESS);
    }
}
