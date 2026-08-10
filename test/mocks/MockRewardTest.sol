// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {REWARD_ACTOR_ADDRESS} from "fvm-solidity/FVMActors.sol";

import {FVMCallActorByIdWithReward} from "./FVMCallActorByIdWithReward.sol";
import {FVMRewardActor} from "./FVMRewardActor.sol";

/// @notice Extends fvm-solidity's MockFVMTest with a mock f02 (Reward actor) covering its
///         stream-splitting methods.
contract MockRewardTest is MockFVMTest {
    function setUp() public virtual override {
        super.setUp();
        vm.etch(REWARD_ACTOR_ADDRESS, address(new FVMRewardActor(vm)).code);
        FVMRewardActor(REWARD_ACTOR_ADDRESS).mockInit();
        vm.etch(
            CALL_ACTOR_BY_ID, address(new FVMCallActorByIdWithReward(vm, FVMRewardActor(REWARD_ACTOR_ADDRESS))).code
        );
    }

    function rewardActor() internal pure returns (FVMRewardActor) {
        return FVMRewardActor(REWARD_ACTOR_ADDRESS);
    }
}
