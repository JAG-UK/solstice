// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {AddressXorSet, EMPTY_SET} from "../src/lib/AddressXorSet.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";

// wraps the internal library so vm.expectRevert has a real call frame to target
contract OwnersHarness {
    function isOwner(address someone) external view returns (bool) {
        return OwnersLibrary.isOwner(someone);
    }

    function getAllOwners() external view returns (AddressXorSet) {
        return OwnersLibrary.getAllOwners();
    }

    function loadOwnerRoster() external view returns (address[] memory) {
        return OwnersLibrary.loadOwnerRoster();
    }

    function addOwner(address owner) external {
        OwnersLibrary.addOwner(owner);
    }

    function removeOwner(address owner, uint256 ownersRosterIndex) external {
        OwnersLibrary.removeOwner(owner, ownersRosterIndex);
    }
}

contract OwnersTest is Test {
    OwnersHarness harness;

    function setUp() public {
        harness = new OwnersHarness();
    }

    function test_isOwner_falseInitially(address someone) public view {
        assertFalse(harness.isOwner(someone));
    }

    function test_allOwners_emptyInitially() public view {
        assertTrue(harness.getAllOwners() == EMPTY_SET);
    }

    function test_loadOwnerRoster_emptyInitially() public view {
        assertEq(harness.loadOwnerRoster().length, 0);
    }

    function testFuzz_addOwner(address owner) public {
        vm.assume(owner != address(0));
        harness.addOwner(owner);
        assertTrue(harness.isOwner(owner));

        address[] memory roster = harness.loadOwnerRoster();
        assertEq(roster.length, 1);
        assertEq(roster[0], owner);

        assertTrue(harness.getAllOwners() == EMPTY_SET.add(owner));

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, owner));
        harness.addOwner(owner);
    }

    function testFuzz_addOwner_multipleOwners(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        harness.addOwner(a);
        harness.addOwner(b);

        assertTrue(harness.isOwner(a));
        assertTrue(harness.isOwner(b));

        address[] memory roster = harness.loadOwnerRoster();
        assertEq(roster.length, 2);
        assertEq(roster[0], a);
        assertEq(roster[1], b);

        assertTrue(harness.getAllOwners() == EMPTY_SET.add(a).add(b));

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, a));
        harness.addOwner(a);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, b));
        harness.addOwner(b);
    }

    function testFuzz_removeOwner(address owner) public {
        vm.assume(owner != address(0));
        harness.addOwner(owner);
        harness.removeOwner(owner, 0);
        assertFalse(harness.isOwner(owner));
        assertEq(harness.loadOwnerRoster().length, 0);
        assertTrue(harness.getAllOwners() == EMPTY_SET);
    }

    function testFuzz_removeOwner_swapsLastIntoRemovedSlot(address a, address b, address c) public {
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        vm.assume(a != b && a != c && b != c);

        harness.addOwner(a);
        harness.addOwner(b);
        harness.addOwner(c);

        // remove the middle element; the last element (c) should be swapped into its place
        harness.removeOwner(b, 1);

        address[] memory roster = harness.loadOwnerRoster();
        assertEq(roster.length, 2);
        assertEq(roster[0], a);
        assertEq(roster[1], c);

        assertFalse(harness.isOwner(b));
        assertTrue(harness.isOwner(a));
        assertTrue(harness.isOwner(c));
        assertTrue(harness.getAllOwners() == EMPTY_SET.add(a).add(c));
    }

    function testFuzz_removeOwner_lastIndex_noSwapNeeded(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);

        harness.addOwner(a);
        harness.addOwner(b);

        harness.removeOwner(b, 1);

        address[] memory roster = harness.loadOwnerRoster();
        assertEq(roster.length, 1);
        assertEq(roster[0], a);
        assertTrue(harness.getAllOwners() == EMPTY_SET.add(a));
    }

    function testFuzz_removeOwner_revertsOnIndexMismatch(address a, uint256 badIndex) public {
        vm.assume(a != address(0));
        badIndex = bound(badIndex, 1, 10);

        harness.addOwner(a);

        vm.expectRevert(stdError.indexOOBError);
        harness.removeOwner(a, badIndex);
    }

    function testFuzz_removeOwner_revertsWhenAddressAtIndexDiffers(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);

        harness.addOwner(a);
        harness.addOwner(b);

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.OwnerIndexMismatch.selector, a));
        harness.removeOwner(b, 0);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.OwnerIndexMismatch.selector, b));
        harness.removeOwner(a, 1);
    }

    function testFuzz_addOwner_afterRemove_canReAdd(address owner) public {
        vm.assume(owner != address(0));

        harness.addOwner(owner);
        harness.removeOwner(owner, 0);
        harness.addOwner(owner);

        assertTrue(harness.isOwner(owner));
        address[] memory roster = harness.loadOwnerRoster();
        assertEq(roster.length, 1);
        assertEq(roster[0], owner);
    }

    function test_addOwner_revertsInvalidOwner_zeroAddress() public {
        // the empty subset of any basis xors to the zero address, so it is
        // always rejected as trivially "spanned" by the existing owners
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.InvalidOwner.selector, address(0)));
        harness.addOwner(address(0));
    }

    function testFuzz_addOwner_revertsInvalidOwner_xorCombinationOfExistingOwners(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        address collider = address(uint160(a) ^ uint160(b));

        harness.addOwner(a);
        harness.addOwner(b);

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.InvalidOwner.selector, collider));
        harness.addOwner(collider);

        assertFalse(harness.isOwner(collider));
    }

    function testFuzz_addOwner_revertsInvalidOwner_xorCombinationOfThreeExistingOwners(address a, address b, address c)
        public
    {
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        vm.assume(a != b && a != c && b != c);
        address collider = address(uint160(a) ^ uint160(b) ^ uint160(c));
        vm.assume(collider != address(0) && collider != a && collider != b && collider != c);

        harness.addOwner(a);
        harness.addOwner(b);
        harness.addOwner(c);

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.InvalidOwner.selector, collider));
        harness.addOwner(collider);
    }
}
