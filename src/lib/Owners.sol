// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {AddressXorSet, AddressXorSetLibrary} from "./AddressXorSet.sol";

library OwnersLibrary {
    using AddressXorSetLibrary for AddressXorSet;

    uint256 private constant IS_OWNER_MASK = 1;

    struct OwnerInfo {
        uint256 flags;
    }

    /// @custom:storage-location erc7201:Solstice.Owners
    struct Owners {
        mapping(address => OwnerInfo) ownerInfo;
        AddressXorSet allOwners;
        address[] ownersRoster;
    }

    // keccak256(abi.encode(uint256(keccak256("Solstice.Owners")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant OWNERS_SLOT = 0x7d2e7f914625694dd929b468ac404d7943373f4d24421c78ac93b57cc8efb500;

    function getOwnersSlot() internal pure returns (Owners storage owners) {
        assembly ("memory-safe") {
            owners.slot := OWNERS_SLOT
        }
    }

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);

    function isOwner(address someone) internal view returns (bool) {
        return getOwnersSlot().ownerInfo[someone].flags & IS_OWNER_MASK != 0;
    }

    function getAllOwners() internal view returns (AddressXorSet) {
        return getOwnersSlot().allOwners;
    }

    function loadOwnerRoster() internal view returns (address[] memory ownersRoster) {
        Owners storage owners = getOwnersSlot();
        unchecked {
            uint256 len = owners.ownersRoster.length;
            ownersRoster = new address[](owners.ownersRoster.length);
            for (uint256 i = 0; i < len; i++) {
                ownersRoster[i] = owners.ownersRoster[i];
            }
        }
    }

    // Proposed owner is already an owner
    error AlreadyOwner(address owner);
    // Proposed owner is a combination of existing owners
    error InvalidOwner(address owner);

    function addOwner(address owner) internal {
        Owners storage owners = getOwnersSlot();
        AddressXorSet allOwners = owners.allOwners;

        require(!isOwner(owner), AlreadyOwner(owner));

        // also verify that no xor combination of existing owners is equal to this one
        require(!AddressXorSetLibrary.negatesSubset(owner, loadOwnerRoster()), InvalidOwner(owner));

        owners.ownersRoster.push(owner);
        owners.allOwners = allOwners.add(owner);
        owners.ownerInfo[owner].flags |= IS_OWNER_MASK;

        emit OwnerAdded(owner);
    }

    // Roster index does not match the supplied owner address
    error OwnerIndexMismatch(address actual);

    function removeOwner(address owner, uint256 ownersRosterIndex) internal {
        Owners storage owners = getOwnersSlot();

        require(
            owners.ownersRoster[ownersRosterIndex] == owner, OwnerIndexMismatch(owners.ownersRoster[ownersRosterIndex])
        );

        owners.allOwners = owners.allOwners.remove(owner);
        delete owners.ownerInfo[owner];

        // delete from roster
        uint256 lastRosterIndex = owners.ownersRoster.length - 1;
        if (ownersRosterIndex != lastRosterIndex) {
            owners.ownersRoster[ownersRosterIndex] = owners.ownersRoster[lastRosterIndex];
        }
        owners.ownersRoster.pop();

        emit OwnerRemoved(owner);
    }
}
