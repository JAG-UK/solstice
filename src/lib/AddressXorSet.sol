// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// XOR sets are storage-efficient, and appropriate for small sets of large random items, such as owner addresses

// TODO compare gas to bloom set

type AddressXorSet is address;

using {equals as ==} for AddressXorSet global;
using AddressXorSetLibrary for AddressXorSet global;

// @param a The first set
// @param b The second set
// @return Whether the two sets have identical underlying bitmaps
function equals(AddressXorSet a, AddressXorSet b) pure returns (bool) {
    return AddressXorSet.unwrap(a) == AddressXorSet.unwrap(b);
}

AddressXorSet constant EMPTY_SET = AddressXorSet.wrap(address(0));

library AddressXorSetLibrary {
    // @param set The set to check
    // @return Whether the set has no items
    function isEmpty(AddressXorSet set) internal pure returns (bool) {
        return set == EMPTY_SET;
    }

    // @dev If the item is actually already in the set, this removes it
    // @param setWithoutItem The set that does not yet contain the item
    // @param itemNotInSet The address to add to the set
    // @return setWithItem The resulting set with the item added
    function add(AddressXorSet setWithoutItem, address itemNotInSet)
        internal
        pure
        returns (AddressXorSet setWithItem)
    {
        assembly ("memory-safe") {
            setWithItem := xor(setWithoutItem, itemNotInSet)
        }
    }

    // @dev If the item is actually not in the set, this adds it
    // @param setWithItem The set that contains the item
    // @param itemInSet The address to remove from the set
    // @return setWithoutItem The resulting set with the item removed
    function remove(AddressXorSet setWithItem, address itemInSet)
        internal
        pure
        returns (AddressXorSet setWithoutItem)
    {
        assembly ("memory-safe") {
            setWithoutItem := xor(setWithItem, itemInSet)
        }
    }

    // The address is not in the possibleItems
    error ImpossibleAddress(address item);
    // The set cannot be created from the possibleItems
    error ImpossibleAddressSet(AddressXorSet set);

    // @dev The execution cost is exponential in the number of possible items.
    // @param set The set to check
    // @param item The address to check for membership; must be present in possibleItems
    // @param possibleItems The full universe of addresses that may have been combined into the set
    // @return Whether the set contains the item
    function contains(AddressXorSet set, address item, address[] memory possibleItems) internal pure returns (bool) {
        unchecked {
            uint256 len = possibleItems.length;
            uint256 index = len;
            for (uint256 i = 0; i < len; i++) {
                if (possibleItems[i] == item) {
                    index = i;
                    break;
                }
            }
            require(index < len, ImpossibleAddress(item));

            // find the underlying bitmap by reconstructing the set from its possible items
            uint256 exp = 1 << len;
            for (uint256 bitmap = 0; bitmap < exp; bitmap++) {
                AddressXorSet calculated = EMPTY_SET;
                for (uint256 i = 0; i < len; i++) {
                    if ((bitmap >> i) & 1 == 1) {
                        calculated = add(calculated, possibleItems[i]);
                    }
                }
                if (calculated == set) {
                    // found the underlying bitmap for the set

                    // does that bitmap contain the item?
                    return (bitmap >> index) & 1 == 1;
                }
            }
            // did not find the underlying bitmap for the set
            revert ImpossibleAddressSet(set);
        }
    }
}
