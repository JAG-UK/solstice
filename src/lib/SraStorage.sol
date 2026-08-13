// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";
import {FPV} from "./SraTypes.sol";

// ----------------------------------------------------------------------------
// SRA ERC-7201 storage layout (4 namespaces) + precomputed slots.
// Extracted from ServiceRewardsActor.sol into a library (review: "Moving these storage
// declarations to a separate library file will simplify the #5 refactor") so the #5
// proxy refactor can share the exact same storage namespace definitions between the
// proxy and the implementation — a single source of truth for the storage layout.
// ----------------------------------------------------------------------------

library SraStorage {
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
    bytes32 internal constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
    bytes32 internal constant LISTS_SLOT = 0x6b063b99e710dc539d819b661c65b9a94a4c91adbbbff20449f292eda97f9300;
    bytes32 internal constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;
    bytes32 internal constant PARAMS_SLOT = 0xe21afbd697880784c3da970abdca3a316f22b4c4fc74f2fceb073d8e55bcad00;

    function registry() internal pure returns (SraStorageRegistry storage r) {
        assembly ("memory-safe") {
            r.slot := REGISTRY_SLOT
        }
    }

    function lists() internal pure returns (SraStorageLists storage l) {
        assembly ("memory-safe") {
            l.slot := LISTS_SLOT
        }
    }

    function quarter() internal pure returns (SraStorageQuarter storage q) {
        assembly ("memory-safe") {
            q.slot := QUARTER_SLOT
        }
    }

    function params() internal pure returns (SraStorageParams storage p) {
        assembly ("memory-safe") {
            p.slot := PARAMS_SLOT
        }
    }
}
