// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

/// @notice Minimal stand-in for any multisig: it just lists its signers.
contract MockMultisig {
    address[] internal signers;

    constructor(uint256 count) {
        for (uint256 i = 0; i < count; i++) {
            signers.push(address(uint160(i + 1)));
        }
    }

    function getOwners() external view returns (address[] memory) {
        return signers;
    }
}
