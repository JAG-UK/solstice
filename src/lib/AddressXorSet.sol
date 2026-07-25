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

    // @dev The execution cost is exponential in the number of basis items.
    // @param item The address to check
    // @param basis The addresses whose xor-combinations are checked against item
    // @return Whether some subset of basis xors to exactly item
    function negatesSubset(address item, address[] memory basis) internal pure returns (bool) {
        unchecked {
            uint256 len = basis.length;
            uint256 exp = 1 << len;
            for (uint256 bitmap = 0; bitmap < exp; bitmap++) {
                AddressXorSet calculated = EMPTY_SET;
                for (uint256 i = 0; i < len; i++) {
                    if ((bitmap >> i) & 1 == 1) {
                        calculated = add(calculated, basis[i]);
                    }
                }
                if (AddressXorSet.unwrap(calculated) == item) {
                    return true;
                }
            }
            return false;
        }
    }
}
