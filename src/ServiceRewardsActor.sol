// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// Service Rewards Actor (SRA) — FIP-0118 service-stream share computation contract (issue #4)
//
// Responsibilities: maintain the orchestrator registry, stablecoin/Filecoin Pay allowlists,
//       and quarterly volume FPV state; compute service-stream shares per SplitRule
//       (largest-remainder method) and write them to f02 (SetShares);
//       export AggregatedFPV(Q) for the SWA. The SRA never receives or holds value.
//
// Basis: docs/sra-design.md (design, tests, decisions, security review; C1-C8 conflict rulings)
//   - C1: registerPairs uses a named struct Pair[] (inline tuple-array params are illegal in Solidity)
//   - C6: the PRICE_BAND reference "last bound qualifying print" is stored in the Quarter namespace (cross-quarter global field)
//   - T1: largest-remainder method per design §2.5.3 (remainder descending, first residue entries +1)
//   - D1: all-zero volume -> submitShares submits [{f099, 1e18}] to burn
//   - D2: admitted (incl. frozen) <= 64; Admit rejects when full; only Remove releases; Freeze does not release
//   - D3a: correctVolume bidirectional correction (unanimousNoHold + in-body verification-window check)
//   - S5: freeze snapshot uses freezeEpochs/unfreezeEpochs history arrays + paired-interval determination (E+POST instant)
//
// Storage: 4 ERC-7201 namespaces (Registry/AdmittedLists/Quarter/Params),
//       reusing Solstice.Owners (dual Safe) and Solstice.PendingTasks (governance queue).
// ============================================================================

import {Epoch, currentEpoch} from "./lib/Epoch.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {Share} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
import {IsASafe} from "./lib/IsASafe.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";

// ----------------------------------------------------------------------------
// Top-level types (test files import from this file: Pair / PricePeriod / FPV)
// ----------------------------------------------------------------------------

/// @notice (payer, operator) binding pair. C1: the design's §2.3.1 inline tuple-array signature is
///         illegal in Solidity 0.8.36 (Error 3546); replaced with a named struct (ABI encoding is still a tuple array).
struct Pair {
    address payer;
    address operator;
}

/// @notice A single FIL pricing period (fee-auction print). Implied rate = lotUsd / claimFil (USD per FIL).
struct PricePeriod {
    uint64 printEpoch; // print settlement epoch
    uint256 lotUsd; // lot face value (USD, integer)
    uint256 claimFil; // claim FIL consumed (attoFIL)
    uint256 attoFil; // FIL amount settled in this period
}

/// @notice Quarterly FPV: stablecoin face value + FIL pricing-period vector; usdValue is the final value after finalizeConversion.
struct FPV {
    uint256 stableUSD; // stablecoin component (face USD)
    PricePeriod[] filPeriods; // FIL component, <= MAX_PRICE_PERIODS entries
    uint256 usdValue; // USD final value after FinalizeConversion (0 if unconverted)
    bool posted; // posted flag (at most once per quarter)
}

