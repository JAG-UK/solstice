// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {AddressXorSet, AddressXorSetLibrary, EMPTY_SET} from "../src/lib/AddressXorSet.sol";

// wraps the internal library so vm.expectRevert has a real call frame to target
contract AddressXorSetHarness {
    using AddressXorSetLibrary for AddressXorSet;

    function contains(AddressXorSet set, address item, address[] memory possibleItems) external pure returns (bool) {
        return set.contains(item, possibleItems);
    }
}

contract AddressXorSetTest is Test {
    using AddressXorSetLibrary for AddressXorSet;

    AddressXorSetHarness harness;

    function setUp() public {
        harness = new AddressXorSetHarness();
    }

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

    function testFuzz_contains_singleItem_present(address item) public pure {
        vm.assume(item != address(0));
        address[] memory universe = new address[](1);
        universe[0] = item;

        assertFalse(EMPTY_SET.contains(item, universe));
        assertTrue(EMPTY_SET.add(item).contains(item, universe));
    }

    function testFuzz_contains_twoItems(address a, address b) public pure {
        vm.assume(a != b && a != address(0) && b != address(0));
        address[] memory universe = new address[](2);
        universe[0] = a;
        universe[1] = b;

        assertFalse(EMPTY_SET.contains(a, universe));
        assertFalse(EMPTY_SET.contains(b, universe));

        AddressXorSet setA = EMPTY_SET.add(a);
        assertTrue(setA.contains(a, universe));
        assertFalse(setA.contains(b, universe));

        AddressXorSet setB = EMPTY_SET.add(b);
        assertFalse(setB.contains(a, universe));
        assertTrue(setB.contains(b, universe));

        AddressXorSet setAb = EMPTY_SET.add(a).add(b);
        assertTrue(setAb.contains(a, universe));
        assertTrue(setAb.contains(b, universe));
    }

    function testFuzz_contains_threeItems(address a, address b, address c) public pure {
        vm.assume(a != b && a != c && b != c && a != address(0) && b != address(0) && c != address(0));
        vm.assume(uint160(a) ^ uint160(b) != uint160(c));
        address[] memory universe = new address[](3);
        universe[0] = a;
        universe[1] = b;
        universe[2] = c;

        AddressXorSet set = EMPTY_SET.add(a).add(b);
        assertTrue(set.contains(a, universe));
        assertTrue(set.contains(b, universe));
        assertFalse(set.contains(c, universe));
    }

    function testFuzz_contains_revertsImpossibleAddress_whenItemNotInUniverse(address a, address b, address other)
        public
    {
        vm.assume(a != b && a != other && b != other);
        address[] memory universe = new address[](2);
        universe[0] = a;
        universe[1] = b;

        AddressXorSet set = EMPTY_SET.add(a);
        vm.expectRevert(abi.encodeWithSelector(AddressXorSetLibrary.ImpossibleAddress.selector, other));
        harness.contains(set, other, universe);
    }

    function testFuzz_contains_revertsImpossibleAddressSet_whenSetNotReconstructable(address a, address b, address c)
        public
    {
        vm.assume(a != b && a != c && b != c);
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        address[] memory universe = new address[](2);
        universe[0] = a;
        universe[1] = b;

        // A set containing `c`, which is outside the {a, b} universe, cannot
        // be reconstructed from any combination of {a, b}.
        AddressXorSet set = EMPTY_SET.add(c);
        vm.expectRevert(abi.encodeWithSelector(AddressXorSetLibrary.ImpossibleAddressSet.selector, set));
        harness.contains(set, a, universe);
    }

    function test_contains_exhaustive_fourItemUniverse() public pure {
        address[] memory universe = new address[](4);
        universe[0] = address(0x1111111111111111111111111111111111111a);
        universe[1] = address(0x2222222222222222222222222222222222222b);
        universe[2] = address(0x3333333333333333333333333333333333333c);
        universe[3] = address(0x4444444444444444444444444444444444444d);

        uint256 len = universe.length;
        for (uint256 bitmap = 1; bitmap < (1 << len); bitmap++) {
            AddressXorSet set = EMPTY_SET;
            for (uint256 i = 0; i < len; i++) {
                if ((bitmap >> i) & 1 == 1) {
                    set = set.add(universe[i]);
                }
            }
            for (uint256 i = 0; i < len; i++) {
                bool expected = (bitmap >> i) & 1 == 1;
                assertEq(set.contains(universe[i], universe), expected);
            }
        }
    }
}
