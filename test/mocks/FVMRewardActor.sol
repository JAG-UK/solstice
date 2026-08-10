// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {FVMPay} from "fvm-solidity/FVMPay.sol";

import {
    SET_WEIGHT_RECORDS,
    STEP_WEIGHT_RECORDS,
    SET_SHARES,
    GET_STATE,
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    CLAIM,
    SWA_TIMELOCK
} from "../../src/lib/FVMRewardMethod.sol";
import {WeightRecord, DistributionKind, Share, PendingOp} from "../../src/lib/FVMRewardTypes.sol";

/// @dev Weights, and per-orchestrator shares, are WAD-scaled: 1e18 == 1.0 == 100%.
int256 constant WAD = 1e18;

/// @dev Mock-only caps; f02 requires these limits to exist but never fixes their values.
uint64 constant MAX_STREAMS = 8;
uint256 constant MAX_RECIPIENTS = 64;

/// @dev Same value as WAD, typed uint256, so summing shares needs no signed-to-unsigned cast.
uint256 constant SHARE_TOTAL = 1e18;

struct LedgerRow {
    address wallet;
    uint256 amount;
}

/// @dev Enumerable, prunable address->uint256 balance -- plain mappings-plus-array, not the
/// builtin-actor's CBOR-behind-a-CID shape (fine: nothing implements that wire format yet).
struct Ledger {
    mapping(address => uint256) amount;
    mapping(address => uint256) indexPlusOne; // 0 == not tracked
    address[] wallets;
}

/// @notice A registered stream (`id` is the mapping key) plus its per-stream ledgers;
/// `shares`/`writer`/`accrued`/the ledgers are unused for IMPLICIT streams.
struct Stream {
    bool exists;
    WeightRecord weightRecord;
    DistributionKind kind;
    address writer;
    Share[] shares;
    uint256 accrued;
    Ledger payableLedger;
    Ledger claimedPeriod;
}

/// @notice A removed stream's outstanding liabilities; a drained tombstone deletes itself.
struct Tombstone {
    bool exists;
    Ledger payableLedger;
}

/// @dev A queued SWA write. Keyed by (streamId, op); an occupied slot rejects, so revising a
/// pending write means cancel + requeue.
struct Pending {
    uint64 effectiveEpoch;
    WeightRecord weightRecord; // SET_WEIGHT / STEP_WEIGHT / REGISTER payload
    DistributionKind distributionKind; // REGISTER / SET_DISTRIBUTION payload
    address writer; // REGISTER / SET_DISTRIBUTION payload
}

struct PendingKey {
    uint64 id;
    PendingOp op;
}

struct StreamView {
    uint64 id;
    WeightRecord weightRecord;
    int256 weight; // clamped weight at the current epoch
    DistributionKind kind;
    address writer;
    uint256 accrued;
    Share[] shares;
    LedgerRow[] payableRows;
    LedgerRow[] claimedPeriodRows;
}

struct TombstoneView {
    uint64 id;
    LedgerRow[] payableRows;
}

struct PendingView {
    uint64 id;
    PendingOp op;
    uint64 effectiveEpoch;
    WeightRecord weightRecord;
    DistributionKind distributionKind;
    address writer;
}

