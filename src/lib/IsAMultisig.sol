// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

/// @notice The only thing we require of a multisig: it can list its signers.
/// @dev Safe{Wallet} and the other common multisig implementations all expose this.
interface IMultisig {
    function getOwners() external view returns (address[] memory);
}

library IsAMultisig {
    error NotAMultisig(address account);
    error TooFewSigners(address account, uint256 signers);

    /// @notice Requires that `account` is a contract behaving like a multisig with >1 signer.
    /// @dev FIP-0118 mandates no specific multisig implementation, so this deliberately checks
    /// behaviour, not identity: any contract answering `getOwners()` with two or more signers
    /// qualifies, and EOAs (no code, so no return data) do not.
    function requireMultisig(address account) internal view {
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeCall(IMultisig.getOwners, ()));
        // 64 bytes is the shortest well-formed `address[]` encoding: head offset + length
        require(ok && ret.length >= 64, NotAMultisig(account));
        address[] memory signers = abi.decode(ret, (address[]));
        require(signers.length > 1, TooFewSigners(account, signers.length));
    }
}
