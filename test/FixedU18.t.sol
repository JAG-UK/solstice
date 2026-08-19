// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {FixedU18, ONE} from "../src/lib/FixedU18.sol";

contract FixedU18Test is Test {
    function test_exp_zeroExponent_isOne() public pure {
        assertTrue(FixedU18.wrap(2.7 ether).exp(0) == ONE);
        assertTrue(FixedU18.wrap(0.7 ether).exp(0) == ONE);
        assertTrue(FixedU18.wrap(0).exp(0) == ONE);
    }

    function test_exp_oneExponent_isBase() public pure {
        FixedU18 base;
        base = FixedU18.wrap(2.7 ether);
        assertTrue(base.exp(1) == base);
        base = FixedU18.wrap(0.7 ether);
        assertTrue(base.exp(1) == base);
        base = FixedU18.wrap(0.3 ether);
        assertTrue(base.exp(1) == base);
        base = FixedU18.wrap(3 ether);
        assertTrue(base.exp(1) == base);

        base = ONE;
        assertTrue(base.exp(0) == ONE);
        assertTrue(base.exp(54) == ONE);
        assertTrue(base.exp(55) == ONE);
    }

    function test_exp_gautlet() public pure {
        assertTrue(FixedU18.wrap(0.5 ether).exp(2) == FixedU18.wrap(0.25 ether));
        assertTrue(FixedU18.wrap(5 ether).exp(2) == FixedU18.wrap(25 ether));

        assertTrue(FixedU18.wrap(0.3 ether).exp(3) == FixedU18.wrap(0.027 ether));
        assertTrue(FixedU18.wrap(3 ether).exp(3) == FixedU18.wrap(27 ether));

        assertTrue(FixedU18.wrap(0.2 ether).exp(4) == FixedU18.wrap(0.0016 ether));
        assertTrue(FixedU18.wrap(2 ether).exp(4) == FixedU18.wrap(16 ether));

        assertTrue(FixedU18.wrap(2.7 ether).exp(5) == FixedU18.wrap(143.48907 ether));
        assertTrue(FixedU18.wrap(2.7 ether).exp(6) == FixedU18.wrap(387.420489 ether));
        assertTrue(FixedU18.wrap(2.7 ether).exp(7) == FixedU18.wrap(1046.0353203 ether));
        assertTrue(FixedU18.wrap(2.7 ether).exp(8) == FixedU18.wrap(2824.29536481 ether));
        assertTrue(FixedU18.wrap(2.7 ether).exp(9) == FixedU18.wrap(7625.597484987 ether));
    }
}
