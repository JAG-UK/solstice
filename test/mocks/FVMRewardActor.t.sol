// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {REWARD_ACTOR_ID, REWARD_ACTOR_ADDRESS, BURN_ACTOR_ID, BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {NO_FLAGS} from "fvm-solidity/FVMFlags.sol";
import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";
import {FVMPay} from "fvm-solidity/FVMPay.sol";
import {FVMMiner} from "fvm-solidity/FVMMiner.sol";

import {MockRewardTest} from "./MockRewardTest.sol";
import {
    WeightRecord,
    DistributionKind,
    Share,
    LedgerRow,
    PendingOp,
    StreamView,
    TombstoneView,
    MockState,
    WAD,
    MAX_STREAMS,
    MAX_RECIPIENTS,
    SHARE_TOTAL
} from "./FVMRewardActor.sol";
import {STEP_WEIGHT_RECORDS, CLAIM, SWA_TIMELOCK} from "../../src/lib/FVMRewardMethod.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";

/// @dev A distinct external caller, so tests can check authorization by identity rather than
/// by happenstance of who the test contract is. The typed methods below go through FVMRewards
/// itself (production code, not a hand-rolled duplicate encoder) so these tests double as
/// FVMRewards<->mock wire-format coverage. `call` serves StepWeightRecords, which has no library
/// wrapper, and tests that send malformed params on purpose.
contract RewardCaller {
    function call(uint64 method, bytes memory params) external returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        require(success, "RewardCaller: precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }

    function registerStream(
        uint64 id,
        WeightRecord memory record,
        DistributionKind kind,
        address writer,
        uint64 activationEpoch
    ) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryRegisterStream(id, record, kind, writer, activationEpoch)));
    }

    function removeStream(uint64 id) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryRemoveStream(id)));
    }

    function setWeightRecords(uint64[] memory ids, WeightRecord[] memory records) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetWeightRecords(ids, records)));
    }

    function setDistribution(uint64 id, DistributionKind kind, address writer) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetDistribution(id, kind, writer)));
    }

    function cancelPending(uint64 id, PendingOp op) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryCancelPending(id, op)));
    }

    function setShares(uint64 id, Share[] memory shares) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetShares(id, shares)));
    }

    function claim(uint64 id, address[] memory wallets) external returns (uint32 exitCode, uint256[] memory amounts) {
        int256 rawExitCode;
        (rawExitCode, amounts) = FVMRewards.tryClaim(id, wallets);
        exitCode = uint32(uint256(rawExitCode));
    }
}

