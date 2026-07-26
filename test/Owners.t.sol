// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {EMPTY_SET, FULL_SET, OwnerSet} from "../src/lib/OwnerSet.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";

// wraps the internal library so vm.expectRevert has a real call frame to target
contract OwnersHarness {
    function isOwner(address someone) external view returns (bool) {
        return OwnersLibrary.isOwner(someone);
    }

    function getAllOwners() external view returns (OwnerSet) {
        return OwnersLibrary.getAllOwners();
    }

    function asOwnerSet(address owner) external view returns (OwnerSet) {
        return OwnersLibrary.asOwnerSet(owner);
    }

    function addOwner(address owner) external {
        OwnersLibrary.addOwner(owner);
    }

    function removeOwner(address owner) external {
        OwnersLibrary.removeOwner(owner);
    }

    // test-only bootstrap: jumps the bit-scan cursor and bitmap directly, so tests can exercise
    // addOwner's wraparound without registering ~160 real owners first
    function seedBitState(uint8 latestOwnerBit, OwnerSet allOwners) external {
        OwnersLibrary.Owners storage owners = OwnersLibrary.getOwnersSlot();
        owners.latestOwnerBit = latestOwnerBit;
        owners.allOwners = allOwners;
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

    function testFuzz_addOwner(address owner) public {
        vm.assume(owner != address(0));
        harness.addOwner(owner);
        assertTrue(harness.isOwner(owner));

        assertTrue(harness.getAllOwners() == harness.asOwnerSet(owner));

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, owner));
        harness.addOwner(owner);
    }

    function testFuzz_addOwner_multipleOwners(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        harness.addOwner(a);
        harness.addOwner(b);

        assertTrue(harness.isOwner(a));
        assertTrue(harness.isOwner(b));

        // distinct owners get distinct bits
        assertTrue(harness.asOwnerSet(a) != harness.asOwnerSet(b));
        assertTrue(harness.getAllOwners() == (harness.asOwnerSet(a) | harness.asOwnerSet(b)));

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, a));
        harness.addOwner(a);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.AlreadyOwner.selector, b));
        harness.addOwner(b);
    }

    function testFuzz_removeOwner(address owner) public {
        vm.assume(owner != address(0));
        harness.addOwner(owner);
        harness.removeOwner(owner);
        assertFalse(harness.isOwner(owner));
        assertTrue(harness.getAllOwners() == EMPTY_SET);
    }

    function testFuzz_removeOwner_leavesOtherOwnersIntact(address a, address b, address c) public {
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        vm.assume(a != b && a != c && b != c);

        harness.addOwner(a);
        harness.addOwner(b);
        harness.addOwner(c);

        OwnerSet bMask = harness.asOwnerSet(b);
        harness.removeOwner(b);

        assertFalse(harness.isOwner(b));
        assertTrue(harness.isOwner(a));
        assertTrue(harness.isOwner(c));
        assertTrue(harness.getAllOwners() & bMask == EMPTY_SET);
        assertTrue(harness.getAllOwners() == (harness.asOwnerSet(a) | harness.asOwnerSet(c)));
    }

    function testFuzz_removeOwner_revertsForNonOwner(address a) public {
        vm.assume(a != address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, a));
        harness.removeOwner(a);
    }

    function testFuzz_removeOwner_revertsAfterAlreadyRemoved(address a) public {
        vm.assume(a != address(0));
        harness.addOwner(a);
        harness.removeOwner(a);

        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, a));
        harness.removeOwner(a);
    }

    function testFuzz_addOwner_afterRemove_canReAdd(address owner) public {
        vm.assume(owner != address(0));

        harness.addOwner(owner);
        harness.removeOwner(owner);
        harness.addOwner(owner);

        assertTrue(harness.isOwner(owner));
    }

    function test_addOwner_revertsWhenFull() public {
        harness.seedBitState(0, FULL_SET);
        address owner = makeAddr("overflowOwner");

        vm.expectRevert(OwnersLibrary.MaximumOwnersReached.selector);
        harness.addOwner(owner);
    }

    // loop-around coverage:
    // addOwner scans forward from `latestOwnerBit` for a free bit, wrapping the
    // scan back to bit 0 (via `ownerBit %= 160`) once it runs past bit 159, the
    // top of the uint160 bitmap. These tests seed that boundary condition
    // directly instead of registering ~160 real owners to reach it.

    function test_addOwner_cursorAtTopBit_resetsCursorToZeroAfterClaimingIt() public {
        // the top bit (159) is free: addOwner claims it directly, no scanning needed,
        // but the stored cursor must still wrap to 0 (160 % 160 == 0) for next time
        harness.seedBitState(159, EMPTY_SET);

        address owner = makeAddr("topBitOwner");
        harness.addOwner(owner);
        assertTrue(harness.asOwnerSet(owner) == OwnerSet.wrap(uint160(1) << 159));

        address nextOwner = makeAddr("afterTopBitOwner");
        harness.addOwner(nextOwner);
        assertTrue(harness.asOwnerSet(nextOwner) == OwnerSet.wrap(1));
    }

    function test_addOwner_wrapsPastTopBitToFindFreeLowBit() public {
        // bits 155-159 are occupied; cursor starts at the top (159), so the very
        // first candidate collides and the scan must wrap around to bit 0
        OwnerSet occupiedTop = OwnerSet.wrap(uint160(0x1F) << 155);
        harness.seedBitState(159, occupiedTop);

        address owner = makeAddr("wraparoundOwner");
        harness.addOwner(owner);

        assertTrue(harness.asOwnerSet(owner) == OwnerSet.wrap(1));
        assertTrue(harness.getAllOwners() == (occupiedTop | OwnerSet.wrap(1)));
    }

    function test_addOwner_wrapsAndSkipsOccupiedLowBitsBeforeFindingFree() public {
        // bit 159 (top) and bits 0,1,2 are occupied; bit 3 is the first free slot
        // once the scan wraps around and walks past the occupied low bits
        OwnerSet occupied = OwnerSet.wrap((uint160(1) << 159) | uint160(0x7));
        harness.seedBitState(159, occupied);

        address owner = makeAddr("wraparoundOwner2");
        harness.addOwner(owner);

        assertTrue(harness.asOwnerSet(owner) == OwnerSet.wrap(uint160(1) << 3));
        assertTrue(harness.getAllOwners() == (occupied | OwnerSet.wrap(uint160(1) << 3)));
    }

    function test_addOwner_wrapsAllTheWayAroundToFindOnlyFreeBit() public {
        // every bit is occupied except bit 5; the cursor starts at the very top
        // (159), which is itself occupied, so the scan must wrap from 159 back to
        // 0 and then walk up through the occupied low bits before landing on 5
        OwnerSet almostFull = FULL_SET ^ OwnerSet.wrap(uint160(1) << 5);
        harness.seedBitState(159, almostFull);

        address owner = makeAddr("lastFreeBitOwner");
        harness.addOwner(owner);

        assertTrue(harness.asOwnerSet(owner) == OwnerSet.wrap(uint160(1) << 5));
        assertTrue(harness.getAllOwners() == FULL_SET);
    }
}
