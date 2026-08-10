// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {REWARD_ACTOR_ID} from "fvm-solidity/FVMActors.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {NO_FLAGS} from "fvm-solidity/FVMFlags.sol";
import {EXIT_SUCCESS} from "fvm-solidity/FVMErrors.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";

import {
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_WEIGHT_RECORDS,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    SET_SHARES,
    CLAIM
} from "./FVMRewardMethod.sol";
import {WeightRecord, DistributionKind, Share, PendingOp} from "./FVMRewardTypes.sol";

/// @notice Calls the f02 (Reward actor) methods specified by FIP-0118, for the Stream Weight
/// Actor (solstice#3) and Service Rewards Actor (solstice#4).
/// @dev The param encodings are unverified against f02's own serialization vectors
/// (builtin-actors `actors/reward/tests/types_test.rs`). Until they are checked against those,
/// agreement with the mock in this repo is not evidence of agreement with the chain.
/// @dev Every write params blob is a CBOR array of positional fields; addresses are encoded as
/// CBOR byte strings wrapping an f410 delegated address (0x04, 0x0a, 20 address bytes). No
/// abi.encode/abi.decode: params are hand-built in assembly and Filecoin BigInt returns are
/// parsed directly out of returndata. Call-envelope scratch memory is never returned to Solidity
/// and so is used past the free memory pointer without bumping it (dies with the call); only
/// claim's decoded `amounts` array is a real, pointer-bumped allocation.
library FVMRewards {
    error RegisterStreamFailed(int256 exitCode);
    error RemoveStreamFailed(int256 exitCode);
    error SetWeightRecordsFailed(int256 exitCode);
    error SetDistributionFailed(int256 exitCode);
    error CancelPendingFailed(int256 exitCode);
    error SetSharesFailed(int256 exitCode);
    error ClaimFailed(int256 exitCode);

    // -------------------------------------------------------------------------
    // RegisterStream -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Calls RegisterStream on f02 without reverting on actor error.
    /// @param id The new stream's id
    /// @param record The stream's initial weight schedule
    /// @param kind IMPLICIT (writer must be address(0)) or EXPLICIT (writer required)
    /// @param writer The stream's designated writer for EXPLICIT streams; address(0) for IMPLICIT
    /// @param activationEpoch The epoch the stream begins paying; must be >= now + SWA_TIMELOCK
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function tryRegisterStream(
        uint64 id,
        WeightRecord memory record,
        DistributionKind kind,
        address writer,
        uint64 activationEpoch
    ) internal returns (int256 exitCode) {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            function writeCborInt64(ptr, v) -> newPtr {
                let neg := slt(v, 0)
                let m := v
                if neg { m := not(v) }
                let base := 0
                if neg { base := 0x20 }
                if lt(m, 24) {
                    mstore8(ptr, or(base, m))
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(m, 0x100) {
                    mstore(ptr, shl(240, or(shl(8, or(base, 0x18)), m)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(m, 0x10000) {
                    mstore(ptr, shl(232, or(shl(16, or(base, 0x19)), m)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(m, 0x100000000) {
                    mstore(ptr, shl(216, or(shl(32, or(base, 0x1a)), m)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, or(base, 0x1b)), shl(184, m)))
                newPtr := add(ptr, 9)
            }

            let fmp := mload(0x40)
            mstore(fmp, REGISTER_STREAM)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0) // params offset
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [id, [vStart, slope, tStart, floor, cap], kind, writerOrNull, activationEpoch]
            let p := add(fmp, 0xe0)
            mstore8(p, 0x85) // 5-element array
            p := add(p, 1)
            p := writeCborUint64(p, id)

            mstore8(p, 0x85) // weight record: 5-element array
            p := add(p, 1)
            p := writeCborInt64(p, mload(record)) // vStart
            p := writeCborInt64(p, mload(add(record, 0x20))) // slope
            p := writeCborUint64(p, mload(add(record, 0x40))) // tStart
            p := writeCborInt64(p, mload(add(record, 0x60))) // floor
            p := writeCborInt64(p, mload(add(record, 0x80))) // cap

            mstore8(p, kind) // DistributionKind ordinal (0 or 1) fits inline CBOR uint
            p := add(p, 1)
            // Null iff writer is the zero address -- independent of `kind`, so a caller mistake
            // (e.g. IMPLICIT with a nonzero writer) reaches the actor honestly instead of being
            // silently corrected here.
            // case 0 on the raw value, not case 1 on a precomputed iszero(writer): one ISZERO
            // instead of two comparisons.
            switch writer
            case 0 {
                mstore8(p, 0xf6) // CBOR null
                p := add(p, 1)
            }
            default {
                // CBOR bytes(22): f410 delegated address [0x04, 0x0a, 20 address bytes]
                mstore(p, or(shl(232, 0x56040a), shl(72, writer)))
                p := add(p, 23)
            }
            p := writeCborUint64(p, activationEpoch)

            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0))) // params length

            exitCode := not(0) // sentinel: precompile failure
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls RegisterStream on f02, reverting on actor error.
    function registerStream(
        uint64 id,
        WeightRecord memory record,
        DistributionKind kind,
        address writer,
        uint64 activationEpoch
    ) internal {
        int256 exitCode = tryRegisterStream(id, record, kind, writer, activationEpoch);
        require(exitCode == EXIT_SUCCESS, RegisterStreamFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // RemoveStream -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Calls RemoveStream on f02 without reverting on actor error.
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function tryRemoveStream(uint64 id) internal returns (int256 exitCode) {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            let fmp := mload(0x40)
            mstore(fmp, REMOVE_STREAM)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: a bare uint64 (streamId), no array wrapper
            let p := writeCborUint64(add(fmp, 0xe0), id)
            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls RemoveStream on f02, reverting on actor error.
    function removeStream(uint64 id) internal {
        int256 exitCode = tryRemoveStream(id);
        require(exitCode == EXIT_SUCCESS, RemoveStreamFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords -- SWA only, batch
    // -------------------------------------------------------------------------

    /// @notice Calls SetWeightRecords on f02 without reverting on actor error.
    /// @param ids The streams to update; must be the same length as `records`
    /// @param records Each id's new weight schedule
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function trySetWeightRecords(uint64[] memory ids, WeightRecord[] memory records)
        internal
        returns (int256 exitCode)
    {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            function writeCborInt64(ptr, v) -> newPtr {
                let neg := slt(v, 0)
                let m := v
                if neg { m := not(v) }
                let base := 0
                if neg { base := 0x20 }
                if lt(m, 24) {
                    mstore8(ptr, or(base, m))
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(m, 0x100) {
                    mstore(ptr, shl(240, or(shl(8, or(base, 0x18)), m)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(m, 0x10000) {
                    mstore(ptr, shl(232, or(shl(16, or(base, 0x19)), m)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(m, 0x100000000) {
                    mstore(ptr, shl(216, or(shl(32, or(base, 0x1a)), m)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, or(base, 0x1b)), shl(184, m)))
                newPtr := add(ptr, 9)
            }

            function writeCborArrayHeader(ptr, count) -> newPtr {
                switch lt(count, 24)
                case 1 {
                    mstore8(ptr, or(0x80, count))
                    newPtr := add(ptr, 1)
                }
                default {
                    switch lt(count, 0x100)
                    case 1 {
                        mstore8(ptr, 0x98)
                        mstore8(add(ptr, 1), count)
                        newPtr := add(ptr, 2)
                    }
                    default {
                        mstore8(ptr, 0x99)
                        mstore(add(ptr, 1), shl(240, count))
                        newPtr := add(ptr, 3)
                    }
                }
            }

            let fmp := mload(0x40)
            mstore(fmp, SET_WEIGHT_RECORDS)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [[id...], [[vStart,slope,tStart,floor,cap]...]]. ids and records are
            // encoded with their own independent lengths -- a mismatch is left on the wire for
            // the actor to reject, not resolved (let alone silently truncated) here.
            let p := add(fmp, 0xe0)
            mstore8(p, 0x82)
            p := add(p, 1)

            let idsCount := mload(ids)
            p := writeCborArrayHeader(p, idsCount)
            let idsData := add(ids, 0x20)
            for { let i := 0 } lt(i, idsCount) { i := add(i, 1) } {
                p := writeCborUint64(p, mload(add(idsData, shl(5, i))))
            }

            let recCount := mload(records)
            p := writeCborArrayHeader(p, recCount)
            let recData := add(records, 0x20)
            for { let i := 0 } lt(i, recCount) { i := add(i, 1) } {
                let rec := mload(add(recData, shl(5, i)))
                mstore8(p, 0x85)
                p := add(p, 1)
                p := writeCborInt64(p, mload(rec))
                p := writeCborInt64(p, mload(add(rec, 0x20)))
                p := writeCborUint64(p, mload(add(rec, 0x40)))
                p := writeCborInt64(p, mload(add(rec, 0x60)))
                p := writeCborInt64(p, mload(add(rec, 0x80)))
            }

            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls SetWeightRecords on f02, reverting on actor error.
    function setWeightRecords(uint64[] memory ids, WeightRecord[] memory records) internal {
        int256 exitCode = trySetWeightRecords(ids, records);
        require(exitCode == EXIT_SUCCESS, SetWeightRecordsFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // SetDistribution -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Calls SetDistribution on f02 without reverting on actor error.
    /// @dev Converting a stream to IMPLICIT is not permitted by f02; kind must be EXPLICIT.
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function trySetDistribution(uint64 id, DistributionKind kind, address writer) internal returns (int256 exitCode) {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            let fmp := mload(0x40)
            mstore(fmp, SET_DISTRIBUTION)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [id, kind, writerOrNull]
            let p := add(fmp, 0xe0)
            mstore8(p, 0x83)
            p := add(p, 1)
            p := writeCborUint64(p, id)
            mstore8(p, kind)
            p := add(p, 1)
            // Null iff writer is the zero address -- independent of `kind` (see RegisterStream).
            switch writer
            case 0 {
                mstore8(p, 0xf6)
                p := add(p, 1)
            }
            default {
                mstore(p, or(shl(232, 0x56040a), shl(72, writer)))
                p := add(p, 23)
            }

            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls SetDistribution on f02, reverting on actor error.
    function setDistribution(uint64 id, DistributionKind kind, address writer) internal {
        int256 exitCode = trySetDistribution(id, kind, writer);
        require(exitCode == EXIT_SUCCESS, SetDistributionFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // CancelPending -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Calls CancelPending on f02 without reverting on actor error.
    /// @dev Cancelling an already-empty (id, op) slot is a benign no-op success, not an error.
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function tryCancelPending(uint64 id, PendingOp op) internal returns (int256 exitCode) {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            let fmp := mload(0x40)
            mstore(fmp, CANCEL_PENDING)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [id, op]
            let p := add(fmp, 0xe0)
            mstore8(p, 0x82)
            p := add(p, 1)
            p := writeCborUint64(p, id)
            mstore8(p, op)
            p := add(p, 1)

            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls CancelPending on f02, reverting on actor error.
    function cancelPending(uint64 id, PendingOp op) internal {
        int256 exitCode = tryCancelPending(id, op);
        require(exitCode == EXIT_SUCCESS, CancelPendingFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // SetShares -- callable only by a stream's designated writer
    // -------------------------------------------------------------------------

    /// @notice Calls SetShares on f02 without reverting on actor error.
    /// @dev shares[].share values must sum to exactly SHARE_TOTAL (1e18, WAD); f02 rejects otherwise.
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    function trySetShares(uint64 id, Share[] memory shares) internal returns (int256 exitCode) {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            function writeCborArrayHeader(ptr, count) -> newPtr {
                switch lt(count, 24)
                case 1 {
                    mstore8(ptr, or(0x80, count))
                    newPtr := add(ptr, 1)
                }
                default {
                    switch lt(count, 0x100)
                    case 1 {
                        mstore8(ptr, 0x98)
                        mstore8(add(ptr, 1), count)
                        newPtr := add(ptr, 2)
                    }
                    default {
                        mstore8(ptr, 0x99)
                        mstore(add(ptr, 1), shl(240, count))
                        newPtr := add(ptr, 3)
                    }
                }
            }

            let n := mload(shares)
            let fmp := mload(0x40)
            mstore(fmp, SET_SHARES)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [id, [[walletBytes, share]...]]
            let p := add(fmp, 0xe0)
            mstore8(p, 0x82)
            p := add(p, 1)
            p := writeCborUint64(p, id)

            p := writeCborArrayHeader(p, n)
            let data := add(shares, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let s := mload(add(data, shl(5, i))) // pointer to Share struct
                let wallet := mload(s)
                let share := mload(add(s, 0x20))
                mstore8(p, 0x82)
                p := add(p, 1)
                mstore(p, or(shl(232, 0x56040a), shl(72, wallet)))
                p := add(p, 23)
                p := writeCborUint64(p, share)
            }

            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            if and(gt(returndatasize(), 0x1f), delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)) {
                exitCode := mload(0)
            }
        }
    }

    /// @notice Calls SetShares on f02, reverting on actor error.
    function setShares(uint64 id, Share[] memory shares) internal {
        int256 exitCode = trySetShares(id, shares);
        require(exitCode == EXIT_SUCCESS, SetSharesFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // Claim -- permissionless
    // -------------------------------------------------------------------------

    /// @notice Calls Claim on f02 without reverting on actor error.
    /// @param id The stream (or drained-but-still-owing tombstone) to claim from
    /// @param wallets The wallets to pay out; a wallet with nothing owed pays zero, not an error
    /// @return exitCode 0 on success; a nonzero actor exit code (or the -1 precompile-failure
    /// sentinel) otherwise
    /// @return amounts Each wallet's paid entitlement (attoFIL), same order as `wallets`; empty
    /// unless exitCode is 0
    /// @dev Builds params in fmp scratch (dead after the call), then -- only on success -- copies
    /// the CBOR return payload into that same dead scratch and decodes `amounts` right after it,
    /// so the two never overlap; only `amounts` itself is a real, pointer-bumped allocation.
    function tryClaim(uint64 id, address[] memory wallets)
        internal
        returns (int256 exitCode, uint256[] memory amounts)
    {
        assembly ("memory-safe") {
            function writeCborUint64(ptr, v) -> newPtr {
                if lt(v, 24) {
                    mstore8(ptr, v)
                    newPtr := add(ptr, 1)
                    leave
                }
                if lt(v, 0x100) {
                    mstore(ptr, shl(240, or(0x1800, v)))
                    newPtr := add(ptr, 2)
                    leave
                }
                if lt(v, 0x10000) {
                    mstore(ptr, shl(232, or(0x190000, v)))
                    newPtr := add(ptr, 3)
                    leave
                }
                if lt(v, 0x100000000) {
                    mstore(ptr, shl(216, or(0x1a00000000, v)))
                    newPtr := add(ptr, 5)
                    leave
                }
                mstore(ptr, or(shl(248, 0x1b), shl(184, v)))
                newPtr := add(ptr, 9)
            }

            function writeCborArrayHeader(ptr, count) -> newPtr {
                switch lt(count, 24)
                case 1 {
                    mstore8(ptr, or(0x80, count))
                    newPtr := add(ptr, 1)
                }
                default {
                    switch lt(count, 0x100)
                    case 1 {
                        mstore8(ptr, 0x98)
                        mstore8(add(ptr, 1), count)
                        newPtr := add(ptr, 2)
                    }
                    default {
                        mstore8(ptr, 0x99)
                        mstore(add(ptr, 1), shl(240, count))
                        newPtr := add(ptr, 3)
                    }
                }
            }

            // Reads one CBOR head (major type + info-derived count/length), 1-, 2-, or 3-byte form.
            // Major type is never consumed by either caller below (this codebase's own encoder
            // only ever produces the shapes they expect), so it's not computed or returned.
            function readCborHead(ptr) -> value, newPtr {
                let info := and(byte(0, mload(ptr)), 0x1f)
                switch lt(info, 24)
                case 1 {
                    value := info
                    newPtr := add(ptr, 1)
                }
                default {
                    switch info
                    case 24 {
                        value := byte(0, mload(add(ptr, 1)))
                        newPtr := add(ptr, 2)
                    }
                    default {
                        value := shr(240, mload(add(ptr, 1)))
                        newPtr := add(ptr, 3)
                    }
                }
            }

            let n := mload(wallets)
            let fmp := mload(0x40)
            mstore(fmp, CLAIM)
            mstore(add(fmp, 0x20), 0)
            mstore(add(fmp, 0x40), NO_FLAGS)
            mstore(add(fmp, 0x60), CBOR_CODEC)
            mstore(add(fmp, 0x80), 0xc0)
            mstore(add(fmp, 0xa0), REWARD_ACTOR_ID)

            // Params CBOR: [id, [walletBytes...]]
            let p := add(fmp, 0xe0)
            mstore8(p, 0x82)
            p := add(p, 1)
            p := writeCborUint64(p, id)
            p := writeCborArrayHeader(p, n)
            let wdata := add(wallets, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let wallet := mload(add(wdata, shl(5, i)))
                mstore(p, or(shl(232, 0x56040a), shl(72, wallet)))
                p := add(p, 23)
            }
            mstore(add(fmp, 0xc0), sub(p, add(fmp, 0xe0)))

            exitCode := not(0)
            let callOk := delegatecall(gas(), CALL_ACTOR_BY_ID, fmp, sub(p, fmp), 0, 0x20)

            amounts := mload(0x40) // empty by default; only reassigned below on a decoded success
            mstore(amounts, 0)

            if and(callOk, gt(returndatasize(), 0x1f)) {
                exitCode := mload(0)
                // returndata layout: 0x00 exitCode, 0x20 codec, 0x40 bytes offset, 0x60 bytes
                // length, 0x80+ the CBOR payload itself (a CBOR array of BigInt byte strings).
                if and(iszero(exitCode), gt(returndatasize(), 0x80)) {
                    let cborLen := sub(returndatasize(), 0x80)
                    let cborPtr := fmp // call input is dead; reuse it as scratch for the raw copy
                    returndatacopy(cborPtr, 0x80, cborLen)

                    let count, cur
                    count, cur := readCborHead(cborPtr)

                    // Place the real, pointer-bumped array right after the raw scratch copy so
                    // the two never overlap.
                    amounts := add(cborPtr, cborLen)
                    mstore(amounts, count)
                    let out := add(amounts, 0x20)

                    for { let i := 0 } lt(i, count) { i := add(i, 1) } {
                        let blen
                        blen, cur := readCborHead(cur)
                        let value := 0
                        if blen {
                            let signByte := byte(0, mload(cur))
                            let magLen := sub(blen, 1)
                            if or(signByte, gt(magLen, 32)) { revert(0, 0) }
                            if magLen { value := shr(shl(3, sub(32, magLen)), mload(add(cur, 1))) }
                        }
                        mstore(add(out, shl(5, i)), value)
                        cur := add(cur, blen)
                    }

                    mstore(0x40, add(out, shl(5, count)))
                }
            }
        }
    }

    /// @notice Calls Claim on f02, reverting on actor error.
    function claim(uint64 id, address[] memory wallets) internal returns (uint256[] memory amounts) {
        int256 exitCode;
        (exitCode, amounts) = tryClaim(id, wallets);
        require(exitCode == EXIT_SUCCESS, ClaimFailed(exitCode));
    }
}
