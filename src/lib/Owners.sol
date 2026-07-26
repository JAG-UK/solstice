// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {EMPTY_SET, FULL_SET, OwnerSet} from "./OwnerSet.sol";

library OwnersLibrary {
    struct OwnerInfo {
        uint8 ownerBit; // [0, 160]
    }

    /// @custom:storage-location erc7201:Solstice.Owners
    struct Owners {
        mapping(address => OwnerInfo) ownerInfo;
        uint8 latestOwnerBit; // [0, 160)
        OwnerSet allOwners;
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
        return getOwnersSlot().ownerInfo[someone].ownerBit != 0;
    }

    function asOwnerSet(address owner) internal view returns (OwnerSet mask) {
        uint8 ownerBit = getOwnersSlot().ownerInfo[owner].ownerBit;
        assembly ("memory-safe") {
            mask := shl(sub(ownerBit, 1), 1)
        }
    }

    function asOwnerSet(uint8 ownerBit) internal pure returns (OwnerSet mask) {
        assembly ("memory-safe") {
            mask := shl(sub(ownerBit, 1), 1)
        }
    }

    function getAllOwners() internal view returns (OwnerSet) {
        return getOwnersSlot().allOwners;
    }

    // Proposed owner is already an owner
    error AlreadyOwner(address owner);
    // Unsupported ownership count (> 160)
    error MaximumOwnersReached();

    function addOwner(address owner) internal {
        require(!isOwner(owner), AlreadyOwner(owner));

        Owners storage owners = getOwnersSlot();
        uint8 ownerBit = owners.latestOwnerBit;
        OwnerSet allOwners = owners.allOwners;

        require(allOwners != FULL_SET, MaximumOwnersReached());

        OwnerSet ownerSet = EMPTY_SET;

        // assign next free bit
        while (true) {
            assembly ("memory-safe") {
                ownerSet := shl(ownerBit, 1)
                ownerBit := add(1, ownerBit)
            }
            if (ownerSet & allOwners == EMPTY_SET) {
                break;
            } else {
                ownerBit %= 160;
            }
        }

        owners.ownerInfo[owner].ownerBit = ownerBit;
        owners.allOwners = allOwners | ownerSet;
        owners.latestOwnerBit = ownerBit % 160;

        emit OwnerAdded(owner);
    }

    // Address to remove is not a current owner
    error NotOwner(address owner);

    function removeOwner(address owner) internal {
        require(isOwner(owner), NotOwner(owner));

        Owners storage owners = getOwnersSlot();
        OwnerSet mask = asOwnerSet(owner);
        owners.allOwners = owners.allOwners ^ mask;
        delete owners.ownerInfo[owner];

        emit OwnerRemoved(owner);
    }
}
