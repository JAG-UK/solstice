// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";

/// @notice Stand-in for f02 (Reward actor) that records the exact bytes it received instead of
///         acting on them. FVMRewardWireTest only checks the wire format FVMRewards sends against
///         f02's own vectors, so it has no need for FVMRewardActor's stateful business logic.
/// @dev Etch at REWARD_ACTOR_ADDRESS via MockRewardWireTest, which also re-etches CALL_ACTOR_BY_ID
///      to reach handle_filecoin_method below, exactly as MockRewardTest does for the full mock.
contract FVMRewardParamsRecorder {
    /// @notice The params of the most recently dispatched call, exactly as they arrived.
    bytes public mockLastParams;

    /// @notice Test helper: return this blob from Claim verbatim, so a test can pin the decode
    /// path against f02's own ClaimReturn vectors rather than against what this mock computes.
    bytes public mockClaimReturnData;
    bool public mockClaimReturnSet;

    function mockSetClaimReturn(bytes calldata data) external {
        mockClaimReturnData = data;
        mockClaimReturnSet = true;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function handle_filecoin_method(uint64, uint64, bytes calldata params)
        external
        returns (uint32, uint64, bytes memory)
    {
        mockLastParams = params;
        if (mockClaimReturnSet) return (0, CBOR_CODEC, mockClaimReturnData);
        return (0, 0, "");
    }
}
