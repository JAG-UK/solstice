// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {REWARD_ACTOR_ID} from "fvm-solidity/FVMActors.sol";
import {NO_FLAGS, READONLY_FLAG} from "fvm-solidity/FVMFlags.sol";
import {USR_ILLEGAL_ARGUMENT} from "fvm-solidity/FVMErrors.sol";
import {FVMCallActorById} from "fvm-solidity/mocks/FVMCallActorById.sol";

import {FVMRewardActor} from "./FVMRewardActor.sol";

/// @notice Extends fvm-solidity's CALL_ACTOR_BY_ID mock with a case for REWARD_ACTOR_ID.
/// @dev fvm-solidity's FVMCallActorById has no branch for the reward actor (f02) and is not
///      ours to modify -- these methods don't exist in builtin-actors yet (see
///      FVMRewardActor.sol) and will only ever be called by solstice's own contracts. Rather
///      than reimplement burn/power/datacap/miner handling here, this contract intercepts
///      only REWARD_ACTOR_ID and forwards everything else, unmodified, to a freshly deployed
///      FVMCallActorById via `delegatecall`. Using `delegatecall` (not `call`) is required: it
///      is what preserves `address(this)`/`msg.sender` as the original caller all the way
///      through to FVMCallActorById's `_handleBurn`, which debits `address(this).balance`
///      expecting that to be the real caller's balance, not this contract's.
/// @dev Etch this at CALL_ACTOR_BY_ID (replacing the vanilla FVMCallActorById) via
///      MockRewardTest, after MockFVMTest.setUp() has already run.
contract FVMCallActorByIdWithReward {
    address private immutable BASE;
    FVMRewardActor private immutable REWARD;

    constructor(Vm vm, FVMRewardActor reward) {
        BASE = address(new FVMCallActorById(vm));
        REWARD = reward;
    }

    fallback() external payable {
        // Real precompile requires delegatecall; call/staticcall returns CallForbidden → (0, empty).
        if (address(this) == CALL_ACTOR_BY_ID) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        (uint64 method, uint256 value, uint64 flags, uint64 codec, bytes memory params, uint64 actorId) =
            abi.decode(msg.data, (uint64, uint256, uint64, uint64, bytes, uint64));

        if (actorId == REWARD_ACTOR_ID) {
            require(flags == READONLY_FLAG || flags == NO_FLAGS, "FVMCallActorByIdWithReward: invalid flags");
            bytes memory response;
            if (value != 0) {
                // None of the reward actor's methods accept a value; reject rather than drop it.
                response = abi.encode(USR_ILLEGAL_ARGUMENT, uint64(0), bytes(""));
            } else {
                (uint32 exitCode, uint64 outCodec, bytes memory rewardRet) =
                    REWARD.handle_filecoin_method(method, codec, params);
                response = abi.encode(exitCode, outCodec, rewardRet);
            }
            assembly ("memory-safe") {
                return(add(response, 0x20), mload(response))
            }
        }

        (bool ok, bytes memory baseRet) = BASE.delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(baseRet, 0x20), mload(baseRet))
            }
        }
        assembly ("memory-safe") {
            return(add(baseRet, 0x20), mload(baseRet))
        }
    }
}
