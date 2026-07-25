// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {AddressXorSet, AddressXorSetLibrary, EMPTY_SET} from "../src/lib/AddressXorSet.sol";

contract AddressXorSetTest is Test {
    using AddressXorSetLibrary for AddressXorSet;

    function test_emptySet_isEmpty() public pure {
        assertTrue(EMPTY_SET.isEmpty());
    }

    function testFuzz_add_makesNonEmpty(address item) public pure {
        vm.assume(item != address(0));
        AddressXorSet set = EMPTY_SET.add(item);
        assertFalse(set.isEmpty());
    }

    function testFuzz_add_remove(address a, address b) public pure {
        assertTrue(EMPTY_SET.add(a).remove(a) == EMPTY_SET);
        assertTrue(EMPTY_SET.add(b).remove(b) == EMPTY_SET);

        assertTrue(EMPTY_SET.add(a).add(b).remove(a).remove(b) == EMPTY_SET);
        assertTrue(EMPTY_SET.add(b).add(a).remove(a).remove(b) == EMPTY_SET);
        assertTrue(EMPTY_SET.add(a).add(b).remove(b).remove(a) == EMPTY_SET);
        assertTrue(EMPTY_SET.add(b).add(a).remove(b).remove(a) == EMPTY_SET);
    }

    function testFuzz_commutative_add(address a, address b) public pure {
        assertTrue(EMPTY_SET.add(a).add(b) == EMPTY_SET.add(b).add(a));
        assertTrue(EMPTY_SET.add(b).add(a) == EMPTY_SET.add(a).add(b));
    }

    function testFuzz_not_equals(address a, address b) public pure {
        vm.assume(a != b);
        assertFalse(EMPTY_SET.add(a) == EMPTY_SET.add(b));
    }

    function testFuzz_negatesSubset_emptyBasis_onlyMatchesZeroAddress(address item) public pure {
        address[] memory basis = new address[](0);
        assertEq(AddressXorSetLibrary.negatesSubset(item, basis), item == address(0));
    }

    function testFuzz_negatesSubset_singleItem_matchesItself(address item) public pure {
        vm.assume(item != address(0));
        address[] memory basis = new address[](1);
        basis[0] = item;
        assertTrue(AddressXorSetLibrary.negatesSubset(item, basis));
    }

    function testFuzz_negatesSubset_singleItem_doesNotMatchOther(address item, address other) public pure {
        vm.assume(item != other && item != address(0) && other != address(0));
        address[] memory basis = new address[](1);
        basis[0] = item;
        assertFalse(AddressXorSetLibrary.negatesSubset(other, basis));
    }

    function testFuzz_negatesSubset_pairXor_matchesCombination(address a, address b) public pure {
        vm.assume(a != b && a != address(0) && b != address(0));
        address combo = address(uint160(a) ^ uint160(b));
        vm.assume(combo != address(0));
        address[] memory basis = new address[](2);
        basis[0] = a;
        basis[1] = b;
        assertTrue(AddressXorSetLibrary.negatesSubset(combo, basis));
    }

    function test_negatesSubset_exhaustive_fourItemUniverse() public pure {
        address[] memory universe = new address[](4);
        universe[0] = address(0x1111111111111111111111111111111111111a);
        universe[1] = address(0x2222222222222222222222222222222222222b);
        universe[2] = address(0x3333333333333333333333333333333333333c);
        universe[3] = address(0x4444444444444444444444444444444444444d);

        uint256 len = universe.length;
        for (uint256 bitmap = 0; bitmap < (1 << len); bitmap++) {
            AddressXorSet set = EMPTY_SET;
            for (uint256 i = 0; i < len; i++) {
                if ((bitmap >> i) & 1 == 1) {
                    set = set.add(universe[i]);
                }
            }
            assertTrue(AddressXorSetLibrary.negatesSubset(AddressXorSet.unwrap(set), universe));
        }
    }
}
