// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {EMPTY_SET, FULL_SET, OwnerSet} from "../src/lib/OwnerSet.sol";

contract OwnerSetTest is Test {
    function test_emptySet_isZero() public pure {
        assertEq(OwnerSet.unwrap(EMPTY_SET), 0);
    }

    function test_fullSet_isMaxUint160() public pure {
        assertEq(OwnerSet.unwrap(FULL_SET), type(uint160).max);
    }

    function testFuzz_equals_reflexive(uint160 raw) public pure {
        OwnerSet set = OwnerSet.wrap(raw);
        assertTrue(set == set);
    }

    function testFuzz_notEquals_isNegationOfEquals(uint160 a, uint160 b) public pure {
        OwnerSet setA = OwnerSet.wrap(a);
        OwnerSet setB = OwnerSet.wrap(b);
        assertEq(setA == setB, !(setA != setB));
    }

    function testFuzz_notEquals_differingBits(uint160 a, uint160 b) public pure {
        vm.assume(a != b);
        assertTrue(OwnerSet.wrap(a) != OwnerSet.wrap(b));
    }

    function testFuzz_or_matchesRawBitwiseOr(uint160 a, uint160 b) public pure {
        OwnerSet result = OwnerSet.wrap(a) | OwnerSet.wrap(b);
        assertEq(OwnerSet.unwrap(result), a | b);
    }

    function testFuzz_xor_matchesRawBitwiseXor(uint160 a, uint160 b) public pure {
        OwnerSet result = OwnerSet.wrap(a) ^ OwnerSet.wrap(b);
        assertEq(OwnerSet.unwrap(result), a ^ b);
    }

    function testFuzz_and_matchesRawBitwiseAnd(uint160 a, uint160 b) public pure {
        OwnerSet result = OwnerSet.wrap(a) & OwnerSet.wrap(b);
        assertEq(OwnerSet.unwrap(result), a & b);
    }

    function testFuzz_or_emptySetIsIdentity(uint160 a) public pure {
        assertTrue((OwnerSet.wrap(a) | EMPTY_SET) == OwnerSet.wrap(a));
    }

    function testFuzz_and_fullSetIsIdentity(uint160 a) public pure {
        assertTrue((OwnerSet.wrap(a) & FULL_SET) == OwnerSet.wrap(a));
    }

    function testFuzz_and_emptySetIsAnnihilator(uint160 a) public pure {
        assertTrue((OwnerSet.wrap(a) & EMPTY_SET) == EMPTY_SET);
    }

    function testFuzz_xor_selfInverse(uint160 a) public pure {
        assertTrue((OwnerSet.wrap(a) ^ OwnerSet.wrap(a)) == EMPTY_SET);
    }

    function testFuzz_xor_isReversibleWithSameOperand(uint160 a, uint160 b) public pure {
        OwnerSet setA = OwnerSet.wrap(a);
        OwnerSet setB = OwnerSet.wrap(b);
        assertTrue((setA ^ setB) ^ setB == setA);
    }
}