contract FVMRewardActorTest is MockRewardTest {
    using FVMPay for uint64;

    RewardCaller swaCaller;
    RewardCaller writerCaller;
    RewardCaller otherWriterCaller;
    RewardCaller randomCaller;

    uint64 constant SERVICE_ID = 1;
    uint64 constant CONSENSUS_ID = 2;

    address constant RECIPIENT_A = address(0xBEEF);
    address constant RECIPIENT_B = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        swaCaller = new RewardCaller();
        writerCaller = new RewardCaller();
        otherWriterCaller = new RewardCaller();
        randomCaller = new RewardCaller();
        rewardActor().mockSwa(address(swaCaller));
    }

    // -------------------------------------------------------------------------
    // Call helpers
    // -------------------------------------------------------------------------

    function _call(uint64 method, bytes memory params) internal returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        assertTrue(success, "precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }

    function _record(int256 vStart, int256 slope, uint64 tStart, int256 floor, int256 cap)
        internal
        pure
        returns (WeightRecord memory)
    {
        return WeightRecord({vStart: vStart, slope: slope, tStart: tStart, floor: floor, cap: cap});
    }

    /// @dev A record whose weight is the constant `w` at every epoch.
    function _constantRecord(int256 w) internal pure returns (WeightRecord memory) {
        return _record(w, 0, 0, 0, WAD);
    }

    function _registerStream(uint64 id, WeightRecord memory record, DistributionKind kind, address writer)
        internal
        returns (uint32)
    {
        return swaCaller.registerStream(id, record, kind, writer, uint64(block.number) + SWA_TIMELOCK);
    }

    /// @dev Bundles a single id/record into the arrays SetWeightRecords batches over.
    function _singleWeightRecord(uint64 id, WeightRecord memory record)
        internal
        pure
        returns (uint64[] memory ids, WeightRecord[] memory records)
    {
        ids = new uint64[](1);
        ids[0] = id;
        records = new WeightRecord[](1);
        records[0] = record;
    }

    function _setWeightRecords(RewardCaller caller, uint64 id, WeightRecord memory record) internal returns (uint32) {
        (uint64[] memory ids, WeightRecord[] memory records) = _singleWeightRecord(id, record);
        return caller.setWeightRecords(ids, records);
    }

    function _registerExplicit(uint64 id, address writer) internal {
        assertEq(_registerStream(id, _constantRecord(0.1e18), DistributionKind.EXPLICIT, writer), 0);
        _warpPastTimelockAndSettle();
    }

    function _warpPastTimelockAndSettle() internal {
        vm.roll(block.number + SWA_TIMELOCK);
        rewardActor().mockSettle();
    }

    /// @dev f02 has no read methods, so this reads the mock directly rather than dispatching.
    function _getState() internal view returns (MockState memory) {
        return rewardActor().mockState();
    }

    function _streams() internal view returns (StreamView[] memory) {
        return _getState().streams;
    }

    function _shares(address wallet, uint256 amount) internal pure returns (Share[] memory arr) {
        arr = new Share[](1);
        arr[0] = Share({wallet: wallet, share: amount});
    }

    function _wallets(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /// @dev Claim is permissionless, so this goes straight through FVMRewards rather than a
    /// RewardCaller identity.
    function _claim(uint64 id, address[] memory wallets_) internal returns (uint32 exitCode, uint256[] memory amounts) {
        int256 rawExitCode;
        (rawExitCode, amounts) = FVMRewards.tryClaim(id, wallets_);
        exitCode = uint32(uint256(rawExitCode));
    }

    function _payableRow(LedgerRow[] memory rows, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].wallet == wallet) return rows[i].amount;
        }
        return 0;
    }

    // The objection window is 7 days; epochs are 30s.
    function test_SwaTimelock_IsSevenDaysOfEpochs() public pure {
        assertEq(SWA_TIMELOCK, 7 * 24 * 60 * 60 / 30);
    }

    function test_SwaTimelockEpochs_DefaultsToConstant() public view {
        assertEq(rewardActor().swaTimelockEpochs(), SWA_TIMELOCK);
    }

    function test_MockSwaTimelockEpochs_Overrides() public {
        rewardActor().mockSwaTimelockEpochs(10);

        // _registerStream hardcodes SWA_TIMELOCK, not the override, so call directly with a
        // 10-epoch activation instead.
        uint32 exitCode = swaCaller.registerStream(
            SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0), uint64(block.number) + 10
        );
        assertEq(exitCode, 0);

        vm.roll(block.number + 10);
        rewardActor().mockSettle();
        assertEq(_streams().length, 1, "must settle after the overridden (short) hold");
    }

    // -------------------------------------------------------------------------
    // ClampWeight -- clamp(v_start + slope * (e - t_start), floor, cap). Not a dispatched
    // method; exposed directly.
    // -------------------------------------------------------------------------

    function _clampWeight(WeightRecord memory record, uint64 epoch) internal pure returns (int256) {
        return rewardActor().clampWeight(record, epoch);
    }

    function test_ClampWeight_AtTStart_ReturnsVStart() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 1000), 0.95e18);
    }

    function test_ClampWeight_MidRamp_IsLinear() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        // 500 epochs after t_start: 0.95e18 - 100*500 = 0.95e18 - 50000
        assertEq(_clampWeight(r, 1500), 0.95e18 - 50_000);
    }

    function test_ClampWeight_PastFloor_ClampsToFloor() public pure {
        WeightRecord memory r = _record(0.95e18, -1e17, 1000, 0.5e18, 0.95e18);
        // 10 epochs after t_start at slope -1e17/epoch is already far past the 0.5e18 floor.
        assertEq(_clampWeight(r, 1010), 0.5e18);
    }

    function test_ClampWeight_BeforeTStart_ClampsToCap() public pure {
        // e < t_start with a negative slope means (e - t_start) < 0, so raw > v_start = cap.
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 0), 0.95e18);
    }

    function test_ClampWeight_ZeroSlope_IsConstant() public pure {
        WeightRecord memory r = _constantRecord(0.3e18);
        assertEq(_clampWeight(r, 0), 0.3e18);
        assertEq(_clampWeight(r, 1_000_000), 0.3e18);
    }

    function test_MockState_Empty_ReturnsNoStreams() public view {
        assertEq(_streams().length, 0);
    }

    function test_MockState_ReflectsRegisteredStream_WithMatchingWeight() public {
        WeightRecord memory r = _constantRecord(0.4e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.EXPLICIT, address(writerCaller)), 0);
        _warpPastTimelockAndSettle();

        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
        assertEq(streams[0].weightRecord.vStart, r.vStart);
        assertEq(uint8(streams[0].kind), uint8(DistributionKind.EXPLICIT));
        assertEq(streams[0].writer, address(writerCaller));
        assertEq(streams[0].weight, _clampWeight(r, uint64(block.number)));
        assertEq(streams[0].accrued, 0);
    }

    function test_RegisterStream_NotSwa_Forbidden() public {
        uint32 exitCode = randomCaller.registerStream(
            SERVICE_ID,
            _constantRecord(0.1e18),
            DistributionKind.IMPLICIT,
            address(0),
            uint64(block.number) + SWA_TIMELOCK
        );
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RegisterStream_ActivationTooSoon_IllegalArgument() public {
        uint32 exitCode = swaCaller.registerStream(
            SERVICE_ID,
            _constantRecord(0.1e18),
            DistributionKind.IMPLICIT,
            address(0),
            uint64(block.number) + SWA_TIMELOCK - 1
        );
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_FloorAboveCap_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0.6e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_CapAboveOne_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0, WAD + 1);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_FloorBelowZero_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, -1, WAD);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    // validate_weight_record pins v_start inside the clamp band. Outside it the record still
    // evaluates (compute_weight clamps) but its anchor claims a value the schedule can never take,
    // which makes the record's own numbers a lie about what it pays.
    function test_RegisterStream_VStartOutsideClampBand_IllegalArgument() public {
        WeightRecord memory below = _record(0.1e18, 0, 0, 0.2e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, below, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
        WeightRecord memory above = _record(0.6e18, 0, 0, 0.2e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, above, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_ImplicitWithWriter_IllegalArgument() public {
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(writerCaller)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_ExplicitWithoutWriter_IllegalArgument() public {
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.EXPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_DuplicateId_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_AtMaxStreams_IllegalArgument() public {
        for (uint64 i = 0; i < MAX_STREAMS; i++) {
            assertEq(_registerStream(i, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), 0);
        }
        uint64 oneMoreId = MAX_STREAMS;
        assertEq(
            _registerStream(oneMoreId, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.6e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        assertEq(
            _registerStream(CONSENSUS_ID, _constantRecord(0.5e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_PendingUntilActivation() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_streams().length, 0, "stream must not be live before its activation epoch");

        _warpPastTimelockAndSettle();
        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
    }

    function test_RegisterStream_TombstonedId_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 1, "sanity: the outstanding payable produced a tombstone");

        // f02 rejects any id collision it can see, including an undrained tombstone.
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );

        // Once the tombstone drains, the id is free again (f02 doesn't remember past that).
        _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
    }

    // -------------------------------------------------------------------------
    // StepWeightRecords params: FVMRewards has no encoder for this method (out of scope, see
    // src/lib/FVMRewardMethod.sol), but the mock's decode is shared with SetWeightRecords and
    // expects the same CBOR shape ([[id...], [[vStart,slope,tStart,floor,cap]...]]), so these
    // tests build it by hand rather than via abi.encode. Only ever exercised with a single
    // (id, record) pair, so the array headers are hardcoded to 0x81 (length 1).
    // -------------------------------------------------------------------------

    function _cborUint64Len(uint256 v) internal pure returns (uint256) {
        if (v < 24) return 1;
        if (v < 0x100) return 2;
        if (v < 0x10000) return 3;
        if (v < 0x100000000) return 5;
        return 9;
    }

    function _writeCborUint64(bytes memory out, uint256 pos, uint256 v) internal pure returns (uint256) {
        if (v < 24) {
            out[pos] = bytes1(uint8(v));
            return pos + 1;
        }
        if (v < 0x100) {
            out[pos] = 0x18;
            out[pos + 1] = bytes1(uint8(v));
            return pos + 2;
        }
        if (v < 0x10000) {
            out[pos] = 0x19;
            out[pos + 1] = bytes1(uint8(v >> 8));
            out[pos + 2] = bytes1(uint8(v));
            return pos + 3;
        }
        if (v < 0x100000000) {
            out[pos] = 0x1a;
            out[pos + 1] = bytes1(uint8(v >> 24));
            out[pos + 2] = bytes1(uint8(v >> 16));
            out[pos + 3] = bytes1(uint8(v >> 8));
            out[pos + 4] = bytes1(uint8(v));
            return pos + 5;
        }
        out[pos] = 0x1b;
        for (uint256 i = 0; i < 8; i++) {
            out[pos + 1 + i] = bytes1(uint8(v >> (8 * (7 - i))));
        }
        return pos + 9;
    }

    function _cborInt64Len(int256 v) internal pure returns (uint256) {
        return _cborUint64Len(v < 0 ? uint256(-1 - v) : uint256(v));
    }

    /// @dev Writes the unsigned magnitude, then ORs the major-1 (negative) bit into the header
    /// byte already written at `pos` -- correct for every CBOR int64 header form (inline or
    /// 2/3/5/9-byte), since the info bits are identical between major type 0 and 1.
    function _writeCborInt64(bytes memory out, uint256 pos, int256 v) internal pure returns (uint256) {
        if (v >= 0) return _writeCborUint64(out, pos, uint256(v));
        uint256 newPos = _writeCborUint64(out, pos, uint256(-1 - v));
        out[pos] = out[pos] | 0x20;
        return newPos;
    }

    function _cborRecordLen(WeightRecord memory r) internal pure returns (uint256) {
        return 1 + _cborInt64Len(r.vStart) + _cborInt64Len(r.slope) + _cborUint64Len(r.tStart) + _cborInt64Len(r.floor)
            + _cborInt64Len(r.cap);
    }

    function _writeCborRecord(bytes memory out, uint256 pos, WeightRecord memory r) internal pure returns (uint256) {
        out[pos++] = 0x85;
        pos = _writeCborInt64(out, pos, r.vStart);
        pos = _writeCborInt64(out, pos, r.slope);
        pos = _writeCborUint64(out, pos, r.tStart);
        pos = _writeCborInt64(out, pos, r.floor);
        pos = _writeCborInt64(out, pos, r.cap);
        return pos;
    }

    function _setWeightParams(uint64 id, WeightRecord memory record) internal pure returns (bytes memory out) {
        uint256 len = 2 + _cborUint64Len(id) + 1 + _cborRecordLen(record);
        out = new bytes(len);
        uint256 pos = 0;
        out[pos++] = 0x82; // top-level 2-element array
        out[pos++] = 0x81; // ids: 1-element array
        pos = _writeCborUint64(out, pos, id);
        out[pos++] = 0x81; // records: 1-element array
        pos = _writeCborRecord(out, pos, record);
    }

    function test_SetWeightRecords_NotSwa_Forbidden() public {
        uint32 exitCode = _setWeightRecords(randomCaller, SERVICE_ID, _constantRecord(0.1e18));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetWeightRecords_NonexistentStream_NotFound() public {
        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.1e18));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetWeightRecords_MismatchedArrayLengths_IllegalArgument() public {
        uint64[] memory ids = new uint64[](2);
        WeightRecord[] memory records = new WeightRecord[](1);
        uint32 exitCode = swaCaller.setWeightRecords(ids, records);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_DuplicateIdInBatch_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint64[] memory ids = new uint64[](2);
        ids[0] = SERVICE_ID;
        ids[1] = SERVICE_ID;
        WeightRecord[] memory records = new WeightRecord[](2);
        records[0] = _constantRecord(0.5e18);
        records[1] = _constantRecord(0.5e18);

        uint32 exitCode = swaCaller.setWeightRecords(ids, records);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT, "a repeated id queues two PendingKeys for one slot");
    }

    function test_SetWeightRecords_InsaneRecord_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        WeightRecord memory bad = _record(0, 0, 0, 0.9e18, 0.1e18); // floor > cap
        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, bad);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.8e18));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_SumWouldExceedOne_WithPendingWrite_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 firstExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.6e18));
        assertEq(firstExit, 0);

        uint32 secondExit = _setWeightRecords(swaCaller, CONSENSUS_ID, _constantRecord(0.6e18));
        assertEq(
            secondExit,
            USR_ILLEGAL_ARGUMENT,
            "guardrail must count SERVICE_ID's still-pending 0.6e18, not its stale 0.4e18"
        );
    }

    function test_SetWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.7e18));
        assertEq(setExit, 0);

        StreamView[] memory before = _streams();
        assertEq(before[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        StreamView[] memory afterSettle = _streams();
        assertEq(afterSettle[0].weightRecord.vStart, 0.7e18);
    }

    // -------------------------------------------------------------------------
    // StepWeightRecords -- queued under its own (id, STEP_WEIGHT) slot, coexists with SetWeightRecords.
    // -------------------------------------------------------------------------

    function test_StepWeightRecords_NotSwa_Forbidden() public {
        (uint32 exitCode,) =
            randomCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.1e18)));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_StepWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 setExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(setExit, 0);
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.15e18);
    }

    function test_StepWeightRecords_And_SetWeightRecords_AreIndependentSlots() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        // Both queue successfully: distinct (id, op) slots.
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(stepExit, 0);
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.2e18));
        assertEq(setExit, 0);

        assertEq(_getState().pendingWrites.length, 2);
    }

    function test_StepWeightRecords_OccupiedSlot_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 firstExit,) =
            swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(firstExit, 0);
        (uint32 secondExit,) =
            swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.2e18)));
        assertEq(secondExit, USR_ILLEGAL_ARGUMENT, "revising a pending write is cancel + requeue, not a second queue");
    }

    function test_SetShares_NotWriter_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = randomCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetShares_NonexistentStream_NotFound() public {
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetShares_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        uint32 exitCode = randomCaller.setShares(CONSENSUS_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_DoesNotSumToOne_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 under = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL - 1));
        assertEq(under, USR_ILLEGAL_ARGUMENT);
        uint32 over = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL + 1));
        assertEq(over, USR_ILLEGAL_ARGUMENT);
    }

    // A zero share is rejected outright rather than stored as a no-op row: validate_shares treats
    // "listed but paid nothing" as a caller mistake, since omitting the recipient says it exactly.
    function test_SetShares_ZeroShare_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: SHARE_TOTAL});
        shares_[1] = Share({wallet: RECIPIENT_B, share: 0});
        assertEq(writerCaller.setShares(SERVICE_ID, shares_), USR_ILLEGAL_ARGUMENT);
    }

    // Duplicates are rejected rather than summed: two rows for one wallet make the map's meaning
    // depend on iteration order.
    function test_SetShares_DuplicateRecipient_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: SHARE_TOTAL / 2});
        shares_[1] = Share({wallet: RECIPIENT_A, share: SHARE_TOTAL / 2});
        assertEq(writerCaller.setShares(SERVICE_ID, shares_), USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_TooManyRecipients_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint256 n = MAX_RECIPIENTS + 1;
        Share[] memory shares_ = new Share[](n);
        for (uint256 i = 0; i < n; i++) {
            shares_[i] = Share({wallet: address(uint160(i + 1)), share: SHARE_TOTAL / n});
        }
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_Valid_AppliesImmediately_NoTimelock() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = _shares(RECIPIENT_A, SHARE_TOTAL);
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(exitCode, 0);

        // No vm.roll here: SetShares is the writer's own write, not queued under the timelock.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got.length, 1);
        assertEq(got[0].wallet, RECIPIENT_A);
        assertEq(got[0].share, SHARE_TOTAL);
    }

    function test_SetShares_FoldsAccruedIntoPayable_AndBurnsResidue() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        uint32 firstSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(firstSetExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        uint256 burnBefore = BURN_ADDRESS.balance;
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL));
        assertEq(exitCode, 0);

        // Sole recipient held 100%, so folding leaves no rounding residue.
        LedgerRow[] memory payableRows = rewardActor().getPayable(SERVICE_ID);
        assertEq(_payableRow(payableRows, RECIPIENT_A), 0.1 ether);
        assertEq(BURN_ADDRESS.balance, burnBefore, "an exact 100% share leaves no rounding dust to burn");
        assertEq(_streams()[0].accrued, 0, "accrual resets after the fold");

        // New map installed for the next period.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got[0].wallet, RECIPIENT_B);
    }

    function test_RemoveStream_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = randomCaller.removeStream(SERVICE_ID);
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RemoveStream_Nonexistent_NotFound() public {
        uint32 exitCode = swaCaller.removeStream(SERVICE_ID);
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_RemoveStream_QueuedThenRemoved_AndSharesCleared() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setExit, 0);

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        assertEq(_streams().length, 1, "must still be live before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0);
        assertEq(rewardActor().getShares(SERVICE_ID).length, 0);
    }

    function test_RemoveStream_NoOutstandingPayable_NoTombstoneCreated() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 0, "nothing was ever owed, so nothing needs to stay addressable");
    }

    function test_RemoveStream_OutstandingPayable_MovesToTombstone_ClaimableAfterRemoval() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_streams().length, 0);
        TombstoneView[] memory tombstones = _getState().tombstones;
        assertEq(tombstones.length, 1);
        assertEq(tombstones[0].id, SERVICE_ID);
        assertEq(_payableRow(tombstones[0].payableRows, RECIPIENT_A), 0.1 ether);

        (uint32 claimExit, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(claimExit, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);

        // Fully claimed: the tombstone drains and deletes.
        assertEq(_getState().tombstones.length, 0);
    }

    function test_SetDistribution_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode =
            randomCaller.setDistribution(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetDistribution_ToImplicit_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = swaCaller.setDistribution(SERVICE_ID, DistributionKind.IMPLICIT, address(0));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetDistribution_ZeroWriter_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = swaCaller.setDistribution(SERVICE_ID, DistributionKind.EXPLICIT, address(0));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    // The stream's current wallet-to-share map remains in force until the new writer
    // overwrites it via SetShares, so payments continue across the transition.
    function test_SetDistribution_OldWriterStaysAuthorizedUntilTimelockElapses() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 initialSet = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(initialSet, 0);

        uint32 distExit = swaCaller.setDistribution(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller));
        assertEq(distExit, 0);

        // Before the timelock elapses: old writer still authorized, new writer is not.
        uint32 oldWriterExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL));
        assertEq(oldWriterExit, 0);
        uint32 newWriterExitTooEarly = otherWriterCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(newWriterExitTooEarly, USR_FORBIDDEN);

        _warpPastTimelockAndSettle();

        // After the timelock elapses: roles have swapped.
        uint32 oldWriterExitTooLate = writerCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(oldWriterExitTooLate, USR_FORBIDDEN);
        uint32 newWriterExit = otherWriterCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(newWriterExit, 0);
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, address(0xF00D));
    }

    function test_SetDistribution_ApplyFoldsAccruedIntoPayable() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues under RECIPIENT_A

        uint32 distExit = swaCaller.setDistribution(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller));
        assertEq(distExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);
        assertEq(_streams()[0].accrued, 0);
        // The share map itself is untouched by the writer change.
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, RECIPIENT_A);
    }

    function test_CancelPending_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18));
        assertEq(setExit, 0);
        uint32 exitCode = randomCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT);
        assertEq(exitCode, USR_FORBIDDEN);
    }

    // Cancelling a slot with nothing queued must succeed as a no-op, not error.
    function test_CancelPending_EmptySlot_BenignNoOp() public {
        uint32 exitCode = swaCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT);
        assertEq(exitCode, 0);
    }

    function test_CancelPending_DiscardsQueuedSetWeightRecords() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18));
        assertEq(setExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "cancelled write must never apply");
    }

    function test_CancelPending_DiscardsQueuedRegisterStream() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.REGISTER);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0, "cancelled registration must never take effect");
    }

    function test_CancelPending_DiscardsQueuedRemoveStream() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.REMOVE);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 1, "cancelled removal must never take effect");
    }

    // StepWeightRecords is uncancellable in f02, and that is enforced by the actor rather than
    // left to SWA discipline: the discretionary path must not be able to revoke a write the
    // governance gate produced.
    function test_CancelPending_StepWeightRecords_IsRejected() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(stepExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.STEP_WEIGHT);
        assertEq(cancelExit, USR_ILLEGAL_ARGUMENT, "a gate-originated write cannot be cancelled");

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.9e18, "the gate write must still apply");
    }

    function test_CancelPending_OnlyCancelsMatchingOp() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.5e18));
        assertEq(setExit, 0);
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.6e18)));
        assertEq(stepExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        // SET_WEIGHT was cancelled; STEP_WEIGHT still applied.
        assertEq(_streams()[0].weightRecord.vStart, 0.6e18);
    }

    function test_Claim_NonexistentStream_NotFound() public {
        (uint32 exitCode,) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_Claim_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        (uint32 exitCode,) = _claim(CONSENSUS_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_Claim_UnknownWallet_ReturnsZero_NoRevert() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_B));
        assertEq(exitCode, 0, "an all-zero batch is a benign no-op success");
        assertEq(amounts[0], 0);
    }

    function test_Claim_PaysLiveAccrual() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
        assertEq(_streams()[0].accrued, 0.1 ether, "accrued is a period gross total, unaffected by claims");

        // A second claim in the same period pays nothing further: claimed_period tracks it.
        (, uint256[] memory secondAmounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(secondAmounts[0], 0);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
    }

    function _wallets(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // Every other Claim test only ever passes a single wallet, so FVMRewards.tryClaim's
    // returndata-array decode loop (and its trailing free-memory-pointer bump) never runs past
    // one iteration. This exercises count > 1, including the last element specifically.
    function test_Claim_MultipleWallets_ReturnsAmountsInOrder() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: 0.6e18});
        shares_[1] = Share({wallet: RECIPIENT_B, share: 0.4e18});
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether, split 60/40

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A, RECIPIENT_B));
        assertEq(exitCode, 0);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 0.06 ether);
        assertEq(amounts[1], 0.04 ether, "last element of the returned array");
        assertEq(RECIPIENT_A.balance, 0.06 ether);
        assertEq(RECIPIENT_B.balance, 0.04 ether);
    }

    function test_Claim_PaysPayablePlusLive() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 firstSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(firstSetExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        // Fold the period (via a new SetShares) so the 0.1 ether moves into payable.
        uint32 secondSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(secondSetExit, 0);
        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);

        rewardActor().mockAwardBlockReward(1 ether); // another 0.1 ether accrues, live this period

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.2 ether, "payable (closed period) plus live (current period)");
        assertEq(RECIPIENT_A.balance, 0.2 ether);
        assertEq(rewardActor().getPayable(SERVICE_ID).length, 0, "claimed payable row drops");
    }

    function test_AwardBlockReward_SplitsAcrossMinerAndService_ConservationHolds() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.85e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.EXPLICIT, address(writerCaller)), 0
        );
        _warpPastTimelockAndSettle();

        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);

        assertEq(minerPortion, 0.85 ether);
        assertEq(servicePortion, 0.1 ether);
        assertEq(burnAmount, 0.05 ether);
        assertEq(minerPortion + servicePortion + burnAmount, 1 ether, "conservation: BR = miner + service + burn");

        assertEq(rewardActor().totalMintedReward(), 1 ether);
        assertEq(rewardActor().totalBurnMinted(), 0.05 ether);
        assertEq(rewardActor().totalServiceMinted(), 0.1 ether);
        // M = T - B - S is derived, never stored.
        assertEq(
            rewardActor().totalMintedReward() - rewardActor().totalBurnMinted() - rewardActor().totalServiceMinted(),
            minerPortion
        );
        assertEq(BURN_ADDRESS.balance, 0.05 ether);
    }

    function test_AwardBlockReward_NoStreams_AllBurn() public {
        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);
        assertEq(minerPortion, 0);
        assertEq(servicePortion, 0);
        assertEq(burnAmount, 1 ether);
        assertEq(BURN_ADDRESS.balance, 1 ether);
    }

    function test_AwardBlockReward_SelfIssues_ClaimPaysWithoutPreDeal() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // no vm.deal beforehand

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether, "claim must actually move funds, not just report bookkeeping");
    }

    // -------------------------------------------------------------------------
    // Fidelity: native-actor fallback and precompile guard
    // -------------------------------------------------------------------------

    // A native actor: direct EVM CALL fails with USR_UNHANDLED_MESSAGE, not like an account actor.
    function test_DirectEvmCall_ReturnsUnhandledMessage() public {
        (bool ok, bytes memory ret) = REWARD_ACTOR_ADDRESS.call("");
        assertTrue(ok);
        (uint32 exitCode,,) = abi.decode(ret, (uint32, uint64, bytes));
        assertEq(exitCode, USR_UNHANDLED_MESSAGE);
    }

    // restrict_internal_api: f02's internal API is closed to EVM callers, so ThisEpochReward is
    // not a back door to the weight schedule and AwardBlockReward cannot be driven from a
    // contract. Every method below FRC-0042's floor is forbidden, not merely unhandled.
    function test_InternalApi_ForbiddenToEvmCallers() public {
        uint64[4] memory internalMethods = [uint64(1), 2, 3, 4]; // Constructor, Award, ThisEpoch, KPI
        for (uint256 i = 0; i < internalMethods.length; i++) {
            (uint32 exitCode,) = swaCaller.call(internalMethods[i], "");
            assertEq(exitCode, USR_FORBIDDEN, "internal API must be forbidden, not unhandled");
        }
    }

    // Above the floor, an unrecognised method is merely unhandled.
    function test_UnknownExportedMethod_Unhandled() public {
        (uint32 exitCode,) = swaCaller.call(type(uint64).max, "");
        assertEq(exitCode, USR_UNHANDLED_MESSAGE);
    }

    // The real precompile requires delegatecall; a direct call/staticcall must fail.
    function test_DirectCallToPrecompile_Reverts() public {
        (bool ok,) = CALL_ACTOR_BY_ID.call("");
        assertFalse(ok);
    }

    // None of the reward actor's methods accept a value; the mock must not silently drop it.
    function test_NonzeroValue_IllegalArgument() public {
        bytes memory callData = abi.encode(CLAIM, uint256(1), NO_FLAGS, uint64(0), bytes(""), REWARD_ACTOR_ID);
        (bool ok, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        assertTrue(ok);
        (uint32 exitCode,,) = abi.decode(ret, (uint32, uint64, bytes));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    // -------------------------------------------------------------------------
    // Regression: FVMCallActorByIdWithReward must not break existing actor mocks
    // -------------------------------------------------------------------------

    // Exercises _handleBurn's balance debit through the new dispatcher -- would break if the
    // forward to FVMCallActorById used `call` instead of `delegatecall`.
    function test_Regression_Burn_StillDebitsCallerBalance() public {
        uint256 before = address(this).balance;
        assertEq(BURN_ADDRESS.balance, 0);
        BURN_ACTOR_ID.pay(10 ether);
        assertEq(BURN_ADDRESS.balance, 10 ether);
        assertEq(address(this).balance, before - 10 ether);
    }

    // Exercises the storage power actor branch (_handlePower) through the new dispatcher.
    function test_Regression_MinerPower_StillWorks() public {
        mockMiner(555);
        assertTrue(FVMMiner.isMiner(555));
        assertFalse(FVMMiner.isMiner(556));
    }
}
