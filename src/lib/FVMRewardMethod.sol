// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// FRC-0042 method numbers for the f02 (Reward actor) stream-splitting methods proposed by
// FIP-1270 (https://github.com/filecoin-project/FIPs/pull/1270) and tracked upstream at
// filecoin-project/builtin-actors#1764. The actor does not exist yet; these numbers are the
// FRC-0042 hash of each method name, defined here so FVMRewards and its mock agree on them.
uint64 constant REGISTER_STREAM = 386660827;
uint64 constant REMOVE_STREAM = 1623858416;
uint64 constant SET_WEIGHT_RECORDS = 3362570548;
uint64 constant STEP_WEIGHT_RECORDS = 3951753085;
uint64 constant SET_DISTRIBUTION = 3872725033;
uint64 constant CANCEL_PENDING = 187585191;
uint64 constant SET_SHARES = 2414422607;
uint64 constant CLAIM = 4045527845;
uint64 constant GET_STATE = 1397113977;

/// @dev The activation timelock SWA writes to f02 are queued under: the mainnet default,
/// 7 days in epochs (30s/epoch); migration-set per network, so the real actor also exposes it
/// as mutable state rather than a hardcoded constant.
uint64 constant SWA_TIMELOCK = 20160;