/// @notice Mock for the Filecoin Reward actor (f02), covering its stream-splitting methods.
/// @dev Etch at REWARD_ACTOR_ADDRESS via MockRewardTest, which also re-etches CALL_ACTOR_BY_ID
///      to reach handle_filecoin_method below.
/// @dev GetState persists due writes rather than only projecting them; behaviorally identical
///      once `effectiveEpoch` has passed.
contract FVMRewardActor {
    /// @dev Survives vm.etch: immutables are baked into runtime bytecode at deploy time.
    Vm private immutable VM;

    constructor(Vm vm_) {
        VM = vm_;
    }

    /// @notice Address authorized to call the SWA-only methods.
    address public swa;

    /// @notice Per-network SWA write hold, in epochs; mutable via mockSwaTimelockEpochs.
    /// @dev Left uninitialized inline (vm.etch copies bytecode, not storage -- an inline
    /// initializer would never apply); mockInit() sets it after etching.
    uint64 public swaTimelockEpochs;

    /// @notice Cumulative FIL minted through f02, all streams (T = position 9 / FilMined).
    uint256 public totalMintedReward;
    /// @notice Cumulative burn: w0 residual plus period-fold rounding dust (B).
    uint256 public totalBurnMinted;
    /// @notice Cumulative gross accrual to EXPLICIT streams (S); miner's share T-B-S is derived, never stored.
    uint256 public totalServiceMinted;

    /// @notice Minimum effectiveEpoch over pending writes; type(uint64).max sentinel when empty.
    uint64 public nextTransitionEpoch;

    mapping(uint64 streamId => Stream) internal _streams;
    uint64[] internal _streamIds;

    mapping(uint64 streamId => Tombstone) internal _tombstones;
    uint64[] internal _tombstoneIds;

    mapping(uint64 streamId => mapping(PendingOp => Pending)) internal _pending;
    mapping(uint64 streamId => mapping(PendingOp => bool)) internal _pendingExists;
    PendingKey[] internal _pendingKeys;

    event Claimed(uint64 indexed streamId, address indexed wallet, uint256 amount);
    /// @dev Fires only when an occupied slot is actually removed; cancelling an empty slot is a no-op.
    event PendingCancelled(uint64 indexed streamId, PendingOp op);
    event BlockRewardAwarded(uint256 br, uint256 minerPortion, uint256 servicePortion, uint256 burnAmount);

    /// @notice Test helper: sets the defaults an inline initializer would give this contract; call once, right after etching.
    function mockInit() external {
        swaTimelockEpochs = SWA_TIMELOCK;
        nextTransitionEpoch = type(uint64).max;
    }

    /// @notice Test helper: set the address authorized to call SWA-only methods.
    function mockSwa(address swa_) external {
        swa = swa_;
    }

    function mockSwaTimelockEpochs(uint64 epochs) external {
        swaTimelockEpochs = epochs;
    }

    /// @notice Test helper: simulates AwardBlockReward, splitting `br` by clamped weight into a
    /// miner portion (IMPLICIT; the actual payout is the unmocked ApplyRewards path), a service
    /// portion (EXPLICIT, accrues for Claim/SetShares), and a burn residual.
    /// @dev Mints `br` into this contract's own balance via vm.deal -- a block reward is newly
    /// issued, not moved from an existing balance, so callers don't pre-fund it themselves.
    function mockAwardBlockReward(uint256 br)
        external
        returns (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount)
    {
        VM.deal(address(this), address(this).balance + br);
        _settle();
        uint64 nowEpoch = uint64(block.number);
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            Stream storage s = _streams[id];
            int256 w = _clampWeight(s.weightRecord, nowEpoch);
            uint256 amount = (uint256(w) * br) / uint256(WAD);
            if (s.kind == DistributionKind.IMPLICIT) {
                minerPortion += amount;
            } else {
                servicePortion += amount;
                s.accrued += amount;
            }
        }
        burnAmount = br - minerPortion - servicePortion;

        totalMintedReward += br;
        totalBurnMinted += burnAmount;
        totalServiceMinted += servicePortion;

        if (burnAmount > 0) FVMPay.burn(burnAmount);
        emit BlockRewardAwarded(br, minerPortion, servicePortion, burnAmount);
    }

    /// @notice Test helper: an EXPLICIT stream's wallet-to-share map, without the GetState round trip.
    function getShares(uint64 streamId) external view returns (Share[] memory) {
        return _streams[streamId].shares;
    }

    /// @notice Test helper: read back a live stream's payable ledger directly.
    function getPayable(uint64 streamId) external view returns (LedgerRow[] memory) {
        return _ledgerView(_streams[streamId].payableLedger);
    }

    /// @notice Test helper: read back a tombstone's payable ledger directly.
    function getTombstonePayable(uint64 streamId) external view returns (LedgerRow[] memory) {
        return _ledgerView(_tombstones[streamId].payableLedger);
    }

    /// @notice Test helper: the clamp(v_start + slope*(e-t_start), floor, cap) math, exposed
    /// directly since it isn't a dispatched method (GetState already projects each weight).
    function clampWeight(WeightRecord memory record, uint64 epoch) external pure returns (int256) {
        return _clampWeight(record, epoch);
    }

    /// @notice A native actor: direct EVM CALL returns USR_UNHANDLED_MESSAGE rather than reverting.
    fallback() external {
        bytes memory response = abi.encode(uint32(USR_UNHANDLED_MESSAGE), uint64(0), bytes(""));
        assembly ("memory-safe") {
            return(add(response, 0x20), mload(response))
        }
    }

    /// @dev Routed here from FVMCallActorByIdWithReward's REWARD_ACTOR_ID branch. Never reverts
    /// for actor-level errors -- returns a non-zero exit code instead, per CALL_ACTOR_BY_ID.
    // forge-lint: disable-next-line(mixed-case-function)
    function handle_filecoin_method(uint64 method, uint64, bytes calldata params)
        external
        returns (uint32, uint64, bytes memory)
    {
        _settle();
        if (method == SET_WEIGHT_RECORDS) return _queueWeightWrite(PendingOp.SET_WEIGHT, params);
        if (method == STEP_WEIGHT_RECORDS) return _queueWeightWrite(PendingOp.STEP_WEIGHT, params);
        if (method == SET_SHARES) return _setShares(params);
        if (method == GET_STATE) return _getState();
        if (method == REGISTER_STREAM) return _registerStream(params);
        if (method == REMOVE_STREAM) return _removeStream(params);
        if (method == SET_DISTRIBUTION) return _setDistribution(params);
        if (method == CANCEL_PENDING) return _cancelPending(params);
        if (method == CLAIM) return _claim(params);
        return (USR_UNHANDLED_MESSAGE, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords / StepWeightRecords -- SWA only, queued under separate ops.
    // -------------------------------------------------------------------------

    function _queueWeightWrite(PendingOp op, bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [[id...], [[vStart,slope,tStart,floor,cap]...]]
        (uint64[] memory ids, WeightRecord[] memory records) = _decodeSetWeightRecordsParams(params);
        if (ids.length != records.length) return (USR_ILLEGAL_ARGUMENT, 0, "");

        uint64 effectiveEpoch = uint64(block.number) + swaTimelockEpochs;
        for (uint256 i = 0; i < ids.length; i++) {
            if (!_streams[ids[i]].exists) return (USR_NOT_FOUND, 0, "");
            if (!_sane(records[i])) return (USR_ILLEGAL_ARGUMENT, 0, "");
            if (_pendingExists[ids[i]][op]) return (USR_ILLEGAL_ARGUMENT, 0, "");
            // Reject repeats: they'd queue two PendingKeys for one (id, op) slot.
            for (uint256 j = 0; j < i; j++) {
                if (ids[j] == ids[i]) return (USR_ILLEGAL_ARGUMENT, 0, "");
            }
        }
        // Guardrail: sum of every stream's weight, including the proposed ones, must not exceed 1.
        int256 sum = _sumWeightsExcluding(ids, effectiveEpoch);
        for (uint256 i = 0; i < records.length; i++) {
            sum += _clampWeight(records[i], effectiveEpoch);
        }
        if (sum > WAD) return (USR_ILLEGAL_ARGUMENT, 0, "");

        for (uint256 i = 0; i < ids.length; i++) {
            _queueWrite(
                ids[i],
                op,
                Pending({
                    effectiveEpoch: effectiveEpoch,
                    weightRecord: records[i],
                    distributionKind: DistributionKind.IMPLICIT,
                    writer: address(0)
                })
            );
        }
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetShares -- designated writer only, applied immediately; folds the closing period into
    // `payable` under the OLD map before installing the new one.
    // -------------------------------------------------------------------------

    function _setShares(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        // Params CBOR: [id, [[walletBytes, share]...]]
        (uint64 id, Share[] memory newShares) = _decodeSetSharesParams(params);
        Stream storage s = _streams[id];
        if (!s.exists) return (USR_NOT_FOUND, 0, "");
        if (s.kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (msg.sender != s.writer) return (USR_FORBIDDEN, 0, "");
        if (newShares.length > MAX_RECIPIENTS) return (USR_ILLEGAL_ARGUMENT, 0, "");

        uint256 total;
        for (uint256 i = 0; i < newShares.length; i++) {
            total += newShares[i].share;
        }
        if (total != SHARE_TOTAL) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _foldAndBurnResidue(s);

        delete s.shares;
        for (uint256 i = 0; i < newShares.length; i++) {
            s.shares.push(newShares[i]);
        }
        return (0, 0, "");
    }

    function _getState() internal view returns (uint32, uint64, bytes memory) {
        uint64 nowEpoch = uint64(block.number);

        StreamView[] memory streams = new StreamView[](_streamIds.length);
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            Stream storage s = _streams[id];
            streams[i] = StreamView({
                id: id,
                weightRecord: s.weightRecord,
                weight: _clampWeight(s.weightRecord, nowEpoch),
                kind: s.kind,
                writer: s.writer,
                accrued: s.accrued,
                shares: s.shares,
                payableRows: _ledgerView(s.payableLedger),
                claimedPeriodRows: _ledgerView(s.claimedPeriod)
            });
        }

        TombstoneView[] memory tombstones = new TombstoneView[](_tombstoneIds.length);
        for (uint256 i = 0; i < _tombstoneIds.length; i++) {
            uint64 id = _tombstoneIds[i];
            tombstones[i] = TombstoneView({id: id, payableRows: _ledgerView(_tombstones[id].payableLedger)});
        }

        PendingView[] memory pendingWrites = new PendingView[](_pendingKeys.length);
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            PendingKey memory k = _pendingKeys[i];
            Pending storage p = _pending[k.id][k.op];
            pendingWrites[i] = PendingView({
                id: k.id,
                op: k.op,
                effectiveEpoch: p.effectiveEpoch,
                weightRecord: p.weightRecord,
                distributionKind: p.distributionKind,
                writer: p.writer
            });
        }

        return (
            0,
            0,
            abi.encode(
                totalMintedReward,
                totalBurnMinted,
                totalServiceMinted,
                nextTransitionEpoch,
                swaTimelockEpochs,
                streams,
                tombstones,
                pendingWrites
            )
        );
    }

    function _registerStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [id, [vStart,slope,tStart,floor,cap], kind, writerOrNull, activationEpoch]
        (uint64 id, WeightRecord memory record, DistributionKind kind, address writer, uint64 activationEpoch) =
            _decodeRegisterStreamParams(params);

        // Rejects any id collision it can see: a live stream, an undrained tombstone, or an
        // already-queued registration. Reuse after a tombstone fully drains is SWA discipline.
        if (_streams[id].exists || _tombstones[id].exists || _pendingExists[id][PendingOp.REGISTER]) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        // Count queued registrations too, or a burst of calls could blow past the cap.
        if (_streamIds.length + _pendingRegistrationCount() >= MAX_STREAMS) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (!_sane(record)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // IMPLICIT is consensus-only and carries no writer; EXPLICIT always needs one.
        if (kind == DistributionKind.IMPLICIT ? writer != address(0) : writer == address(0)) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (activationEpoch < uint64(block.number) + swaTimelockEpochs) return (USR_ILLEGAL_ARGUMENT, 0, "");

        int256 sum = _sumWeightsExcluding(new uint64[](0), activationEpoch) + _clampWeight(record, activationEpoch);
        if (sum > WAD) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queueWrite(
            id,
            PendingOp.REGISTER,
            Pending({effectiveEpoch: activationEpoch, weightRecord: record, distributionKind: kind, writer: writer})
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // RemoveStream -- SWA only, queued; applying it folds the period then tombstones the rest.
    // -------------------------------------------------------------------------

    function _removeStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: a bare uint64 (streamId), no array wrapper
        uint64 id = _decodeBareUint64(params);
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");
        if (_pendingExists[id][PendingOp.REMOVE]) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queueWrite(
            id,
            PendingOp.REMOVE,
            Pending({
                effectiveEpoch: uint64(block.number) + swaTimelockEpochs,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: 0, floor: 0, cap: 0}),
                distributionKind: DistributionKind.IMPLICIT,
                writer: address(0)
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetDistribution -- SWA only, queued; changes only the writer, folding the period first.
    // -------------------------------------------------------------------------

    function _setDistribution(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [id, kind, writerOrNull]
        (uint64 id, DistributionKind kind, address writer) = _decodeSetDistributionParams(params);
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");
        // Converting a stream to IMPLICIT is not permitted (IMPLICIT is consensus-only).
        if (kind == DistributionKind.IMPLICIT || writer == address(0)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (_pendingExists[id][PendingOp.SET_DISTRIBUTION]) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queueWrite(
            id,
            PendingOp.SET_DISTRIBUTION,
            Pending({
                effectiveEpoch: uint64(block.number) + swaTimelockEpochs,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: 0, floor: 0, cap: 0}),
                distributionKind: kind,
                writer: writer
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // CancelPending -- SWA only; cancelling an empty slot is a benign no-op.
    // -------------------------------------------------------------------------

    function _cancelPending(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [id, op]
        (uint64 id, PendingOp op) = _decodeCancelPendingParams(params);
        if (_pendingExists[id][op]) {
            delete _pending[id][op];
            _pendingExists[id][op] = false;
            _removePendingKey(id, op);
            _recomputeNextTransition();
            emit PendingCancelled(id, op);
        }
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // Claim -- permissionless, batched; zero-entitlement entries pay nothing, no revert.
    // -------------------------------------------------------------------------

    function _claim(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        // Params CBOR: [id, [walletBytes...]]
        (uint64 id, address[] memory wallets) = _decodeClaimParams(params);

        bool tombstoned = _tombstones[id].exists;
        Stream storage s = _streams[id];
        if (!tombstoned) {
            if (!s.exists) return (USR_NOT_FOUND, 0, "");
            if (s.kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        }

        uint256[] memory amounts = new uint256[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            uint256 entitlement;
            if (tombstoned) {
                entitlement = _tombstones[id].payableLedger.amount[wallet];
                if (entitlement == 0) continue;
                _ledgerRemove(_tombstones[id].payableLedger, wallet);
                if (_tombstones[id].payableLedger.wallets.length == 0) {
                    _tombstones[id].exists = false;
                    _removeTombstoneId(id);
                }
            } else {
                uint256 share = _shareOf(s, wallet);
                uint256 claimed = s.claimedPeriod.amount[wallet];
                uint256 grossLive = (share * s.accrued) / SHARE_TOTAL;
                uint256 live = grossLive > claimed ? grossLive - claimed : 0;
                uint256 payableAmount = s.payableLedger.amount[wallet];
                entitlement = live + payableAmount;
                if (entitlement == 0) continue;
                if (live > 0) _ledgerIncrement(s.claimedPeriod, wallet, live);
                if (payableAmount > 0) _ledgerRemove(s.payableLedger, wallet);
            }
            FVMPay.pay(wallet, entitlement); // method 0/SEND; cannot fail here
            emit Claimed(id, wallet, entitlement);
            amounts[i] = entitlement;
        }
        // Return CBOR: an array of Filecoin BigInt-encoded entitlements, one per wallet.
        return (0, CBOR_CODEC, _encodeCborBigIntArray(amounts));
    }

    // -------------------------------------------------------------------------
    // CBOR params/return encoding -- f02's real wire format; not gas-optimized, since only
    // FVMRewards (src/lib/FVMRewards.sol) and this mock need to agree on it.
    // -------------------------------------------------------------------------

    // Every decode helper below takes/returns an absolute calldata byte position (not an offset
    // into `params`), read via `calldataload` -- one word load per field, no `bytes calldata`
    // indexing or intermediate slicing.

    function _decodeSetWeightRecordsParams(bytes calldata params)
        private
        pure
        returns (uint64[] memory ids, WeightRecord[] memory records)
    {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 2-element array header
        uint256 idsCount;
        (idsCount, pos) = _decodeCborArrayHeader(pos);
        ids = new uint64[](idsCount);
        for (uint256 i = 0; i < idsCount; i++) {
            (ids[i], pos) = _decodeCborUint64(pos);
        }

        uint256 recCount;
        (recCount, pos) = _decodeCborArrayHeader(pos);
        records = new WeightRecord[](recCount);
        for (uint256 i = 0; i < recCount; i++) {
            pos += 1; // skip the per-record 5-element array header
            (records[i], pos) = _decodeWeightRecord(pos);
        }
    }

    function _decodeSetSharesParams(bytes calldata params) private pure returns (uint64 id, Share[] memory newShares) {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 2-element array header
        (id, pos) = _decodeCborUint64(pos);
        uint256 count;
        (count, pos) = _decodeCborArrayHeader(pos);
        newShares = new Share[](count);
        for (uint256 i = 0; i < count; i++) {
            pos += 1; // skip the per-entry 2-element array header
            address wallet;
            (wallet, pos) = _decodeAddressOrNull(pos);
            uint64 share;
            (share, pos) = _decodeCborUint64(pos);
            newShares[i] = Share({wallet: wallet, share: share});
        }
    }

    function _decodeRegisterStreamParams(bytes calldata params)
        private
        pure
        returns (uint64 id, WeightRecord memory record, DistributionKind kind, address writer, uint64 activationEpoch)
    {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 5-element array header
        (id, pos) = _decodeCborUint64(pos);
        pos += 1; // skip the weight-record 5-element array header
        (record, pos) = _decodeWeightRecord(pos);
        uint64 kindOrdinal;
        (kindOrdinal, pos) = _decodeCborUint64(pos);
        kind = DistributionKind(kindOrdinal);
        (writer, pos) = _decodeAddressOrNull(pos);
        (activationEpoch, pos) = _decodeCborUint64(pos);
    }

    function _decodeSetDistributionParams(bytes calldata params)
        private
        pure
        returns (uint64 id, DistributionKind kind, address writer)
    {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 3-element array header
        (id, pos) = _decodeCborUint64(pos);
        uint64 kindOrdinal;
        (kindOrdinal, pos) = _decodeCborUint64(pos);
        kind = DistributionKind(kindOrdinal);
        (writer, pos) = _decodeAddressOrNull(pos);
    }

    function _decodeCancelPendingParams(bytes calldata params) private pure returns (uint64 id, PendingOp op) {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 2-element array header
        (id, pos) = _decodeCborUint64(pos);
        uint64 opOrdinal;
        (opOrdinal, pos) = _decodeCborUint64(pos);
        op = PendingOp(opOrdinal);
    }

    function _decodeClaimParams(bytes calldata params) private pure returns (uint64 id, address[] memory wallets) {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 2-element array header
        (id, pos) = _decodeCborUint64(pos);
        uint256 count;
        (count, pos) = _decodeCborArrayHeader(pos);
        wallets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            (wallets[i], pos) = _decodeAddressOrNull(pos);
        }
    }

    /// @dev Bare CBOR uint64 (no array wrapper), e.g. RemoveStream's single streamId param.
    function _decodeBareUint64(bytes calldata params) private pure returns (uint64 v) {
        (v,) = _decodeCborUint64(_calldataPos(params));
    }

    function _decodeWeightRecord(uint256 pos) private pure returns (WeightRecord memory record, uint256 newPos) {
        int256 vStart;
        int256 slope;
        uint64 tStart;
        int256 floor;
        int256 cap;
        (vStart, pos) = _decodeCborInt64(pos);
        (slope, pos) = _decodeCborInt64(pos);
        (tStart, pos) = _decodeCborUint64(pos);
        (floor, pos) = _decodeCborInt64(pos);
        (cap, pos) = _decodeCborInt64(pos);
        record = WeightRecord({vStart: vStart, slope: slope, tStart: tStart, floor: floor, cap: cap});
        newPos = pos;
    }

    /// @dev The absolute calldata byte position of a calldata bytes value's content.
    function _calldataPos(bytes calldata data) private pure returns (uint256 pos) {
        assembly ("memory-safe") {
            pos := data.offset
        }
    }

    /// @dev Decodes a CBOR unsigned integer (major type 0) at absolute calldata position `pos`;
    /// also reused for array-length header counts (major type 4), since both encode their value
    /// the same way in the low 5 info bits. One `calldataload`, then shifts extract the width
    /// the info byte calls for -- no per-byte reads.
    function _decodeCborUint64(uint256 pos) private pure returns (uint64 v, uint256 newPos) {
        assembly ("memory-safe") {
            let w := calldataload(pos)
            let info := and(byte(0, w), 0x1f)
            let data := shl(8, w) // drop the header byte; field bytes now sit at the MSB end
            switch lt(info, 24)
            case 1 {
                v := info
                newPos := add(pos, 1)
            }
            default {
                switch info
                case 24 {
                    v := shr(248, data)
                    newPos := add(pos, 2)
                }
                case 25 {
                    v := shr(240, data)
                    newPos := add(pos, 3)
                }
                case 26 {
                    v := shr(224, data)
                    newPos := add(pos, 5)
                }
                default {
                    // info == 27
                    v := shr(192, data)
                    newPos := add(pos, 9)
                }
            }
        }
    }

    function _decodeCborArrayHeader(uint256 pos) private pure returns (uint256 count, uint256 newPos) {
        (uint64 c, uint256 np) = _decodeCborUint64(pos);
        return (c, np);
    }

    /// @dev Decodes a CBOR signed integer (major type 0 or 1) at absolute calldata position
    /// `pos`; the value fits int256 regardless of major type, since a CBOR-major-1 int64's
    /// magnitude is itself at most a uint64.
    function _decodeCborInt64(uint256 pos) private pure returns (int256 v, uint256 newPos) {
        uint256 major;
        assembly ("memory-safe") {
            major := shr(5, byte(0, calldataload(pos)))
        }
        uint64 magnitude;
        (magnitude, newPos) = _decodeCborUint64(pos);
        v = major == 0 ? int256(uint256(magnitude)) : -1 - int256(uint256(magnitude));
    }

    /// @dev Decodes an f410 delegated address wrapped in a CBOR byte string (0x04, 0x0a, 20
    /// bytes) at absolute calldata position `pos`, or CBOR null (address(0)) for an IMPLICIT
    /// stream's absent writer. The address bytes are big-endian, so one `calldataload` shifted
    /// into place reads all 20 at once.
    function _decodeAddressOrNull(uint256 pos) private pure returns (address addr, uint256 newPos) {
        assembly ("memory-safe") {
            let b := byte(0, calldataload(pos))
            switch b
            case 0xf6 {
                addr := 0
                newPos := add(pos, 1)
            }
            default {
                let len := and(b, 0x1f) // 22 for f410; length is always inline
                // header byte + [0x04, 0x0a] prefix (3 bytes), then 20 big-endian address bytes
                addr := shr(96, calldataload(add(pos, 3)))
                newPos := add(pos, add(1, len))
            }
        }
    }

    /// @dev Writes a CBOR array(count) header at absolute memory position `pos`; returns the new
    /// position. `pos` is a raw pointer (like a calldata `.offset`), not an index into a `bytes
    /// memory` -- callers compute it once from their buffer instead of passing the buffer itself,
    /// so every write is a direct `mstore8` rather than a bounds-checked `bytes memory` index.
    function _writeCborArrayHeader(uint256 pos, uint256 count) private pure returns (uint256 newPos) {
        assembly ("memory-safe") {
            switch lt(count, 24)
            case 1 {
                mstore8(pos, or(0x80, count))
                newPos := add(pos, 1)
            }
            default {
                switch lt(count, 0x100)
                case 1 {
                    mstore8(pos, 0x98)
                    mstore8(add(pos, 1), count)
                    newPos := add(pos, 2)
                }
                default {
                    mstore8(pos, 0x99)
                    mstore8(add(pos, 1), shr(8, count))
                    mstore8(add(pos, 2), count)
                    newPos := add(pos, 3)
                }
            }
        }
    }

    /// @dev The minimal big-endian encoding length of `value` (no leading zero byte); `value` is nonzero.
    function _bigEndianLen(uint256 value) private pure returns (uint256 len) {
        len = 32;
        bytes32 full = bytes32(value);
        while (full[32 - len] == 0) {
            len--;
        }
    }

    /// @dev Writes `value`'s Filecoin BigInt CBOR encoding (a CBOR byte string containing a sign
    /// byte -- 0x00, since entitlements are never negative -- followed by the minimal big-endian
    /// magnitude; zero is the empty byte string, matching go-state-types' big.Int
    /// (de)serialization) at absolute memory position `pos`; returns the new position.
    function _writeCborBigInt(uint256 pos, uint256 value) private pure returns (uint256 newPos) {
        if (value == 0) {
            assembly ("memory-safe") {
                mstore8(pos, 0x40)
                newPos := add(pos, 1)
            }
            return newPos;
        }
        uint256 magLen = _bigEndianLen(value);
        uint256 contentLen = magLen + 1;
        assembly ("memory-safe") {
            let p := pos
            switch lt(contentLen, 24)
            case 1 {
                mstore8(p, or(0x40, contentLen))
                p := add(p, 1)
            }
            default {
                mstore8(p, 0x58)
                mstore8(add(p, 1), contentLen)
                p := add(p, 2)
            }
            mstore8(p, 0) // sign byte: positive
            p := add(p, 1)
            // Magnitude, big-endian, right-aligned in `value`; the mstore's trailing bytes past
            // magLen spill into the buffer's over-allocated slack (see below) and are harmless.
            mstore(p, shl(shl(3, sub(32, magLen)), value))
            newPos := add(p, magLen)
        }
    }

    /// @dev Claims the free memory pointer directly rather than `new bytes(...)`, since the exact
    /// length isn't known until after writing: `new bytes(worstCase)` would permanently bump the
    /// free pointer past memory this array never ends up using (memory is never freed), forcing
    /// every later allocation in the call to sit -- and pay expansion gas -- past that unused
    /// stretch regardless. Writing before the free pointer is moved, then moving it to the real
    /// (32-rounded) size afterward, is the standard memory-safe manual-allocation pattern: only
    /// memory at-or-past the free pointer at the time of each write is ever touched.
    function _encodeCborBigIntArray(uint256[] memory values) private pure returns (bytes memory out) {
        uint256 n = values.length;
        uint256 dataStart;
        assembly ("memory-safe") {
            out := mload(0x40)
            dataStart := add(out, 0x20)
        }
        uint256 pos = _writeCborArrayHeader(dataStart, n);
        for (uint256 i = 0; i < n; i++) {
            pos = _writeCborBigInt(pos, values[i]);
        }
        uint256 actualLen = pos - dataStart;
        assembly ("memory-safe") {
            mstore(out, actualLen)
            mstore(0x40, add(dataStart, and(add(actualLen, 0x1f), not(0x1f))))
        }
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev clamp(v_start + slope * (e - t_start), floor, cap).
    function _clampWeight(WeightRecord memory w, uint64 e) internal pure returns (int256 weight) {
        int256 raw = w.vStart + w.slope * (int256(uint256(e)) - int256(uint256(w.tStart)));
        weight = raw < w.floor ? w.floor : (raw > w.cap ? w.cap : raw);
    }

    /// @dev Per-record sanity required at write time: 0 <= floor <= cap <= 1.
    function _sane(WeightRecord memory w) internal pure returns (bool) {
        return w.floor >= 0 && w.floor <= w.cap && w.cap <= WAD;
    }

    /// @dev Sum of every registered stream's weight at `atEpoch`, excluding `excludeIds`.
    function _sumWeightsExcluding(uint64[] memory excludeIds, uint64 atEpoch) internal view returns (int256 sum) {
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            bool excluded = false;
            for (uint256 j = 0; j < excludeIds.length; j++) {
                if (excludeIds[j] == id) {
                    excluded = true;
                    break;
                }
            }
            if (!excluded) sum += _effectiveWeight(id, atEpoch);
        }
    }

    /// @dev A stream's weight at `atEpoch`, using a still-pending SET_WEIGHT/STEP_WEIGHT write's
    /// record instead of the stale settled one when queued (the larger of the two if both are
    /// queued), so the WAD guardrail can't be bypassed by splitting increases across batches.
    function _effectiveWeight(uint64 id, uint64 atEpoch) internal view returns (int256 w) {
        w = _clampWeight(_streams[id].weightRecord, atEpoch);
        if (_pendingExists[id][PendingOp.SET_WEIGHT]) {
            int256 pw = _clampWeight(_pending[id][PendingOp.SET_WEIGHT].weightRecord, atEpoch);
            if (pw > w) w = pw;
        }
        if (_pendingExists[id][PendingOp.STEP_WEIGHT]) {
            int256 pw = _clampWeight(_pending[id][PendingOp.STEP_WEIGHT].weightRecord, atEpoch);
            if (pw > w) w = pw;
        }
    }

    function _pendingRegistrationCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            if (_pendingKeys[i].op == PendingOp.REGISTER) count++;
        }
    }

    function _shareOf(Stream storage s, address wallet) internal view returns (uint256) {
        for (uint256 i = 0; i < s.shares.length; i++) {
            if (s.shares[i].wallet == wallet) return s.shares[i].share;
        }
        return 0;
    }

    /// @dev Closes out the current period: each recipient's earned-minus-claimed amount moves
    /// into `payable` under the OLD map, the rounding residue burns, and accrual state resets.
    function _foldAndBurnResidue(Stream storage s) internal {
        uint256 pool = s.accrued;
        uint256 earnedSum;
        for (uint256 i = 0; i < s.shares.length; i++) {
            address wallet = s.shares[i].wallet;
            uint256 earned = (s.shares[i].share * pool) / SHARE_TOTAL;
            earnedSum += earned;
            uint256 claimed = s.claimedPeriod.amount[wallet];
            if (earned > claimed) {
                _ledgerIncrement(s.payableLedger, wallet, earned - claimed);
            }
        }
        uint256 residue = pool - earnedSum;
        s.accrued = 0;
        _ledgerClearAll(s.claimedPeriod);

        if (residue > 0) {
            FVMPay.burn(residue);
            totalBurnMinted += residue;
        }
    }

    function _queueWrite(uint64 id, PendingOp op, Pending memory p) internal {
        _pending[id][op] = p;
        _pendingExists[id][op] = true;
        _pendingKeys.push(PendingKey({id: id, op: op}));
        if (p.effectiveEpoch < nextTransitionEpoch) nextTransitionEpoch = p.effectiveEpoch;
    }

    function _removePendingKey(uint64 id, PendingOp op) internal {
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            if (_pendingKeys[i].id == id && _pendingKeys[i].op == op) {
                _swapRemove(_pendingKeys, i);
                return;
            }
        }
    }

    /// @dev Remove index `i` by swapping in the last element; order is not preserved.
    function _swapRemove(PendingKey[] storage arr, uint256 i) internal {
        arr[i] = arr[arr.length - 1];
        arr.pop();
    }

    /// @dev Remove index `i` by swapping in the last element; order is not preserved.
    function _swapRemove(uint64[] storage arr, uint256 i) internal {
        arr[i] = arr[arr.length - 1];
        arr.pop();
    }

    function _recomputeNextTransition() internal {
        uint64 best = type(uint64).max;
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            uint64 e = _pending[_pendingKeys[i].id][_pendingKeys[i].op].effectiveEpoch;
            if (e < best) best = e;
        }
        nextTransitionEpoch = best;
    }

    function _removeTombstoneId(uint64 id) internal {
        for (uint256 i = 0; i < _tombstoneIds.length; i++) {
            if (_tombstoneIds[i] == id) {
                _swapRemove(_tombstoneIds, i);
                return;
            }
        }
    }

    function _removeStreamId(uint64 id) internal {
        for (uint256 i = 0; i < _streamIds.length; i++) {
            if (_streamIds[i] == id) {
                _swapRemove(_streamIds, i);
                return;
            }
        }
    }

    function _ledgerIncrement(Ledger storage l, address wallet, uint256 delta) internal {
        if (delta == 0) return;
        if (l.indexPlusOne[wallet] == 0) {
            l.wallets.push(wallet);
            l.indexPlusOne[wallet] = l.wallets.length;
        }
        l.amount[wallet] += delta;
    }

    function _ledgerRemove(Ledger storage l, address wallet) internal {
        uint256 idx1 = l.indexPlusOne[wallet];
        if (idx1 == 0) return;
        uint256 lastIdx = l.wallets.length - 1;
        address lastWallet = l.wallets[lastIdx];
        l.wallets[idx1 - 1] = lastWallet;
        l.indexPlusOne[lastWallet] = idx1;
        l.wallets.pop();
        delete l.indexPlusOne[wallet];
        delete l.amount[wallet];
    }

    /// @dev Explicit teardown of both mappings: `delete` on a struct doesn't recurse into
    /// mapping members, so a later id-reuse could otherwise resurface stale entries.
    function _ledgerClearAll(Ledger storage l) internal {
        uint256 n = l.wallets.length;
        for (uint256 i = 0; i < n; i++) {
            address wallet = l.wallets[i];
            delete l.amount[wallet];
            delete l.indexPlusOne[wallet];
        }
        delete l.wallets;
    }

    function _ledgerView(Ledger storage l) internal view returns (LedgerRow[] memory rows) {
        rows = new LedgerRow[](l.wallets.length);
        for (uint256 i = 0; i < l.wallets.length; i++) {
            rows[i] = LedgerRow({wallet: l.wallets[i], amount: l.amount[l.wallets[i]]});
        }
    }

    /// @dev Applies every queued write whose effectiveEpoch has arrived, in (effectiveEpoch, id) order.
    function _settle() internal {
        uint64 nowEpoch = uint64(block.number);
        while (true) {
            bool found = false;
            uint256 bestIdx = 0;
            uint64 bestEpoch = 0;
            uint64 bestId = 0;
            for (uint256 i = 0; i < _pendingKeys.length; i++) {
                PendingKey memory k = _pendingKeys[i];
                uint64 e = _pending[k.id][k.op].effectiveEpoch;
                if (e > nowEpoch) continue;
                if (!found || e < bestEpoch || (e == bestEpoch && k.id < bestId)) {
                    found = true;
                    bestIdx = i;
                    bestEpoch = e;
                    bestId = k.id;
                }
            }
            if (!found) break;

            PendingKey memory key = _pendingKeys[bestIdx];
            _apply(key.id, key.op);
            delete _pending[key.id][key.op];
            _pendingExists[key.id][key.op] = false;
            _pendingKeys[bestIdx] = _pendingKeys[_pendingKeys.length - 1];
            _pendingKeys.pop();
        }
        _recomputeNextTransition();
    }

    function _apply(uint64 id, PendingOp op) internal {
        Pending storage p = _pending[id][op];
        if (op == PendingOp.REGISTER) {
            Stream storage s = _streams[id];
            s.exists = true;
            s.weightRecord = p.weightRecord;
            s.kind = p.distributionKind;
            s.writer = p.writer;
            _streamIds.push(id);
        } else if (op == PendingOp.SET_WEIGHT || op == PendingOp.STEP_WEIGHT) {
            _streams[id].weightRecord = p.weightRecord;
        } else if (op == PendingOp.SET_DISTRIBUTION) {
            Stream storage s = _streams[id];
            _foldAndBurnResidue(s);
            s.kind = p.distributionKind;
            s.writer = p.writer;
        } else if (op == PendingOp.REMOVE) {
            _applyRemove(id);
        }
    }

    function _applyRemove(uint64 id) internal {
        Stream storage s = _streams[id];
        _foldAndBurnResidue(s);

        if (s.payableLedger.wallets.length > 0) {
            Tombstone storage t = _tombstones[id];
            t.exists = true;
            uint256 n = s.payableLedger.wallets.length;
            for (uint256 i = 0; i < n; i++) {
                address wallet = s.payableLedger.wallets[i];
                _ledgerIncrement(t.payableLedger, wallet, s.payableLedger.amount[wallet]);
            }
            _tombstoneIds.push(id);
        }
        _ledgerClearAll(s.payableLedger);

        delete _streams[id];
        _removeStreamId(id);
    }
}
