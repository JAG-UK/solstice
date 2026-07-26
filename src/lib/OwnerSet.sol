// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// OwnerSet is a space-efficient bitmask
// Each owner has a unique representative bit assigned during addOwner

type OwnerSet is uint160;

using {equals as ==, notEquals as !=, or as |, xor as ^, and as &} for OwnerSet global;

OwnerSet constant EMPTY_SET = OwnerSet.wrap(uint160(0));
OwnerSet constant FULL_SET = OwnerSet.wrap(type(uint160).max);

function equals(OwnerSet a, OwnerSet b) pure returns (bool) {
    return OwnerSet.unwrap(a) == OwnerSet.unwrap(b);
}

function notEquals(OwnerSet a, OwnerSet b) pure returns (bool) {
    return OwnerSet.unwrap(a) != OwnerSet.unwrap(b);
}

function or(OwnerSet a, OwnerSet b) pure returns (OwnerSet) {
    return OwnerSet.wrap(OwnerSet.unwrap(a) | OwnerSet.unwrap(b));
}

function xor(OwnerSet a, OwnerSet b) pure returns (OwnerSet) {
    return OwnerSet.wrap(OwnerSet.unwrap(a) ^ OwnerSet.unwrap(b));
}

function and(OwnerSet a, OwnerSet b) pure returns (OwnerSet) {
    return OwnerSet.wrap(OwnerSet.unwrap(a) & OwnerSet.unwrap(b));
}