contract ServiceRewardsActor is UnanimousGovernance {
    using IsASafe for address;
    using OwnersLibrary for address;

    // ------------------------------------------------------------------------
    // Constants and immutable config (design §2.6: quarter/window/hold compile-time constants, passed via constructor)
    // ------------------------------------------------------------------------

    /// @dev f02's service stream fixed id = 2 (f02-design: "Migration pins consensus = 1 and service = 2").
    uint64 private constant SERVICE_STREAM_ID = 2;

    /// @dev Total share (f02 encoding constraint: Σ shares must be exactly == 1e18).
    uint256 private constant SHARE_TOTAL = 1e18;

    /// @dev PRICE_BAND in basis points (10000 = 100%). Test assumption H-band: 2000 = ±20%.
    uint256 private constant BASIS_POINTS = 10_000;

    /// @dev D2: admitted orchestrator cap (incl. frozen), matching f02 MAX_RECIPIENTS.
    uint256 private constant MAX_ORCHESTRATORS = 64;
    uint256 private constant MAX_PAIRS = 64; // registerPairs batch bound (audit C1: aligns with MAX_ORCHESTRATORS)
    uint256 private constant MAX_ALLOWLIST = 64; // per-allowlist array bound (audit F2)

    /// @dev Business-domain upper bounds on the FPV input fields (audit V1/V2/V3 fix).
    ///      The security review's "Integer overflow ✅ Safe" conclusion (§5.5) relies on an unenforced
    ///      "business domain ~1e6" assumption; these bounds are now enforced at the input entries
    ///      (postVolume/correctVolume, via _validateFpvBounds) so the arithmetic in
    ///      _checkPriceBand / _finalizeConversion / _computeShares cannot overflow:
    ///        - _checkPriceBand (V1): lotUsd × claimFil × (BASIS_POINTS+band) ≤ 1e30×1e30×12000 ≈ 1.2e64 ≪ 2^256
    ///        - _finalizeConversion (V2): attoFil × lotUsd ≤ 1e27×1e30 = 1e57 ≪ 2^256
    ///        - _computeShares (V3): usd per orchestrator ≤ 1e30 + 32×1e57 ≈ 3.3e58 < 2^256/1e18;
    ///          total (≤ 64) ≤ 64×3.3e58 ≈ 2.1e60 ≪ 2^256
    ///
    ///      Magnitude rationale (why 1e30 / 1e27, and why MAX_CLAIM_FIL is not tightened to the FIL supply):
    ///        - Loose-by-design: the assumed business domain is ~1e6 USD/quarter (§5.5); 1e30 is ~24 orders
    ///          of magnitude above it (≈ 1e16 × Earth's annual GDP). The bounds are immutable `constant`s,
    ///          so the looseness is a conscious trade — permanent headroom instead of a tight-but-risky cap —
    ///          while the arithmetic chain above still closes with ≥ 3.5× headroom at its tightest link (V3).
    ///        - MAX_ATTO_FIL = 1e27 (= 1e9 FIL) is the chain's keystone and its only *physical* bound:
    ///          Filecoin's total supply is ~2e9 FIL, so a single print's attoFil can never exceed 1e9 FIL.
    ///          Loosening it to 1e30 would make per-orchestrator usd ≈ 3.2e61 > 2^256/1e18 and re-open V3.
    ///        - MAX_CLAIM_FIL = 1e30 is intentionally left at the symmetric value: claimFil sits in the
    ///          *denominator* of _finalizeConversion (`attoFil × lotUsd / claimFil` — larger only shrinks
    ///          the result; the only dangerous value is 0, guarded by ZeroClaimFil), and in _checkPriceBand
    ///          the product 1e30×1e30×12000 ≈ 1.2e64 still leaves ~13 orders of magnitude below 2^256.
    ///          Tightening it would buy no additional arithmetic safety.
    ///      ⚠️ Maintenance: the closure assumes all four bounds + MAX_PRICE_PERIODS(32) + MAX_ORCHESTRATORS(64)
    ///      hold together. If any of these is ever changed, re-derive the chain (§5.5) before shipping —
    ///      the links are interdependent, not independent.
    uint256 private constant MAX_STABLE_USD = 1e30; // stablecoin face USD per quarter per orchestrator
    uint256 private constant MAX_LOT_USD = 1e30; // lot face value USD per print
    uint256 private constant MAX_CLAIM_FIL = 1e30; // claim FIL per print — bounds the band-check products (V1); denominator in V2 (larger = safer)
    uint256 private constant MAX_ATTO_FIL = 1e27; // = 1e9 FIL per print — network supply is ~2e9 FIL (V2)

    uint64 private immutable EPOCHS_PER_QUARTER;
    uint64 private immutable POST_PERIOD;
    uint64 private immutable VERIFICATION_WINDOW;
    uint64 private immutable SRA_CANCEL_HOLD;
    uint64 private immutable ACTIVATION_EPOCH;

    // ------------------------------------------------------------------------
    // ERC-7201 storage layout (4 namespaces)
    // ------------------------------------------------------------------------

    struct OrchestratorInfo {
        bool admitted; // admitted
        bool frozen; // current frozen state (checked immediately by registerPairs/postVolume)
        Epoch[] freezeEpochs; // epoch of each freeze execution (S5 freeze history array)
        Epoch[] unfreezeEpochs; // epoch of each unfreeze execution
        address successor; // binding resolution chain after replace (non-zero = transferred to successor; design-gap completion)
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Registry
    struct SraStorageRegistry {
        mapping(address orch => OrchestratorInfo) orchestrators;
        mapping(bytes32 pairId => address orch) bindings; // pairId = keccak256(abi.encode(payer, operator))
        uint64 admittedCount; // includes frozen, used for the D2 cap check
        address[] admittedList; // enumerable admitted (needed by finalize/submitShares/aggregatedFPV traversal; design-gap completion)
    }

    /// @custom:storage-location erc7201:Solstice.SRA.AdmittedLists
    struct SraStorageLists {
        mapping(address => bool) stablecoins; // admitted stablecoins (valued at face USD)
        mapping(address => bool) filecoinPayContracts; // admitted Filecoin Pay contracts
        address[] stablecoinList; // needed for exclusive updates (design-gap completion)
        address[] filecoinPayList;
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Quarter
    struct SraStorageQuarter {
        mapping(uint64 Q => mapping(address orch => FPV)) fpv;
        mapping(uint64 Q => bool) conversionFinalized; // idempotency flag
        // C6: PRICE_BAND reference — the rate of the last bound qualifying print (rational pair; anchored, updated at finalize)
        uint256 lastBoundPrintLotUsd;
        uint256 lastBoundPrintClaimFil;
        bool hasBoundPrint; // cold-start flag (system never had a qualifying print -> no reference to reject against, accepted)
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Params
    struct SraStorageParams {
        uint256 minLot; // MIN_LOT (thin auction guardrail)
        uint256 priceBand; // PRICE_BAND (basis points)
        uint256 maxPricePeriods; // MAX_PRICE_PERIODS
    }

    // keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff)) — precomputed and hardcoded
    bytes32 private constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
    bytes32 private constant LISTS_SLOT = 0x6b063b99e710dc539d819b661c65b9a94a4c91adbbbff20449f292eda97f9300;
    bytes32 private constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;
    bytes32 private constant PARAMS_SLOT = 0xe21afbd697880784c3da970abdca3a316f22b4c4fc74f2fceb073d8e55bcad00;

    function _registry() internal pure returns (SraStorageRegistry storage r) {
        assembly ("memory-safe") {
            r.slot := REGISTRY_SLOT
        }
    }

    function _lists() internal pure returns (SraStorageLists storage l) {
        assembly ("memory-safe") {
            l.slot := LISTS_SLOT
        }
    }

    function _quarter() internal pure returns (SraStorageQuarter storage q) {
        assembly ("memory-safe") {
            q.slot := QUARTER_SLOT
        }
    }

    function _params() internal pure returns (SraStorageParams storage p) {
        assembly ("memory-safe") {
            p.slot := PARAMS_SLOT
        }
    }

    // ------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------

    event OrchestratorAdmitted(address indexed orch);
    event OrchestratorRemoved(address indexed orch);
    event OrchestratorFrozen(address indexed orch);
    event OrchestratorUnfrozen(address indexed orch);
    event OrchestratorReplaced(address indexed oldOrch, address indexed newOrch);
    event BindingReassigned(address indexed payer, address indexed operator, address indexed orch);
    event AdmittedListsUpdated(uint256 stablecoinCount, uint256 filecoinPayCount);
    event PricingParamsUpdated(uint256 minLot, uint256 priceBand, uint256 maxPricePeriods);
    event VolumePosted(uint64 indexed q, address indexed orch);
    event VolumeCorrected(uint64 indexed q, address indexed orch);
    event ConversionFinalized(uint64 indexed q);
    event SharesSubmitted(uint64 indexed q, uint256 recipientCount, uint256 totalUsd);

    error NotAdmitted(address orch);
    error AlreadyAdmitted(address orch);
    error NotFrozen(address orch);
    error AlreadyFrozen(address orch);
    error AtCapacity();
    error AlreadyBound(bytes32 pairId);
    error NotInPostingWindow(uint64 q);
    error NotInVerificationWindow(uint64 q);
    error NotBound(uint64 q);
    error AlreadyPosted(uint64 q);
    error TooManyPricePeriods(uint64 q);
    error PriceBandExceeded(uint64 printEpoch);
    error ZeroClaimFil();
    error TooManyPairs(); // audit C1: registerPairs batch exceeds MAX_PAIRS
    error InvalidParameter();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @param owner1,owner2 governance dual Safe (must be Safe proxies)
    /// @param epochsPerQuarter quarter length (epochs)
    /// @param postPeriod posting window (epochs)
    /// @param verificationWindow verification window (epochs)
    /// @param cancelHold governance hold (epochs)
    /// @param activationEpoch end epoch of quarter 0 (window start)
    /// @param minLot,priceBand,maxPricePeriods initial FIL pricing parameters (governable)
    constructor(
        address owner1,
        address owner2,
        uint64 epochsPerQuarter,
        uint64 postPeriod,
        uint64 verificationWindow,
        uint64 cancelHold,
        uint64 activationEpoch,
        uint256 minLot,
        uint256 priceBand,
        uint256 maxPricePeriods
    ) {
        owner1.isProbablyASafe();
        owner2.isProbablyASafe();
        owner1.addOwner();
        owner2.addOwner();

        // audit E2: deployment-time parameter validation, aligned with setPricingParams (G1)
        require(maxPricePeriods > 0 && priceBand <= BASIS_POINTS && minLot <= MAX_LOT_USD, InvalidParameter());
        require(epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0, InvalidParameter());

        EPOCHS_PER_QUARTER = epochsPerQuarter;
        POST_PERIOD = postPeriod;
        VERIFICATION_WINDOW = verificationWindow;
        SRA_CANCEL_HOLD = cancelHold;
        ACTIVATION_EPOCH = activationEpoch;

        SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;
        p.maxPricePeriods = maxPricePeriods;
    }

    // ------------------------------------------------------------------------
    // Window and quarter utilities (design §2.5.1: Epoch = block.number)
    // ------------------------------------------------------------------------

    function _qEnd(uint64 q) internal view returns (Epoch) {
        // S1C: Q × EPOCHS_PER_QUARTER uses a uint256 intermediate to guard overflow
        uint256 end = uint256(ACTIVATION_EPOCH) + uint256(q) * uint256(EPOCHS_PER_QUARTER);
        return Epoch.wrap(uint96(end));
    }

    /// @dev posting window (E, E+POST].
    function _inPostingWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch e = _qEnd(q);
        return nowE > e && nowE <= e + Epoch.wrap(uint96(POST_PERIOD));
    }

    /// @dev verification window (E+POST, E+POST+VERIFY].
    function _inVerificationWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch postEnd = _qEnd(q) + Epoch.wrap(uint96(POST_PERIOD));
        return nowE > postEnd && nowE <= postEnd + Epoch.wrap(uint96(VERIFICATION_WINDOW));
    }

    /// @dev post-binding: now > E+POST+VERIFY.
    function _afterBinding(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch verifyEnd = _qEnd(q) + Epoch.wrap(uint96(POST_PERIOD)) + Epoch.wrap(uint96(VERIFICATION_WINDOW));
        return nowE > verifyEnd;
    }

    /// @dev frozen determination at the E+POST instant (S5 snapshot semantics: derivable at any point, independent of call timing).
    function _frozenAtPostEnd(address orch, uint64 q) internal view returns (bool) {
        return _isFrozenAt(orch, _qEnd(q) + Epoch.wrap(uint96(POST_PERIOD)));
    }

    /// @dev Determines whether the epoch falls inside any [freezeEpochs[i], unfreezeEpochs[i]) freeze interval.
    function _isFrozenAt(address orch, Epoch e) internal view returns (bool) {
        OrchestratorInfo storage o = _registry().orchestrators[orch];
        uint256 n = o.freezeEpochs.length;
        for (uint256 i = 0; i < n; i++) {
            if (e >= o.freezeEpochs[i]) {
                if (i < o.unfreezeEpochs.length && e >= o.unfreezeEpochs[i]) {
                    continue; // this interval already unfrozen; check the next
                }
                return true;
            }
            return false; // freezeEpochs is increasing; later ones are even larger
        }
        return false;
    }

    // ------------------------------------------------------------------------
    // 2.3.1 Orchestrator operations (called by self, no governance)
    // ------------------------------------------------------------------------

    /// @notice An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another (uniqueness, 📄 §3.3).
    /// @dev C1: parameter uses a named struct Pair[] (inline tuple-array params are illegal in Solidity).
    function registerPairs(Pair[] calldata pairs) external {
        require(pairs.length <= MAX_PAIRS, TooManyPairs()); // audit C1: batch bound
        require(_isAdmitted(msg.sender), NotAdmitted(msg.sender));
        require(!_isFrozen(msg.sender), NotFrozen(msg.sender));

        SraStorageRegistry storage r = _registry();
        for (uint256 i = 0; i < pairs.length; i++) {
            bytes32 pairId = _pairId(pairs[i].payer, pairs[i].operator);
            address current = r.bindings[pairId];
            // Uniqueness: if bound and the bound orchestrator (resolved along the alias chain to the current valid one) is still admitted -> reject;
            // if the bound orchestrator was Removed (admitted=false and no successor) -> treated as unclaimed, claimable (📄 §4.2).
            // T6: after replace, bindings still point to oldOrch (admitted=false, successor=newOrch);
            //     must _resolve to newOrch for the check, otherwise a third party could grab the binding pair.
            if (current != address(0) && _isAdmitted(_resolve(current))) {
                revert AlreadyBound(pairId);
            }
            r.bindings[pairId] = msg.sender;
        }
    }

    /// @notice During posting, at most one posting per quarter of both components; prints exceeding PRICE_BAND are rejected at posting time (📄 §4.2).
    /// @dev C3: the FPV input uses the full 4-field structure; usdValue/posted are maintained internally by the SRA (input values ignored).
    function postVolume(uint64 q, FPV calldata fpv) external {
        require(_isAdmitted(msg.sender), NotAdmitted(msg.sender));
        require(!_isFrozen(msg.sender), NotFrozen(msg.sender));
        require(_inPostingWindow(q), NotInPostingWindow(q));

        SraStorageQuarter storage qt = _quarter();
        FPV storage stored = qt.fpv[q][msg.sender];
        require(!stored.posted, AlreadyPosted(q));

        uint256 maxPeriods = _params().maxPricePeriods;
        require(fpv.filPeriods.length <= maxPeriods, TooManyPricePeriods(q));

        // Audit V1/V2/V3 fix: enforce the business-domain upper bounds on the FPV input at the entry —
        // otherwise extreme lotUsd/claimFil/attoFil/stableUSD could overflow _checkPriceBand /
        // _finalizeConversion / _computeShares and permanently DoS the network (see _validateFpvBounds).
        _validateFpvBounds(fpv);

        // PRICE_BAND validation (📄 §3.3 + deviation D aligned): each print is checked against the
        // "qualifying print of the previous quarter's binding final state" (anchor);
        // the reference updates at quarter binding (finalize), not at posting — preventing single-batch
        // chained stepping from drifting the anchor (anchor-manipulation protection).
        for (uint256 i = 0; i < fpv.filPeriods.length; i++) {
            _checkPriceBand(fpv.filPeriods[i]);
        }

        stored.stableUSD = fpv.stableUSD;
        for (uint256 i = 0; i < fpv.filPeriods.length; i++) {
            stored.filPeriods.push(fpv.filPeriods[i]);
        }
        stored.posted = true;

        emit VolumePosted(q, msg.sender);
    }

    // ------------------------------------------------------------------------
    // 2.3.2 Governance operations (dual Safe + SRA_CANCEL_HOLD, unanimous path)
    // ------------------------------------------------------------------------

    /// @notice Admits an orchestrator; rejects when admitted total >= 64 (🔍 D2).
    /// @dev Re-admit = fresh identity (symmetric with remove cleanup): when an old address is re-admitted after replace,
    ///      clears the residual successor alias chain and freeze history — otherwise submitShares's _frozenAtPostEnd
    ///      checks the address itself (not frozen, passes) but _resolve resolves along the residual chain to the frozen
    ///      successor -> a frozen orchestrator receives a share through the resolve chain (A2 defect, violating S5/S7);
    ///      residual frozen state would also carry over on re-admission.
    function admit(address orch) external unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD)) {
        SraStorageRegistry storage r = _registry();
        require(!r.orchestrators[orch].admitted, AlreadyAdmitted(orch));
        require(r.admittedCount < MAX_ORCHESTRATORS, AtCapacity());
        r.orchestrators[orch].admitted = true;
        r.orchestrators[orch].successor = address(0);
        r.orchestrators[orch].frozen = false;
        delete r.orchestrators[orch].freezeEpochs;
        delete r.orchestrators[orch].unfreezeEpochs;
        r.admittedList.push(orch);
        r.admittedCount++;
        emit OrchestratorAdmitted(orch);
    }

    /// @notice Permanent removal; releases all bindings (pairs return to unclaimed) (📄 §4.2).
    function remove(address orch) external unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD)) {
        SraStorageRegistry storage r = _registry();
        require(r.orchestrators[orch].admitted, NotAdmitted(orch));
        r.orchestrators[orch].admitted = false;
        r.orchestrators[orch].frozen = false;
        r.orchestrators[orch].successor = address(0);
        delete r.orchestrators[orch].freezeEpochs;
        delete r.orchestrators[orch].unfreezeEpochs;
        r.admittedCount--;
        _swapRemove(r.admittedList, orch);
        emit OrchestratorRemoved(orch);
    }

    /// @notice Freeze: suspends, zeroes shares, excludes FPV (📄 §4.2). Freeze does not release a slot (D2).
    function freeze(address orch) external unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD)) {
        SraStorageRegistry storage r = _registry();
        require(r.orchestrators[orch].admitted, NotAdmitted(orch));
        require(!r.orchestrators[orch].frozen, AlreadyFrozen(orch));
        r.orchestrators[orch].frozen = true;
        r.orchestrators[orch].freezeEpochs.push(currentEpoch());
        emit OrchestratorFrozen(orch);
    }

    /// @notice Exact restoration (📄 §4.2).
    function unfreeze(address orch) external unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD)) {
        SraStorageRegistry storage r = _registry();
        require(r.orchestrators[orch].admitted, NotAdmitted(orch));
        require(r.orchestrators[orch].frozen, NotFrozen(orch));
        r.orchestrators[orch].frozen = false;
        r.orchestrators[orch].unfreezeEpochs.push(currentEpoch());
        emit OrchestratorUnfrozen(orch);
    }

    /// @notice Operator address change (📄 §4.2). Identity (frozen state/freeze history) and all bindings transfer to newOrch.
    /// @dev bindings store the admitted address; reads resolve along the alias chain to the current valid address (design-gap
    ///      completion: pairIds cannot be enumerated, so bindings do not migrate storage values; an alias indirection layer
    ///      achieves zero-enumeration transfer).
    function replace(address oldOrch, address newOrch)
        external
        unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD))
    {
        SraStorageRegistry storage r = _registry();
        require(r.orchestrators[oldOrch].admitted, NotAdmitted(oldOrch));
        require(!r.orchestrators[newOrch].admitted, AlreadyAdmitted(newOrch));

        // Identity transfer: copy old's frozen state and freeze history to new
        r.orchestrators[newOrch] = r.orchestrators[oldOrch];
        r.orchestrators[newOrch].successor = address(0);
        // old becomes invalid, alias points to new (bindings resolve to new on read)
        r.orchestrators[oldOrch].admitted = false;
        r.orchestrators[oldOrch].successor = newOrch;

        // Replace the element in the enumerable array (admittedCount unchanged)
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            if (r.admittedList[i] == oldOrch) {
                r.admittedList[i] = newOrch;
                break;
            }
        }
        emit OrchestratorReplaced(oldOrch, newOrch);
    }

    /// @notice Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (📄 §4.2).
    function reassignBinding(address payer, address operator, address orch)
        external
        unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD))
    {
        require(_isAdmitted(orch), NotAdmitted(orch));
        _registry().bindings[_pairId(payer, operator)] = orch;
        emit BindingReassigned(payer, operator, orch);
    }

    /// @notice Owner rotation (audit E1): dual-Safe, effective immediately (unanimousNoHold path,
    ///         aligned with upstream SWA's replaceOwner). newOwner must be a Safe proxy.
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        newOwner.isProbablyASafe();
        prevOwner.removeOwner();
        newOwner.addOwner();
    }

    /// @notice Updates the stablecoin + Filecoin Pay allowlists (exclusive update, 📄 §4.2).
    /// @dev Array parameters require normalization (only same-order calldata yields an identical taskId) — I2 risk covered by tests.
    function setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)
        external
        unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD))
    {
        require(stablecoins.length <= MAX_ALLOWLIST && filecoinPayContracts.length <= MAX_ALLOWLIST, InvalidParameter()); // audit F2
        SraStorageLists storage l = _lists();
        // Clear old entries
        for (uint256 i = 0; i < l.stablecoinList.length; i++) {
            delete l.stablecoins[l.stablecoinList[i]];
        }
        for (uint256 i = 0; i < l.filecoinPayList.length; i++) {
            delete l.filecoinPayContracts[l.filecoinPayList[i]];
        }
        // Write new entries
        delete l.stablecoinList;
        delete l.filecoinPayList;
        for (uint256 i = 0; i < stablecoins.length; i++) {
            l.stablecoins[stablecoins[i]] = true;
            l.stablecoinList.push(stablecoins[i]);
        }
        for (uint256 i = 0; i < filecoinPayContracts.length; i++) {
            l.filecoinPayContracts[filecoinPayContracts[i]] = true;
            l.filecoinPayList.push(filecoinPayContracts[i]);
        }
        emit AdmittedListsUpdated(stablecoins.length, filecoinPayContracts.length);
    }

    /// @notice Updates the FIL pricing parameters MIN_LOT/PRICE_BAND/MAX_PRICE_PERIODS (📄 §3.3/§5.2).
    function setPricingParams(uint256 minLot, uint256 priceBand, uint256 maxPricePeriods)
        external
        unanimous(keccak256(msg.data), Epoch.wrap(SRA_CANCEL_HOLD))
    {
        require(maxPricePeriods > 0 && priceBand <= BASIS_POINTS && minLot <= MAX_LOT_USD, InvalidParameter()); // audit B1
        SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;
        p.maxPricePeriods = maxPricePeriods;
        emit PricingParamsUpdated(minLot, priceBand, maxPricePeriods);
    }

    /// @notice Either Safe calls _veto alone to discard a queued change (📄 §4.2 + 📘 _veto).
    function cancelPending(bytes32 taskId) external {
        _veto(taskId);
    }

    // ------------------------------------------------------------------------
    // 2.3.3 correctVolume (dual Safe + effective immediately within the window, unanimousNoHold path)
    // ------------------------------------------------------------------------

    /// @notice Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed value
    ///         or backfills for an unposted orchestrator; exempt from SRA_CANCEL_HOLD (📄 §4.2/§5.3 window-is-hold),
    ///         allows bidirectional correction (🔍 D3a).
    /// @dev The unanimousNoHold modifier handles dual-Safe owner validation; the function body validates the verification window.
    function correctVolume(address orch, uint64 q, FPV calldata fpv) external unanimousNoHold(keccak256(msg.data)) {
        require(_inVerificationWindow(q), NotInVerificationWindow(q));
        require(_isAdmitted(orch), NotAdmitted(orch));
        require(fpv.filPeriods.length <= _params().maxPricePeriods, TooManyPricePeriods(q));

        // Audit V1/V2/V3 fix: same business-domain bounds as postVolume (correctVolume is the governance
        // path into the same FPV storage; it bypasses _checkPriceBand so claimFil > 0 is enforced here too).
        _validateFpvBounds(fpv);

        SraStorageQuarter storage qt = _quarter();
        FPV storage stored = qt.fpv[q][orch];
        stored.stableUSD = fpv.stableUSD;
        delete stored.filPeriods;
        for (uint256 i = 0; i < fpv.filPeriods.length; i++) {
            stored.filPeriods.push(fpv.filPeriods[i]);
        }
        stored.usdValue = 0; // cannot be finalized within the window; defensive reset
        stored.posted = true;

        emit VolumeCorrected(q, orch);
    }

    // ------------------------------------------------------------------------
    // 2.3.4 Mechanism operations (permissionless)
    // ------------------------------------------------------------------------

    /// @notice Callable after the window closes; idempotent; completes the quarter's FIL→USD conversion in one pass (📄 §4.2).
    function finalizeConversion(uint64 q) external {
        _finalizeConversion(q);
    }

    /// @notice Permissionless after binding; triggers conversion (if not yet run) → SplitRule → f02.SetShares(2, map) (📄 §4.2).
    function submitShares(uint64 q) external {
        require(_afterBinding(q), NotBound(q));
        _finalizeConversion(q); // auto-trigger (idempotent)

        SraStorageRegistry storage r = _registry();
        SraStorageQuarter storage qt = _quarter();

        // Collect non-excluded (not frozen at the E+POST instant) orchestrators with usdValue > 0
        address[] memory wallets = new address[](r.admittedList.length);
        uint256[] memory usds = new uint256[](r.admittedList.length);
        uint256 count = 0;
        uint256 total = 0;
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            uint256 usd = qt.fpv[q][orch].usdValue;
            if (usd == 0) continue;
            wallets[count] = _resolve(orch);
            usds[count] = usd;
            total += usd;
            count++;
        }

        Share[] memory shares;
        if (total == 0) {
            // 🔍 D1 all-zero burn: the quarter's service stream is burned (mock verified accepting f099 as a valid recipient)
            shares = new Share[](1);
            shares[0] = Share({wallet: BURN_ADDRESS, share: SHARE_TOTAL});
        } else {
            shares = _computeShares(wallets, usds, count, total);
            // Trim zero-share entries: the largest-remainder method can floor a tiny usdValue to 0
            // when the residue top-up round count is smaller than the number of orchestrators.
            // Real f02 SetShares rejects share==0 entries (as does the mock), so drop them here.
            uint256 kept = 0;
            for (uint256 i = 0; i < shares.length; i++) {
                if (shares[i].share > 0) shares[kept++] = shares[i];
            }
            if (kept < shares.length) {
                Share[] memory trimmed = new Share[](kept);
                for (uint256 i = 0; i < kept; i++) {
                    trimmed[i] = shares[i];
                }
                shares = trimmed;
            }
        }

        FVMRewards.setShares(SERVICE_STREAM_ID, shares);
        emit SharesSubmitted(q, shares.length, total);
    }

    // ------------------------------------------------------------------------
    // 2.3.5 Read-only (for SWA and external audit)
    // ------------------------------------------------------------------------

    /// @notice Returns the post-binding USD aggregate (stablecoin face value + finalized FIL component); reading auto-triggers idempotent finalize.
    /// @dev Aligned with the spec's "reading AggregatedFPV triggers FinalizeConversion" (📄 §3.2/§4.1/§4.2): after binding,
    ///      a read before finalize triggers the conversion (idempotent, same path as submitShares), returning the complete USD
    ///      (incl. the FIL component), with the observable side effect isFinalized=true. Before binding it still returns 0.
    function aggregatedFPV(uint64 q) external returns (uint256 usd) {
        if (!_afterBinding(q)) return 0;
        _finalizeConversion(q);
        SraStorageRegistry storage r = _registry();
        SraStorageQuarter storage qt = _quarter();
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            FPV storage fpv = qt.fpv[q][orch];
            if (!fpv.posted) continue;
            usd += fpv.usdValue; // always complete after finalize (incl. the FIL component)
        }
    }

    function isAdmitted(address orch) external view returns (bool) {
        return _registry().orchestrators[orch].admitted;
    }

    function isFrozen(address orch) external view returns (bool) {
        return _registry().orchestrators[orch].frozen;
    }

    function admittedCount() external view returns (uint64) {
        return _registry().admittedCount;
    }

    function bindingOf(address payer, address operator) external view returns (address) {
        return _resolve(_registry().bindings[_pairId(payer, operator)]);
    }

    function fpvOf(uint64 q, address orch) external view returns (FPV memory) {
        return _quarter().fpv[q][orch];
    }

    function isFinalized(uint64 q) external view returns (bool) {
        return _quarter().conversionFinalized[q];
    }

    function isStablecoinAdmitted(address token) external view returns (bool) {
        return _lists().stablecoins[token];
    }

    function getPricingParams() external view returns (uint256 minLot, uint256 priceBand, uint256 maxPricePeriods) {
        SraStorageParams storage p = _params();
        return (p.minLot, p.priceBand, p.maxPricePeriods);
    }

    function orchestratorCount() external view returns (uint64) {
        return _registry().admittedCount;
    }

    // ------------------------------------------------------------------------
    // Internal logic
    // ------------------------------------------------------------------------

    /// @dev FIL→USD conversion (idempotent): accumulates attoFil × lotUsd / claimFil for every non-excluded posted orchestrator;
    ///      sub-MIN_LOT prints do not participate in pricing (deviation B aligned, 📄 §3.3 qualifying-print semantics).
    ///      On completion updates the PRICE_BAND anchor = the quarter's last qualifying (lotUsd >= minLot) print
    ///      (deviation D aligned: the reference updates at quarter binding; correctVolume has already completed within the
    ///      verification window, so finalize reads the final-state values).
    function _finalizeConversion(uint64 q) internal {
        require(_afterBinding(q), NotBound(q));
        SraStorageQuarter storage qt = _quarter();
        if (qt.conversionFinalized[q]) return;

        SraStorageRegistry storage r = _registry();
        uint256 minLot = _params().minLot;
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            FPV storage fpv = qt.fpv[q][orch];
            if (!fpv.posted) continue;
            uint256 usd = fpv.stableUSD;
            for (uint256 j = 0; j < fpv.filPeriods.length; j++) {
                PricePeriod storage p = fpv.filPeriods[j];
                if (p.lotUsd < minLot) continue; // B: sub-MIN_LOT does not participate in pricing
                usd += p.attoFil * p.lotUsd / p.claimFil; // integer precision (✏️ S9)
            }
            fpv.usdValue = usd;
        }
        qt.conversionFinalized[q] = true;
        emit ConversionFinalized(q);

        // D: anchor update = the quarter's last qualifying print (overwrite-style traversal;
        //    _updateLastBoundPrint filters sub-MIN_LOT internally).
        //    The traversal order is the anchor order: the last qualifying print by admittedList admission order
        //    (a rare edge of cross-orchestrator out-of-order posting; the anchor is always a qualifying print and
        //    band validation only constrains deviation, so this is not manipulable — defensible).
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            FPV storage fpv = qt.fpv[q][orch];
            if (!fpv.posted) continue;
            for (uint256 j = 0; j < fpv.filPeriods.length; j++) {
                _updateLastBoundPrint(fpv.filPeriods[j]);
            }
        }
    }

    /// @dev SplitRule share computation: floor + largest-remainder method (design §2.5.3, T1: remainder descending, first residue entries +1).
    function _computeShares(address[] memory wallets, uint256[] memory usds, uint256 n, uint256 total)
        internal
        pure
        returns (Share[] memory shares)
    {
        shares = new Share[](n);
        uint256[] memory remainders = new uint256[](n);
        bool[] memory bumped = new bool[](n);
        uint256 residue = SHARE_TOTAL;
        for (uint256 i = 0; i < n; i++) {
            shares[i] = Share({wallet: wallets[i], share: usds[i] * SHARE_TOTAL / total});
            remainders[i] = usds[i] * SHARE_TOTAL % total;
            residue -= shares[i].share;
        }
        // Remainder descending: each round tops up +1 to the largest remaining remainder (n <= 64, O(n²) acceptable)
        for (uint256 r = 0; r < residue; r++) {
            uint256 best = type(uint256).max;
            uint256 bestRem = 0;
            for (uint256 i = 0; i < n; i++) {
                if (!bumped[i] && remainders[i] > bestRem) {
                    bestRem = remainders[i];
                    best = i;
                }
            }
            bumped[best] = true;
            shares[best].share += 1;
        }
    }

    /// @dev Business-domain upper-bound validation of an FPV input (audit V1/V2/V3 fix; root cause:
    ///      the FPV fields had no upper bound while the §5.5 "overflow safe" conclusion relies on bounded
    ///      inputs). Enforced at both input entries (postVolume / correctVolume); also enforces claimFil > 0
    ///      here so correctVolume — which does not run _checkPriceBand — cannot introduce a divide-by-zero
    ///      (attoFil × lotUsd / claimFil) at finalize.
    function _validateFpvBounds(FPV calldata fpv) internal pure {
        require(fpv.stableUSD <= MAX_STABLE_USD, InvalidParameter());
        for (uint256 i = 0; i < fpv.filPeriods.length; i++) {
            PricePeriod calldata p = fpv.filPeriods[i];
            require(p.claimFil > 0, ZeroClaimFil());
            require(p.lotUsd <= MAX_LOT_USD, InvalidParameter());
            require(p.claimFil <= MAX_CLAIM_FIL, InvalidParameter());
            require(p.attoFil <= MAX_ATTO_FIL, InvalidParameter());
        }
    }

    /// @dev PRICE_BAND validation: a new print's implied rate deviates from the "qualifying print of the previous
    ///      quarter's binding final state" (anchor) by at most band (basis points).
    ///      The anchor updates at quarter binding (finalize) (deviation D aligned); cold start (no anchor) accepts;
    ///      sub-MIN_LOT prints do not participate in pricing (deviation B aligned: skipped, never become the reference, 📄 §3.3).
    function _checkPriceBand(PricePeriod calldata p) internal view {
        require(p.claimFil > 0, ZeroClaimFil());
        if (p.lotUsd < _params().minLot) return; // B: sub-MIN_LOT does not participate in pricing (not validated)
        SraStorageQuarter storage qt = _quarter();
        if (!qt.hasBoundPrint) return; // cold start / auction drought: no previous print to deviate from -> accepted

        uint256 priceBand = _params().priceBand;
        // newRate/lastRate = (p.lotUsd/p.claimFil) / (last.lotUsd/last.claimFil)
        //   = p.lotUsd * last.claimFil / (last.lotUsd * p.claimFil)
        // band constraint: |newRate/lastRate - 1| <= band/10000
        //   ⇔ (10000-band)/10000 <= ratio <= (10000+band)/10000
        uint256 lhs = p.lotUsd * qt.lastBoundPrintClaimFil * BASIS_POINTS;
        uint256 lower = qt.lastBoundPrintLotUsd * p.claimFil * (BASIS_POINTS - priceBand);
        uint256 upper = qt.lastBoundPrintLotUsd * p.claimFil * (BASIS_POINTS + priceBand);
        require(lhs >= lower && lhs <= upper, PriceBandExceeded(p.printEpoch));
    }

    /// @dev Updates the PRICE_BAND anchor (only called in _finalizeConversion, deviation D aligned);
    ///      sub-MIN_LOT prints never become the reference (deviation B aligned).
    function _updateLastBoundPrint(PricePeriod storage p) internal {
        if (p.lotUsd < _params().minLot) return; // B: sub-MIN_LOT does not participate in pricing (never the reference)
        // Audit V1 deep defense: never let an out-of-domain print become the anchor, even if a future entry
        // bypasses _validateFpvBounds — the anchor must stay within the band-check overflow bound
        // (lastBoundPrintLotUsd × claimFil × (BASIS_POINTS+band) ≤ 1e30×1e30×12000 ≈ 1.2e64 ≪ 2^256).
        if (p.lotUsd > MAX_LOT_USD || p.claimFil > MAX_CLAIM_FIL) return;
        SraStorageQuarter storage qt = _quarter();
        qt.lastBoundPrintLotUsd = p.lotUsd;
        qt.lastBoundPrintClaimFil = p.claimFil;
        qt.hasBoundPrint = true;
    }

    function _isAdmitted(address orch) internal view returns (bool) {
        return _registry().orchestrators[orch].admitted;
    }

    function _isFrozen(address orch) internal view returns (bool) {
        return _registry().orchestrators[orch].frozen;
    }

    /// @dev Resolves a binding along the alias chain to the current valid orchestrator address (replace support).
    function _resolve(address orch) internal view returns (address) {
        address cur = orch;
        while (cur != address(0) && _registry().orchestrators[cur].successor != address(0)) {
            cur = _registry().orchestrators[cur].successor;
        }
        return cur;
    }

    function _pairId(address payer, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(payer, operator));
    }

    function _swapRemove(address[] storage list, address orch) internal {
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            if (list[i] == orch) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }
}
