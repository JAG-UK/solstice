// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

type Epoch is uint96;

using {
    add as +,
    sub as -,
    equals as ==,
    greaterThan as >,
    lessThan as <,
    greaterThanOrEqualTo as >=,
    lessThanOrEqualTo as <=
} for Epoch global;

function currentEpoch() view returns (Epoch epoch) {
    assembly ("memory-safe") {
        epoch := number()
    }
}

function add(Epoch epoch, Epoch other) pure returns (Epoch sum) {
    assembly ("memory-safe") {
        sum := add(epoch, other)
    }
}

function sub(Epoch epoch, Epoch other) pure returns (Epoch difference) {
    assembly ("memory-safe") {
        difference := sub(epoch, other)
    }
}

function equals(Epoch epoch, Epoch other) pure returns (bool) {
    return Epoch.unwrap(epoch) == Epoch.unwrap(other);
}

function greaterThan(Epoch epoch, Epoch other) pure returns (bool) {
    return Epoch.unwrap(epoch) > Epoch.unwrap(other);
}

function lessThan(Epoch epoch, Epoch other) pure returns (bool) {
    return Epoch.unwrap(epoch) < Epoch.unwrap(other);
}

function greaterThanOrEqualTo(Epoch epoch, Epoch other) pure returns (bool) {
    return Epoch.unwrap(epoch) >= Epoch.unwrap(other);
}

function lessThanOrEqualTo(Epoch epoch, Epoch other) pure returns (bool) {
    return Epoch.unwrap(epoch) <= Epoch.unwrap(other);
}
