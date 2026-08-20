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
//   - T1: largest-remainder method per design §2.5.3 (remainder descending, first residue entries +1)
//   - FIP-0118 (FIPs#1275): FIL→USD conversion moved off-chain — FPV is a single USD total, no
//     PricePeriod[]/FinalizeConversion/PRICE_BAND on-chain; all-zero quarter -> SubmitShares no-op
//   - D2: admitted (incl. frozen) <= 64; Admit rejects when full; only Remove releases; Freeze does not release
//   - D3a: correctVolume bidirectional correction (unanimousNoHold + in-body verification-window check)
//   - S5: freeze snapshot uses freezeEpochs/unfreezeEpochs history arrays + paired-interval determination (E+POST instant)
//
// Storage: 4 ERC-7201 namespaces (Registry/AdmittedLists/Quarter/Params),
//       reusing Solstice.Owners (dual Safe) and Solstice.PendingTasks (governance queue).
// ============================================================================

import {Epoch, currentEpoch} from "./lib/Epoch.sol";
import {FixedU18, ONE, ONE_WAD} from "./lib/FixedU18.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {Share} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
import {IsASafe} from "./lib/IsASafe.sol";
// Top-level SRA types (Pair / FPV) and the ERC-7201 storage layout live in
// separate library files (SraTypes.sol / SraStorage.sol) — extracted to simplify
// the #5 proxy refactor; test files import the types from SraTypes.sol.
import {Pair, FPV} from "./lib/SraTypes.sol";
import {SraStorage} from "./lib/SraStorage.sol";

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

    /// @dev PRICE_BAND in basis points (10000 = 100%).
    uint256 private constant BASIS_POINTS = 10_000;

    /// @dev D2: admitted orchestrator cap (incl. frozen), matching f02 MAX_RECIPIENTS.
    uint256 private constant MAX_ORCHESTRATORS = 64;
    uint256 private constant MAX_PAIRS = 64; // registerPairs batch bound, aligns with MAX_ORCHESTRATORS
    uint256 private constant MAX_ALLOWLIST = 64; // per-allowlist array bound

    /// @dev Business-domain upper bound on the quarterly FPV input (18-decimal FixedU18: 1e30 wraps 1e12 USD).
    ///      With the FIL→USD conversion moved off-chain (FIPs#1275), the FPV input is a single USD total,
    ///      so the on-chain arithmetic that must not overflow is only _computeShares:
    ///        - per-orchestrator usd_f ≤ 1e30 → usd_f × 1e18 ≤ 1e48 ≪ 2^256
    ///        - total (≤ MAX_ORCHESTRATORS 64) ≤ 64 × 1e30 = 6.4e31 ≪ 2^256
    ///      Magnitude rationale: the assumed business domain is ~1e6 USD/quarter (§5.5); 1e12 USD is ~6
    ///      orders of magnitude above it — loose-by-design headroom (immutable constant, permanent), while
    ///      the arithmetic chain still closes with ~29 orders of magnitude to spare (1e48 → 2^256 ≈ 1.16e77).
    ///      ⚠️ Maintenance: the closure assumes MAX_FPV_USD and MAX_ORCHESTRATORS(64) hold together.
    FixedU18 private constant MAX_FPV_USD = FixedU18.wrap(1e30); // single USD total per quarter per orchestrator (18-decimal)

    // Epoch-typed immutables (EPOCHS_PER_QUARTER public — sole source of truth for both the SRA
    // and the SWA; SWA reads it via the auto-generated getter instead of duplicating quarter config).
    // All quarter/window/hold values are Epoch-typed (epoch semantics -> Epoch type; POST_PERIOD,
    // VERIFICATION_WINDOW, ACTIVATION_EPOCH follow SRA_CANCEL_HOLD/EPOCHS_PER_QUARTER — no wraps at call sites).
    Epoch public immutable EPOCHS_PER_QUARTER;
    Epoch private immutable POST_PERIOD;
    Epoch private immutable VERIFICATION_WINDOW;
    Epoch private immutable SRA_CANCEL_HOLD;
    Epoch private immutable ACTIVATION_EPOCH;

    // ------------------------------------------------------------------------
    // ERC-7201 storage accessors — layout (structs, slots, assembly getters) lives in
    // SraStorage.sol (separate storage declarations for the #5 proxy refactor);
    // these thin wrappers keep the internal call sites unchanged.
    // ------------------------------------------------------------------------

    function _registry() internal pure returns (SraStorage.SraStorageRegistry storage r) {
        return SraStorage.registry();
    }

    function _lists() internal pure returns (SraStorage.SraStorageLists storage l) {
        return SraStorage.lists();
    }

    function _quarter() internal pure returns (SraStorage.SraStorageQuarter storage q) {
        return SraStorage.quarter();
    }

    function _params() internal pure returns (SraStorage.SraStorageParams storage p) {
        return SraStorage.params();
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
    event PricingParamsUpdated(uint256 minLot, uint256 priceBand);
    event VolumePosted(uint64 indexed q, address indexed orch);
    event VolumeCorrected(uint64 indexed q, address indexed orch);
    event SharesSubmitted(uint64 indexed q, uint256 recipientCount, FixedU18 totalUsd);

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
    error AlreadySubmitted(uint64 q); // FIP: SubmitShares reverts once a quarter's map is submitted
    error NotLatestQuarter(uint64 q); // FIP-0118 §4.2: an older quarter's shares can never overwrite a newer quarter's
    error TooManyPairs(); // registerPairs batch exceeds MAX_PAIRS
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
    /// @param minLot,priceBand initial FIL pricing parameters (governable; authoritative for the off-chain indexer, FIPs#1275)
    constructor(
        address owner1,
        address owner2,
        uint64 epochsPerQuarter,
        uint64 postPeriod,
        uint64 verificationWindow,
        uint64 cancelHold,
        uint64 activationEpoch,
        uint256 minLot,
        uint256 priceBand
    ) {
        owner1.isProbablyASafe();
        owner2.isProbablyASafe();
        owner1.addOwner();
        owner2.addOwner();

        // deployment-time parameter validation, aligned with setPricingParams
        require(priceBand <= BASIS_POINTS, InvalidParameter());
        require(epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0, InvalidParameter());

        EPOCHS_PER_QUARTER = Epoch.wrap(epochsPerQuarter);
        POST_PERIOD = Epoch.wrap(postPeriod);
        VERIFICATION_WINDOW = Epoch.wrap(verificationWindow);
        SRA_CANCEL_HOLD = Epoch.wrap(cancelHold);
        ACTIVATION_EPOCH = Epoch.wrap(activationEpoch);

        SraStorage.SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;
    }

    // ------------------------------------------------------------------------
    // Window and quarter utilities (design §2.5.1: Epoch = block.number)
    // ------------------------------------------------------------------------

    function _qEnd(uint64 q) internal view returns (Epoch) {
        // S1C: Q × EPOCHS_PER_QUARTER uses a uint256 intermediate to guard overflow.
        //
        // Range guard: without the explicit check, an attacker-controlled huge q would wrap
        // inside Epoch.wrap and could collide into the current quarter window, bypassing the
        // window checks (enabling forged shares). The guard rejects end beyond the Epoch
        // width — at uint64, uint64.max × EPOCHS_PER_QUARTER ≥ 2^64 always overflows, so the
        // guard is the revert path for the MaxQuarter probes (test/SRAAdversarial.t.sol).
        uint256 end = uint256(Epoch.unwrap(ACTIVATION_EPOCH)) + uint256(q) * uint256(Epoch.unwrap(EPOCHS_PER_QUARTER));
        require(end <= type(uint64).max, InvalidParameter());
        return Epoch.wrap(uint64(end));
    }

    /// @dev posting window (E, E+POST].
    function _inPostingWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch e = _qEnd(q);
        return nowE > e && nowE <= e + POST_PERIOD;
    }

    /// @dev verification window (E+POST, E+POST+VERIFY].
    function _inVerificationWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch postEnd = _qEnd(q) + POST_PERIOD;
        return nowE > postEnd && nowE <= postEnd + VERIFICATION_WINDOW;
    }

    /// @dev post-binding: now > E+POST+VERIFY.
    function _afterBinding(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch verifyEnd = _qEnd(q) + POST_PERIOD + VERIFICATION_WINDOW;
        return nowE > verifyEnd;
    }

    /// @dev frozen determination at the E+POST instant (S5 snapshot semantics: derivable at any point, independent of call timing).
    function _frozenAtPostEnd(address orch, uint64 q) internal view returns (bool) {
        return _isFrozenAt(orch, _qEnd(q) + POST_PERIOD);
    }

    /// @dev Determines whether the epoch falls inside any [freezeEpochs[i], unfreezeEpochs[i]) freeze interval.
    function _isFrozenAt(address orch, Epoch e) internal view returns (bool) {
        SraStorage.OrchestratorInfo storage o = _registry().orchestrators[orch];
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

    /// @notice An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another (uniqueness, spec §3.3).
    /// @dev C1: parameter uses a named struct Pair[] (inline tuple-array params are illegal in Solidity).
    function registerPairs(Pair[] calldata pairs) external {
        require(pairs.length <= MAX_PAIRS, TooManyPairs()); // batch bound
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = _registry();
        SraStorage.OrchestratorInfo storage o = r.orchestrators[msg.sender];
        require(o.admitted, NotAdmitted(msg.sender));
        require(!o.frozen, NotFrozen(msg.sender));

        for (uint256 i = 0; i < pairs.length; i++) {
            bytes32 pairId = _pairId(pairs[i].payer, pairs[i].operator);
            address current = r.bindings[pairId];
            // Uniqueness: if bound and the bound orchestrator (resolved along the alias chain to the current valid one) is still admitted -> reject;
            // if the bound orchestrator was Removed (admitted=false and no successor) -> treated as unclaimed, claimable (spec §4.2).
            // After replace, bindings still point to oldOrch (admitted=false, successor=newOrch);
            // must _resolve to newOrch for the check, otherwise a third party could grab the binding pair.
            if (current != address(0) && _isAdmitted(_resolve(current))) {
                revert AlreadyBound(pairId);
            }
            r.bindings[pairId] = msg.sender;
        }
    }

    /// @notice During posting, at most one posting per quarter; the value is a single USD total
    ///         (FPV_i(Q): stablecoin face USD + off-chain-converted FIL volume, FIP-0118 FIPs#1275).
    function postVolume(uint64 q, FixedU18 fpv) external {
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = _registry();
        SraStorage.OrchestratorInfo storage o = r.orchestrators[msg.sender];
        require(o.admitted, NotAdmitted(msg.sender));
        require(!o.frozen, NotFrozen(msg.sender));
        require(_inPostingWindow(q), NotInPostingWindow(q));

        // The single USD total is the only on-chain input that feeds _computeShares;
        // bound it at the entry so the share arithmetic cannot overflow (see MAX_FPV_USD).
        require(fpv <= MAX_FPV_USD, InvalidParameter());

        SraStorage.SraStorageQuarter storage qt = _quarter();
        FPV storage stored = qt.fpv[q][msg.sender];
        require(!stored.posted, AlreadyPosted(q));

        stored.usd = fpv; // FixedU18 — 18-decimal USD, type-checked from the entry
        stored.posted = true;

        emit VolumePosted(q, msg.sender);
    }

    // ------------------------------------------------------------------------
    // 2.3.2 Governance operations (dual Safe + SRA_CANCEL_HOLD, unanimous path)
    // ------------------------------------------------------------------------

    /// @notice Admits an orchestrator; rejects when admitted total >= 64 (D2).
    /// @dev Re-admit = fresh identity (symmetric with remove cleanup): when an old address is re-admitted after replace,
    ///      clears the residual successor alias chain and freeze history — otherwise submitShares's _frozenAtPostEnd
    ///      checks the address itself (not frozen, passes) but _resolve resolves along the residual chain to the frozen
    ///      successor, so a frozen orchestrator would receive a share through the resolve chain; residual frozen state
    ///      would also carry over on re-admission.
    function admit(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
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

    /// @notice Permanent removal; releases all bindings (pairs return to unclaimed) (spec §4.2).
    function remove(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
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

    /// @notice Freeze: suspends, zeroes shares, excludes FPV (spec §4.2). Freeze does not release a slot.
    function freeze(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        require(r.orchestrators[orch].admitted, NotAdmitted(orch));
        require(!r.orchestrators[orch].frozen, AlreadyFrozen(orch));
        r.orchestrators[orch].frozen = true;
        r.orchestrators[orch].freezeEpochs.push(currentEpoch());
        emit OrchestratorFrozen(orch);
    }

    /// @notice Exact restoration (spec §4.2).
    function unfreeze(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        require(r.orchestrators[orch].admitted, NotAdmitted(orch));
        require(r.orchestrators[orch].frozen, NotFrozen(orch));
        r.orchestrators[orch].frozen = false;
        r.orchestrators[orch].unfreezeEpochs.push(currentEpoch());
        emit OrchestratorUnfrozen(orch);
    }

    /// @notice Operator address change (spec §4.2). Identity (frozen state/freeze history) and all bindings transfer to newOrch.
    /// @dev bindings store the admitted address; reads resolve along the alias chain to the current valid address (design-gap
    ///      completion: pairIds cannot be enumerated, so bindings do not migrate storage values; an alias indirection layer
    ///      achieves zero-enumeration transfer).
    function replace(address oldOrch, address newOrch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        require(r.orchestrators[oldOrch].admitted, NotAdmitted(oldOrch));
        require(!r.orchestrators[newOrch].admitted, AlreadyAdmitted(newOrch));

        // Identity transfer: copy old's frozen state and freeze history to new
        r.orchestrators[newOrch] = r.orchestrators[oldOrch];
        r.orchestrators[newOrch].successor = address(0);
        // old becomes invalid, alias points to new (bindings resolve to new on read)
        r.orchestrators[oldOrch].admitted = false;
        r.orchestrators[oldOrch].successor = newOrch;

        for (uint256 i = 0; i < r.admittedList.length; i++) {
            if (r.admittedList[i] == oldOrch) {
                r.admittedList[i] = newOrch;
                break;
            }
        }
        emit OrchestratorReplaced(oldOrch, newOrch);
    }

    /// @notice Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (spec §4.2).
    function reassignBinding(address payer, address operator, address orch)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(_isAdmitted(orch), NotAdmitted(orch));
        _registry().bindings[_pairId(payer, operator)] = orch;
        emit BindingReassigned(payer, operator, orch);
    }

    /// @notice Owner rotation: dual-Safe, effective immediately (unanimousNoHold path,
    ///         aligned with upstream SWA's replaceOwner). newOwner must be a Safe proxy.
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        newOwner.isProbablyASafe();
        prevOwner.removeOwner();
        newOwner.addOwner();
    }

    /// @notice Updates the stablecoin + Filecoin Pay allowlists (exclusive update, spec §4.2).
    /// @dev Array parameters require normalization (only same-order calldata yields an identical taskId).
    function setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(stablecoins.length <= MAX_ALLOWLIST && filecoinPayContracts.length <= MAX_ALLOWLIST, InvalidParameter());
        SraStorage.SraStorageLists storage l = _lists();
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

    /// @notice Updates the FIL pricing parameters MIN_LOT/PRICE_BAND (spec §3.3/§5.2).
    ///         FIPs#1275: authoritative for the off-chain indexer's conversion, not an on-chain computation.
    function setPricingParams(uint256 minLot, uint256 priceBand)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(priceBand <= BASIS_POINTS, InvalidParameter());
        SraStorage.SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;
        emit PricingParamsUpdated(minLot, priceBand);
    }

    /// @notice Either Safe calls _veto alone to discard a queued change (spec §4.2, _veto).
    function cancelPending(bytes32 taskId) external {
        _veto(taskId);
    }

    // ------------------------------------------------------------------------
    // 2.3.3 correctVolume (dual Safe + effective immediately within the window, unanimousNoHold path)
    // ------------------------------------------------------------------------

    /// @notice Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed figure,
    ///         or supplies the recomputed figure for an unposted orchestrator; exempt from SRA_CANCEL_HOLD (spec §4.2/§5.3
    ///         window-is-hold), allows bidirectional correction. Value is a single USD total (FIP-0118 FIPs#1275).
    /// @dev The unanimousNoHold modifier handles dual-Safe owner validation; the function body validates the verification window.
    function correctVolume(address orch, uint64 q, FixedU18 value) external unanimousNoHold(keccak256(msg.data)) {
        require(_inVerificationWindow(q), NotInVerificationWindow(q));
        require(_isAdmitted(orch), NotAdmitted(orch));

        // Same business-domain bound as postVolume (governance path into the same FPV storage).
        require(value <= MAX_FPV_USD, InvalidParameter());

        SraStorage.SraStorageQuarter storage qt = _quarter();
        FPV storage stored = qt.fpv[q][orch];
        stored.usd = value; // FixedU18 — 18-decimal USD
        stored.posted = true;

        emit VolumeCorrected(q, orch);
    }

    // ------------------------------------------------------------------------
    // 2.3.4 Mechanism operations (permissionless)
    // ------------------------------------------------------------------------

    /// @notice Permissionless after binding; SplitRule over the bound USD values → f02.SetShares(2, map) (spec §4.2).
    ///         Reverts when this quarter's map has already been submitted (FIP-0118 §4.2); an all-zero quarter is a
    ///         benign no-op: SplitRule is not evaluated and the existing share map stands (FIPs#1275, replacing D1 burn).
    function submitShares(uint64 q) external {
        require(_afterBinding(q), NotBound(q));
        // FIP-0118 §4.2: SubmitShares operates on the **latest** quarter whose volumes are bound, so an
        // older quarter's shares can never overwrite a newer quarter's. Because _afterBinding is monotonic
        // in q, q is the latest bound quarter iff q + 1 is not yet bound. (At q = uint64.max the first
        // require's _qEnd range guard already reverts, so q + 1 cannot overflow here.)
        require(!_afterBinding(q + 1), NotLatestQuarter(q));

        SraStorage.SraStorageRegistry storage r = _registry();
        SraStorage.SraStorageQuarter storage qt = _quarter();
        require(!qt.sharesSubmitted[q], AlreadySubmitted(q));

        // Collect non-excluded (not frozen at the E+POST instant) orchestrators with posted usd > 0
        address[] memory wallets = new address[](r.admittedList.length);
        FixedU18[] memory usds = new FixedU18[](r.admittedList.length);
        uint256 count = 0;
        FixedU18 total;
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            FixedU18 usd = qt.fpv[q][orch].usd;
            if (FixedU18.unwrap(usd) == 0) continue;
            wallets[count] = _resolve(orch);
            usds[count] = usd;
            total = total + usd;
            count++;
        }

        // FIP-0118: an all-zero quarter is a benign no-op — no SplitRule, no SetShares, existing map stands.
        if (FixedU18.unwrap(total) == 0) return;

        Share[] memory shares = _computeShares(wallets, usds, count, total);
        // Trim zero-share entries: the largest-remainder method can floor a tiny usd to 0
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

        qt.sharesSubmitted[q] = true; // CEI: mark before the external call
        FVMRewards.setShares(SERVICE_STREAM_ID, shares);
        emit SharesSubmitted(q, shares.length, total); // totalUsd as FixedU18 (18-decimal USD)
    }

    // ------------------------------------------------------------------------
    // 2.3.5 Read-only (for SWA and external audit)
    // ------------------------------------------------------------------------

    // forge-lint: disable-next-item(mixed-case-function) — FIP-0118 spec method name (selector-affecting)
    /// @notice Returns the post-binding USD aggregate (FIP-0118 §4.2): Σ of each non-excluded posted orchestrator's
    ///         bound USD value. Pure view — the FIL→USD conversion happens off-chain (FIPs#1275), so there is no
    ///         on-chain finalize to trigger.
    /// @dev Reverts NotBound(q) before binding — distinguishes "quarter not yet bound" (call too early; the SWA
    ///      does not need to re-enforce the check) from "quarter with zero declared volume" (legitimately returns 0).
    function aggregatedFPV(uint64 q) external view returns (FixedU18 usd) {
        require(_afterBinding(q), NotBound(q));
        SraStorage.SraStorageRegistry storage r = _registry();
        SraStorage.SraStorageQuarter storage qt = _quarter();
        for (uint256 i = 0; i < r.admittedList.length; i++) {
            address orch = r.admittedList[i];
            if (_frozenAtPostEnd(orch, q)) continue;
            FPV storage fpv = qt.fpv[q][orch];
            if (!fpv.posted) continue;
            usd = usd + fpv.usd; // FixedU18 addition — 18-decimal fixed point, matches IServiceRewardsActor
        }
    }

    /// @dev Quarter end epoch for quarter q (Epoch-typed; exposed per the IServiceRewardsActor interface the SWA consumes).
    function qEnd(uint64 q) external view returns (Epoch) {
        return _qEnd(q);
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

    function isStablecoinAdmitted(address token) external view returns (bool) {
        return _lists().stablecoins[token];
    }

    function getPricingParams() external view returns (uint256 minLot, uint256 priceBand) {
        SraStorage.SraStorageParams storage p = _params();
        return (p.minLot, p.priceBand);
    }

    function orchestratorCount() external view returns (uint64) {
        return _registry().admittedCount;
    }

    // ------------------------------------------------------------------------
    // Internal logic
    // ------------------------------------------------------------------------

    /// @dev SplitRule share computation: floor + largest-remainder method (design §2.5.3, T1: remainder descending, first residue entries +1).
    function _computeShares(address[] memory wallets, FixedU18[] memory usds, uint256 n, FixedU18 total)
        internal
        pure
        returns (Share[] memory shares)
    {
        shares = new Share[](n);
        uint256[] memory remainders = new uint256[](n);
        bool[] memory bumped = new bool[](n);
        uint256 residue = SHARE_TOTAL;
        // Remainders keep the integer-USD formulation (usd * 1e18 % total): the FixedU18 division
        // shareF = usds[i] * ONE / total computes div(mul(usd, 1e18), total), so its integer
        // remainder is usd * 1e18 % total — identical ordering to the previous uint256 path.
        uint256 totalUsd = FixedU18.unwrap(total);
        for (uint256 i = 0; i < n; i++) {
            // 18-decimal fixed-point: usd * SHARE_TOTAL / total, mathematically identical to the
            // integer-USD form (usd_f = usd, total_f = total are already 18-decimal). Type-safe
            // against integer/fixed-point magnitude mixing.
            FixedU18 shareF = usds[i] * ONE / total;
            shares[i] = Share({wallet: wallets[i], share: FixedU18.unwrap(shareF)});
            // remainder = (usd_f × 1e18) % total_f = (usd × 1e18 % total_int) × 1e18 — the integer-USD
            // remainder scaled by 1e18; the common ×1e18 factor preserves relative ordering, so the
            // largest-remainder assignment order is bit-identical to the integer formulation.
            remainders[i] = FixedU18.unwrap(usds[i]) * ONE_WAD % totalUsd;
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

    function _pairId(address payer, address operator) internal pure returns (bytes32 result) {
        // Scratch-memory assembly: both addresses fit in the 64-byte scratch space,
        // identical result to keccak256(abi.encode(payer, operator)) without the memory allocation.
        assembly {
            mstore(0, payer)
            mstore(32, operator)
            result := keccak256(0, 64)
        }
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
