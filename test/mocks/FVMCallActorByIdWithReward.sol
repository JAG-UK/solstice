// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {REWARD_ACTOR_ID, REWARD_ACTOR_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {NO_FLAGS, READONLY_FLAG} from "fvm-solidity/FVMFlags.sol";
import {USR_ILLEGAL_ARGUMENT} from "fvm-solidity/FVMErrors.sol";
import {FVMCallActorById} from "fvm-solidity/mocks/FVMCallActorById.sol";

/// @notice Extends fvm-solidity's CALL_ACTOR_BY_ID mock with a branch for REWARD_ACTOR_ID (f02).
/// @dev Serves calls addressed to f02 by raw-selector routing to whichever mock is etched at
///      REWARD_ACTOR_ADDRESS, so callers can swap it without a typed dependency. Forwards every
///      other actor id, unmodified, to an FVMCallActorById deployed at construction.
/// @dev That forward is a `delegatecall` and must stay one. It preserves `address(this)` and
///      `msg.sender` as the original caller through to FVMCallActorById's `_handleBurn`, which
///      debits `address(this).balance`; under `call` the debit lands on this contract instead.
/// @dev Etch at CALL_ACTOR_BY_ID, replacing the vanilla FVMCallActorById, via MockRewardTest and
///      after MockFVMTest.setUp() has run.
contract FVMCallActorByIdWithReward {
    address private immutable BASE;

    constructor(Vm vm) {
        BASE = address(new FVMCallActorById(vm));
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
                (bool rewardOk, bytes memory rewardRet) = REWARD_ACTOR_ADDRESS.call(
                    abi.encodeWithSignature("handle_filecoin_method(uint64,uint64,bytes)", method, codec, params)
                );
                response = rewardOk ? rewardRet : abi.encode(USR_ILLEGAL_ARGUMENT, uint64(0), bytes(""));
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
