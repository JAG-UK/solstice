# SRA (Service Rewards Actor) design, tests, decisions, and security review

This document consolidates the design, test plan and registries, decision record, and security review for the Service Rewards Actor (SRA, issue #4) of FIP-0118 (Solstice). It previously lived in four separate files (`docs/design/001-sra-design.md`, `docs/design/002-sra-tests.md`, `docs/decisions/001-sra-decision-record.md`, `docs/spec/001-sra-security-review.md`); this single file keeps the same technical content organized as: §1 overview, §2 technical design, §3 decision record, §4 test strategy and coverage, §5 security review, §6 references.

## 1. Overview

### 1.1 Goal and Core Features

Implement the Service Rewards Actor (issue #4) of FIP-0118 (Solstice) as a **feature monolith**: maintain the orchestrator registry, allowlists, and quarterly volume state, compute service stream shares per the SplitRule and write them to f02 (`SetShares`), and export `AggregatedFPV(Q)` for the SWA. The SRA **never receives or holds value** (spec §3.1/§4).

Core features:

- Orchestrator registry: (payer, operator) pair → orchestrator binding, uniqueness invariant (spec §3.3)
- Stablecoin allowlist + Filecoin Pay contract allowlist (spec §3.3/§4.2)
- Quarterly volume FPV_i(Q) posting and verification-window binding (spec §3.2)
- Oracle-free FIL→USD pricing (fee-auction prints, spec §3.3)
- Quarterly share computation and f02.SetShares call (spec §4.2 + f02-design)
- Aggregated read AggregatedFPV(Q) for SWA gating (spec §3.2)
- Dual-Safe governance: registry/allowlist/parameter changes go through unanimous + SRA_CANCEL_HOLD (spec §5)

### 1.2 Document Scope and Status

- Scope: all key decisions for Issue #4, from design to PR.
- Decision groups used throughout: **D** design decisions (settled) | **S** structural decisions (approval) | **C** conflict rulings (found test-first) | **T** test decisions (defect fixes) | **G** coverage-gap closures | **I/R** implementation-layer risks and mitigations.
- Status: all landed — design approved and converged; implementation **295/295 tests Green** (146 SRA deterministic + 5 invariant + 144 existing); SRA line coverage 100%; `forge fmt --check` / `forge lint` clean; Slither static analysis zero real risk; Halmos symbolic verification `_computeShares` 6/6 PASS + quarter-window 4/4 PASS; final code review PASS; the A2 real defect (T10) fixed with 2 deterministic regression tests guarding it; spec-conformance deviations A/B/C/D/E reviewed by the user one by one and uniformly landed (T11); audit hardening V1/V2/V3 (overflow DoS) + B1/C1/E1/E2/F2 (remaining input-domain bounds) + QA-system fixes S1-S5 (adversarial matrix / security-claim map / evidence-condition annotation / threat matrix / reviewer checklist) landed.

### 1.3 Source Annotation System

Used throughout this document:

- 📄 **spec agreement**: directly from the FIP-0118 spec; the implementation must comply; no approval needed
- 📘 **code fact**: from merged/submitted code (governance libs, f02 lib, SWA); no approval needed
- ✏️ **design derivation**: the spec gives only the concept; the concrete form requires design; **needs approval**
- 🔍 **design decision**: spec-undefined blanks or settled trade-offs; **requires focused approval**

## 2. Technical Design

### 2.1 Tech Stack

| Item | Choice | Source |
|------|--------|--------|
| Language | Solidity ^0.8.36 | 📘 Project status (consistent with SWA) |
| Framework | Foundry (forge 1.7.1) | 📘 Project status |
| Governance | Reuse `UnanimousGovernance` (incl. `unanimousNoHold`) | 📘 Merged in PR #12/#17 |
| f02 interaction | Reuse `FVMRewards.setShares` library | 📘 Submitted in PR #16 |
| Storage | ERC-7201 namespaces (`@custom:storage-location`) | 📘 Precedent in PR #12 (Owners/PendingTask) + ✏️ reserved for future proxying |

### 2.2 Technology Choices and Key Decisions

**Deployment form (settled 🔍)**: the final state is an ERC-8167 proxy (decided in issue #5), but **this iteration implements only the feature monolith** (no proxy). Storage is designed with ERC-7201 namespaces from day one to reserve zero-migration for future proxying. Module organization follows the SWA: thin contract + logic delegated to libraries (f02 interaction reuses FVMRewards).

**D1 All-zero volume (settled 🔍)**: when the sum of all orchestrator FPVs in a quarter is 0, `SubmitShares` submits `[{f099, 1e18}]` and the quarter's service stream is burned. ⚠️ Design assumption: f099 (burn actor) can be resolved by f02 to an ID address and is a valid recipient — must be verified in mock tests during implementation.

**D2 Orchestrator cap (settled 🔍)**: the total number of admitted orchestrators in the registry (**including frozen**) is ≤ 64 (MAX_RECIPIENTS, 📘 PR #13 suggested value). `Admit` checks this and rejects when full; only `Remove` releases a slot; Freeze does not release a slot (frozen orchestrators keep their identity).

**D3 CorrectVolume (settled 🔍)**: follows the spec's no-hold exemption (📄 §4.2/§5.3 "the window itself is the hold") — uses the `unanimousNoHold` path with in-body window validation, allows bidirectional correction (up or down), no extra veto fallback (dual-Safe agreement is the protection).

**Governance hold parameter (✏️ needs approval)**: SRA governance operations enforce `SRA_CANCEL_HOLD` at the contract level (unlike the SWA, which relies on f02's SWA_TIMELOCK — 📘 that is why the SWA uses unanimousNoHold). Suggested SRA_CANCEL_HOLD = 7 days (consistent with the spec's suggested verification window length, 📄 §3.2).

### 2.3 Method Interfaces (15 writes + 1 read)

> Scope note: **15 writes = 12 core writes + 2 auxiliary writes + 1 audit-added governance write**. The 12 core writes are the methods in §2.3.1-2.3.4 other than the 2 auxiliaries below (registerPairs/postVolume/admit/remove/freeze/unfreeze/replace/reassignBinding/setAdmittedLists/setPricingParams/correctVolume/submitShares); the 2 auxiliary writes are `cancelPending` (governance veto auxiliary, exposes 📘 `_veto`) and `finalizeConversion` (permissionless mechanism trigger; submitShares can auto-trigger it); the audit-added write is `replaceOwner` (E1 owner rotation, aligned with upstream SWA — the spec's §4.2 method list does not name it, but the shared governance model needs an owner-rotation path). The earlier "14 writes" scope (12 core + 2 auxiliary) did not count `replaceOwner`.
> Semantics source 📄 §4.2 method list; **Solidity signatures are ✏️ design derivation (the spec gives only method names and prose) — ✅ S1 approved** (approval record in §3.2).

#### 2.3.1 Orchestrator operations (called by self, no governance)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `registerPairs` | `registerPairs(Pair[] calldata pairs)` — named struct `Pair {address payer; address operator;}` (C1: inline tuple-array params are illegal in Solidity) | An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another orchestrator (uniqueness, 📄 §3.3) |
| `postVolume` | `postVolume(uint64 Q, FPV calldata fpv)` | During posting; at most one posting per quarter of both components; prints exceeding PRICE_BAND are rejected at posting time (📄 §4.2) |

#### 2.3.2 Governance operations (dual Safe + SRA_CANCEL_HOLD, unanimous path)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `admit` | `admit(address orch)` | Admits an orchestrator; rejects when admitted total ≥ 64 (🔍 D2); re-admit = fresh identity (clears successor/frozen/freeze history, T10) |
| `remove` | `remove(address orch)` | Permanent removal; releases all bindings (pairs return to unclaimed) (📄 §4.2) |
| `freeze` | `freeze(address orch)` | Freeze: suspends, zeroes shares, excludes FPV (📄 §4.2) |
| `unfreeze` | `unfreeze(address orch)` | Exact restoration (📄 §4.2) |
| `replace` | `replace(address oldOrch, address newOrch)` | Operator address change (📄 §4.2) |
| `reassignBinding` | `reassignBinding(address payer, address operator, address orch)` | Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (📄 §4.2) |
| `setAdmittedLists` | `setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)` | Updates the stablecoin + Filecoin Pay allowlists (📄 §4.2) |
| `setPricingParams` | `setPricingParams(uint256 minLot, uint256 priceBand, uint256 maxPricePeriods)` | Updates the FIL pricing parameters MIN_LOT/PRICE_BAND/MAX_PRICE_PERIODS (📄 §3.3: all three are SRA state settable by governance) |
| `replaceOwner` | `replaceOwner(address prevOwner, address newOwner)` | **Owner rotation (audit E1, unanimousNoHold path)**: dual-Safe, effective immediately; newOwner must be a Safe proxy; revokes prevOwner and adds newOwner (aligned with upstream SWA) |
| `cancelPending` | `cancelPending(bytes32 taskId)` | Either Safe calls `_veto` alone to discard a queued change (📄 §4.2 + 📘 _veto) |

> `setPricingParams` is the governance power implied by spec §3.3/§5.2 ("FIL pricing parameters... can be set by SRA Governance"), not named in the spec's method list — **✏️ design derivation**.

#### 2.3.3 Governance operations (dual Safe + effective immediately within the window, unanimousNoHold path)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `correctVolume` | `correctVolume(address orch, uint64 Q, FPV calldata fpv)` | Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed value or backfills for an unposted orchestrator; exempt from SRA_CANCEL_HOLD, allows bidirectional correction (📄 §4.2/§5.3 + 🔍 D3a) |

> `value` uses the same full FPV structure as PostVolume (including the FIL period vector, because corrections may involve erroneous prints) — **✏️ design derivation** (the spec writes "value" without defining the structure).
>
> **PRICE_BAND exemption (✏️ made explicit)**: `correctVolume` is a governance correction — it **does not validate PRICE_BAND and does not update the lastBoundPrint reference** — dual-Safe agreement (unanimousNoHold) is the final authority; correction exists precisely to fix prints wrongly rejected by the band (📄 §3.3 optimistic acceptance + §4.2 correctable; 🔍 D3/D3a).

#### 2.3.4 Mechanism operations (permissionless)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `finalizeConversion` | `finalizeConversion(uint64 Q)` | Callable after the window closes; idempotent; completes the quarter's FIL→USD conversion in one pass (📄 §4.2) |
| `submitShares` | `submitShares(uint64 Q)` | Permissionless after binding; triggers conversion (if not yet run) → SplitRule → `FVMRewards.setShares(2, map)` (📄 §4.2 + 📘 library) |

#### 2.3.5 Read-only (for SWA and external audit)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `aggregatedFPV` | `aggregatedFPV(uint64 Q) returns (uint256 usd)` | Returns the post-binding USD aggregate (stablecoin face value + finalized FIL component); reading auto-triggers idempotent finalize (📄 §3.2/§4.2 + 🔍 R1 protection; deviation A aligned) |

> **Contract declaration (✏️ deviation A aligned, spec-conformance matrix)**: this method aligns with the spec's "reading AggregatedFPV(Q) triggers FinalizeConversion(Q) (if not yet run)"
> (§3.2/§4.1/§4.2) — after binding, a read before finalize auto-triggers the idempotent conversion (same path as `submitShares`), returns the complete USD value
> (including the FIL component), and produces the observable side effect `isFinalized=true`; before binding it still returns 0. Callers (SWA QuarterlyGateCheck) **do not need
> to pre-finalize**; a read yields the full value with no divergence from the internal total in `submitShares`. The contract behavior is locked by `test/SRAIntegration.t.sol` (§4.3.6, scenarios C1-C4).
> Rejected alternative: keeping a pure view that relies on the caller to finalize first (deviates from the spec's letter, and G3 showed the SWA has no gating implementation, so the contract dependency would be unmet). Note: the original design (C7) kept a pure view; deviation-A alignment (T11) revised it to the auto-trigger semantics above.

> Supplementary read-only views (✏️ design derivation, spec §4.2 says "read-only views expose the registry, bound volume, USD-denominated AggregatedFPV"): `isAdmitted(address)`, `isFrozen(address)`, `bindingOf(payer, operator)`, `fpvOf(Q, orch)`, `isFinalized(Q)`, `admittedCount()`, `getPricingParams()`, `orchestratorCount()` (+ C5: `isStablecoinAdmitted(address)` allowlist getter).

### 2.4 Data Structures (ERC-7201 namespace storage layout)

> Storage layout is ✏️ design derivation (the spec describes only conceptual state: "SRA holds the registry, FPV and verification-window state, two Safe addresses, the pending queue, allowlists, FIL pricing parameters", 📄 §4.2). Namespace division follows 📘 Owners/PendingTask's `Solstice.*` pattern, reserving zero-migration for future ERC-8167 proxying.

**Division basis (✅ S2 approved)**: split into 4 blocks by "data lifecycle × governance ownership" — ① Registry (long-lived identity, governance domain), ② AdmittedLists (isolated configuration, governance domain), ③ Quarter (rolling quarterly data, mechanism domain, the only high-frequency write), ④ Params (governance parameters, governance domain). Each block has an independent ERC-7201 slot (derived from `keccak256(namespace)`, never colliding); future delegate division maps directly onto these blocks with zero storage migration.

**Governance state (reused, not added)**:
- `Solstice.Owners`: two Safe addresses → bitmask (📘 Owners.sol)
- `Solstice.PendingTasks`: taskId → {modified, approvals} (📘 PendingTask.sol)

**① `Solstice.SRA.Registry` — orchestrator registry** (✏️)

```solidity
struct OrchestratorInfo {
    bool admitted;   // admitted
    bool frozen;     // current frozen state (checked immediately by registerPairs/postVolume)
    address successor; // replace alias chain; cleared on remove and on re-admit (T10)
    Epoch[] freezeEpochs;    // epoch of each freeze execution (✅ S5 finalized: freeze history array)
    Epoch[] unfreezeEpochs;  // epoch of each unfreeze execution
}
struct SRAStorageRegistry {
    mapping(address orch => OrchestratorInfo) orchestrators;
    mapping(bytes32 pairId => address orch) bindings;  // pairId = keccak256(abi.encode(payer, operator))
    uint64 admittedCount;   // includes frozen, used for the D2 cap check
}
```

**② `Solstice.SRA.AdmittedLists` — allowlists** (✏️)

```solidity
struct SRAStorageLists {
    mapping(address => bool) stablecoins;          // admitted stablecoins (valued at face USD)
    mapping(address => bool) filecoinPayContracts; // admitted Filecoin Pay contracts
}
```

**③ `Solstice.SRA.Quarter` — quarterly FPV** (✏️)

```solidity
struct PricePeriod {
    uint64 printEpoch;     // print settlement epoch
    uint256 lotUsd;        // lot face value (USD, integer)
    uint256 claimFil;      // claim FIL consumed (attoFIL)
    uint256 attoFil;       // FIL amount settled in this period
    // implied rate = lotUsd / claimFil (USD per FIL), integer arithmetic at FinalizeConversion
}
struct FPV {
    uint256 stableUSD;              // stablecoin component (face USD)
    PricePeriod[] filPeriods;       // FIL component, ≤ MAX_PRICE_PERIODS entries
    uint256 usdValue;               // USD final value after FinalizeConversion (0 if unconverted)
    bool posted;                    // posted flag (at most once per quarter)
}
struct SRAStorageQuarter {
    mapping(uint64 Q => mapping(address orch => FPV)) fpv;
    mapping(uint64 Q => bool) conversionFinalized;   // idempotency flag
    uint256 lastBoundPrintRate;    // PRICE_BAND anchor: last qualifying print of the previous quarter's binding final state (C6 + deviation D aligned)
}
```

> `PricePeriod` represents the rate as the rational `lotUsd / claimFil` (not floating point); at FinalizeConversion `usd += attoFil * lotUsd / claimFil` preserves integer precision — **✏️ design derivation**.
> C6 found a design gap — the PRICE_BAND reference "last bound qualifying print" needed a storage field; placed in the Quarter namespace (cross-quarter global field).

**④ `Solstice.SRA.Params` — governable parameters** (✏️)

```solidity
struct SRAStorageParams {
    uint256 minLot;          // MIN_LOT (proposed a few hundred USD, 📄 §11)
    uint256 priceBand;       // PRICE_BAND (thin auction guardrail, 📄 §3.3)
    uint256 maxPricePeriods; // MAX_PRICE_PERIODS (proposed 32, 📄 §11)
}
```

**Constants (compile-time)**: `EPOCHS_PER_QUARTER`, `POST_PERIOD`, `VERIFICATION_WINDOW`, `SRA_CANCEL_HOLD`, `MAX_ORCHESTRATORS = 64`, `ACTIVATION_EPOCH` — passed as deployment configuration to the constructor (✏️ see 2.6).

### 2.5 Core Logic

#### 2.5.1 Quarter State Machine (📄 §3.2 semantics + ✏️ determination implementation)

```
E(Q) = ACTIVATION_EPOCH + Q × EPOCHS_PER_QUARTER        // end epoch of quarter Q

posting:      E(Q) < now && now <= E(Q) + POST_PERIOD            // PostVolume callable
verification: E(Q) + POST_PERIOD < now
              && now <= E(Q) + POST_PERIOD + VERIFICATION_WINDOW // CorrectVolume callable
post-binding: now > E(Q) + POST_PERIOD + VERIFICATION_WINDOW     // SubmitShares/FinalizeConversion callable
```

- All comparisons use the `Epoch` (uint64) type; `currentEpoch()` reads `block.number` (📘 Epoch.sol)
- Boundary determination is an off-by-one hotspot; tests must cover E, E+POST, E+POST+VERIFY and ±1 (🔍 I5)
- **SubmitShares/FinalizeConversion/AggregatedFPV are callable only after the window closes and read only bound values** (📄 §3.2)

#### 2.5.2 Freeze and Share-Exclusion Semantics (📄 §4.2 + ✏️ snapshot implementation)

- A frozen orchestrator cannot `registerPairs`/`postVolume` (📄 §4.2)
- "For any quarter whose posting close was during a freeze": FPV is excluded, share is 0 (📄 §4.2)
- **Snapshot implementation (✏️ ✅ approved, freeze history arrays)**: `OrchestratorInfo` maintains `freezeEpochs`/`unfreezeEpochs` history arrays (one push per freeze/unfreeze execution; governance is low-frequency so the arrays are tiny). Determining whether "the E+POST instant of quarter Q is frozen": do a paired interval search; falling inside `[freezeEpochs[i], unfreezeEpochs[i])` → frozen, otherwise unfrozen. **Derivable at any point in time, independent of call ordering** — SubmitShares/AggregatedFPV results do not depend on when the keeper calls, strictly matching the spec's E+POST snapshot semantics.
- **After Remove**: pairs return to unclaimed and can be claimed by other orchestrators via `registerPairs` (📄 §4.2)
- **Re-admit = fresh identity (✏️ finalized after T10 defect fix)**: `admit` sets `admitted = true` and **resets identity** — clears `successor` (residual alias chain from replace), `frozen = false`, `delete freezeEpochs/unfreezeEpochs` (symmetric with `remove` cleanup). Rationale: if after `replace(old→new)` the old address is re-`admit`ted while a successor remains, the `submitShares` freeze check passes for old itself but the wallet resolves along the residual chain to the frozen new → a frozen orchestrator obtains a share through the resolve chain (violating S5/S7); residual frozen state would also carry over on re-admission. Rejected alternatives: B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5, which requires checking the reporting orchestrator itself; old's legitimate FPV would be dragged down by frozen new, and other functions like aggregatedFPV would be inconsistent), C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple")
- **After ReassignBinding**: volume is credited to the new orchestrator from the change epoch onward; already-posted quarters are unaffected (📄 §4.2)

#### 2.5.3 SplitRule Share Computation (with largest-remainder method)

```
submitShares(Q):
    1. if !conversionFinalized[Q]: run finalizeConversion logic (auto-trigger, 📄 §4.2)
    2. collect usdValue_i of non-excluded (admitted and non-frozen) orchestrators
    3. total = Σ usdValue_i
    4. if total == 0: shares = [{f099, 1e18}]      // 🔍 D1 all-zero burn
       else:
         for i: share_i = usdValue_i * SHARE_TOTAL / total      // floor
         residue = SHARE_TOTAL - Σ share_i                       // 0 <= residue < N
         // largest-remainder method: sort by remainder (usdValue_i * SHARE_TOTAL % total) descending,
         // the first residue entries get share_i += 1
         shares = [{wallet_i, share_i}]                          // wallet = orch address (✏️)
    5. drop entries with share_i == 0 (floor division can yield 0 for tiny usds; f02 rejects 0 shares — adapter surfaced by the main-branch mock validation)
    6. FVMRewards.setShares(SERVICE_STREAM_ID, shares)           // SERVICE_STREAM_ID = 2 (📘 f02-design)
```

- **Σ shares must be exactly == SHARE_TOTAL (1e18)**, otherwise f02 rejects (📘 f02-design / FVMRewards comment); the largest-remainder method guarantees this exactly (✏️ design derivation; the spec gives no algorithm)
- The 3-way split (333333333333333333 × 3 = 999999999999999999) must rely on remainder distribution to top up 1 — a key test (🔍 I1)
- `share` value domain is uint64 (f02 encoding constraint, 📘 FVMRewardTypes)
- Dropping zero-share entries: a floor of 0 arises when a tiny usdValue is far below the total; f02's recipient validation rejects share=0 and duplicate wallets, so the SRA filters them before SetShares (the main-branch mock's `_sharesValid` surfaced this; the sra-branch mock's looser validation had masked it)

#### 2.5.4 FIL Pricing (📄 §3.3 rules + ✏️ implementation details)

**At PostVolume posting**:
- `filPeriods.length ≤ MAX_PRICE_PERIODS`, reject if exceeded (✏️ design derivation: the spec says "at most MAX_PRICE_PERIODS entries"; the chain enforces the upper bound; merging over-limit periods is the off-chain indexer's job — compatible with the spec, not a deviation; C clarified)
- **PRICE_BAND validation (📄 §3.3 "reject if the deviation from the last bound qualifying print exceeds the band" + §4.2 "reject at posting")**: each print's implied rate (lotUsd/claimFil) is validated against the **anchor** (the last qualifying print of the previous quarter's **binding final state**, deviation D aligned); a deviation beyond the band is rejected. The anchor is updated at `finalizeConversion` (quarter binding time) and is fixed within the quarter — a print that is accepted does **not** immediately become the reference. Rationale: under the optimistic-acceptance model the SRA cannot verify print authenticity; if the reference updated on posting (chained reference), an attacker could step multiple prints within a single postVolume (each just inside the band) to push the reference arbitrarily far (×1.199³² ≈ 218×), taking effect immediately with no rollback on correction; with an anchor the push rate is band/quarter and the verification window offers a correction opportunity (spec §394 "gating may only under-count, never over-count" explicitly accepts the under-count degradation). Only boundary: when the system has never had a qualifying print (cold start / auction drought) there is no anchor to reject against — accepted.
- **MIN_LOT (deviation B aligned)**: prints below MIN_LOT **do not participate in pricing** — `postVolume` skips their band validation (stored, accepted), they never become the anchor reference, and `finalizeConversion` does not count their FIL amount (📄 §3.3 qualifying-print semantics "only lots with face value at least MIN_LOT participate in pricing"). The chain cannot verify whether a print corresponds to a real fee-auction event (an inherent boundary of the optimistic-acceptance model), but filtering on the reported lotUsd prevents dust lots from polluting the pricing anchor.

**FinalizeConversion(Q) (permissionless, idempotent)**:
- For each posted orchestrator's each filPeriod: `usd += attoFil * lotUsd / claimFil` (skipping prints below MIN_LOT)
- On completion, updates the anchor = the last qualifying (lotUsd ≥ MIN_LOT) print of the quarter; if the quarter has no qualifying print the anchor is unchanged (drought quarter does not update; "last bound" semantics)
- Stores `fpv[Q][orch].usdValue`, sets `conversionFinalized[Q] = true`
- All periods are priced as constructed (prints settle within Q, 📄 §3.2/§3.3); there is no unpriced case

#### 2.5.5 Governance Integration (📘 UnanimousGovernance mechanism + ✏️ method pairing)

| Governance method | Modifier | hold | Notes |
|-------------------|----------|------|-------|
| admit/remove/freeze/unfreeze/replace/reassignBinding/setAdmittedLists/setPricingParams | `unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)` | yes | two votes + permissionless completion after hold |
| correctVolume | `unanimousNoHold(keccak256(msg.data))` | no | the window is the hold (📄 §5.3); validates the verification window in the function body |
| replaceOwner (audit E1) | `unanimousNoHold(keccak256(msg.data))` | no | owner rotation, effective immediately (aligned with upstream SWA) |
| cancelPending | `_veto(taskId)` | — | either Safe cancels alone (📄 §4.2) |

- **taskId = keccak256(msg.data)** (📘): both Safes must submit byte-identical calldata; methods with array parameters like `setAdmittedLists` require a normalization convention (sorting, consistent encoding) — 🔍 I2 risk; tests must cover dual-Safe calls
- Completion after the hold elapses is permissionless (any keeper may trigger); the second approval call only accumulates a vote, it does not execute (📘 modifier semantics)

#### 2.5.6 f02 Interaction (📘 FVMRewards library)

- Reuse `FVMRewards.setShares(id, shares)` (revert semantics wrapped as `SetSharesFailed`)
- `SERVICE_STREAM_ID = 2` (📘 f02-design: migration fixes consensus=1, service=2)
- SetShares **binds immediately** (f02 folds old shares, 📘 f02-design): the quarterly cadence is the SRA's own normative discipline; f02 does not enforce it
- Share map size ≤ 64 (guaranteed by admitted ≤ 64, 🔍 D2)

### 2.6 Parameter Handling

| Parameter | Handling | Basis |
|-----------|----------|-------|
| `EPOCHS_PER_QUARTER` | Compile-time constant (constructor config) | 📄 §3.2 governance-repo parameter; ✏️ const-ified (avoid a governance attack surface, related to 🔍 R1) |
| `POST_PERIOD` (proposed 3 days) | Compile-time constant | 📄 §11; ✏️ const-ified |
| `VERIFICATION_WINDOW` (proposed 7 days) | Compile-time constant | 📄 §11; ✏️ const-ified |
| `SRA_CANCEL_HOLD` (suggested 7 days) | Compile-time constant | 📄 §4.2 governance-repo parameter; ✏️ const-ified |
| `MAX_ORCHESTRATORS` (64) | Compile-time constant | 📘 PR #13 MAX_RECIPIENTS; 🔍 D2 |
| `MIN_LOT` / `PRICE_BAND` / `MAX_PRICE_PERIODS` | **Governable** (SRA Governance, updated under SRA_CANCEL_HOLD) | 📄 §3.3/§5.2 explicitly: "all three are SRA state, settable by SRA Governance" |
| `ACTIVATION_EPOCH` | Constructor config | 📄 §3.2 quarter-window start |

## 3. Decision Record

### 3.1 Design Decisions (D1-D5, user-approved)

#### D1 All-Zero Volume Burn

- **Decision**: when the sum of all orchestrator FPVs in a quarter is 0, `SubmitShares` submits `[{f099, 1e18}]` and the quarter's service stream is burned.
- **Rationale**: when nobody posted or all are frozen/excluded there is no legitimate share recipient; f099 (burn actor) is an explicit ownerless target, while guaranteeing the Σ shares == 1e18 constraint holds and the service stream does not linger.
- **Impact**: depends on the assumption "f099 can be resolved by f02 to a valid recipient" — verified by mock tests (`test_SubmitShares_AllZero_BurnsToF099` / `AllFrozen_BurnsToF099` both assert the mock accepts f099). Alternatives (revert / skip) rejected.
- **FIP follow-up ([FIP-0118](https://github.com/filecoin-project/FIPs/pull/1270))**: the burn semantics are to be updated at the FIP level — the burn should happen immediately and be accounted in f02 state as burn, without requiring a `Claim([f099])`. f02 is expected to special-case f099 arriving via `SubmitShares` (covered by the mock tests above). The SRA implementation stays unchanged until the FIP text lands.

#### D2 Orchestrator Cap 64

- **Decision**: total admitted orchestrators (**including frozen**) ≤ 64 (MAX_RECIPIENTS). `admit` rejects when full; only `remove` releases a slot; `freeze` does not release a slot.
- **Rationale**: f02 `MAX_RECIPIENTS=64` (PR #13); frozen orchestrators keep their identity; freeze not releasing a slot avoids frequent share-map restructuring from freeze/unfreeze.
- **Impact**: share map size always ≤ 64; tests cover 64-full rejection, Remove release, Freeze non-release (G2 adds the 64-all-posted map-boundary case).

#### D3 / D3a CorrectVolume Bidirectional Correction

- **Decision**: `correctVolume` uses the `unanimousNoHold` path (no-hold exemption; the verification window itself is the hold), validates the window in the function body; allows **bidirectional correction** (up or down); no extra veto fallback (dual-Safe agreement is the protection). **Exempt from PRICE_BAND validation; does not update the lastBoundPrint reference**.
- **Rationale**: spec §4.2/§5.3 "the window itself is the hold"; correction exists precisely to fix prints wrongly rejected by the band; governance is the final authority (dual-Safe agreement).
- **Impact**: callable only within the verification window, not after it closes; tests cover up/down/multiple-corrections-last-wins/backfill/window boundaries (±1); the PRICE_BAND exemption is made explicit in §2.3.3 (reviewer suggestion landed).

#### D5 Deployment Form (this iteration: feature monolith only)

- **Decision**: this iteration implements only the feature monolith (no proxy); storage is designed with ERC-7201 namespaces, reserving zero-migration for future ERC-8167 proxying. Module organization follows the SWA: thin contract + logic delegated to libraries (f02 interaction reuses `FVMRewards`).
- **Rationale**: issue #5 already decided the ERC-8167 proxy final state; staged implementation; namespace-based storage from day one avoids future migration cost.
- **Impact**: storage split into 4 ERC-7201 namespaces (see S2); future delegate division maps directly onto these blocks.

### 3.2 Structural Decisions (S1-S12)

#### S1 Method Signatures (✅ approved)

- **Decision**: Solidity types for all 15 writes + 1 read (12 core writes + 2 auxiliary writes: cancelPending governance veto, finalizeConversion mechanism trigger; + 1 audit-added governance write: replaceOwner owner rotation, E1). Sub-decisions: A. `setPricingParams` as an independent method (not merged into setAdmittedLists; parameter domains separate); B. `correctVolume` takes the full FPV structure (whole replacement; no USD-value concept within the window, only raw components can be corrected); C. `Q` as uint64 (sufficient quantization headroom; `Q × EPOCHS_PER_QUARTER` uses a uint256 intermediate to guard overflow).
- **Rationale**: the spec gives only method names and prose; signatures are design derivations; parameter-domain separation lowers governance coupling; the full FPV structure supports correction scenarios.
- **Impact**: method set and ABI finalized; C1 later adjusts `registerPairs` to a named struct (Solidity compile limitation); C8 environment issue resolved via the forge upgrade.

#### S2 Data Structures (✅ approved)

- **Decision**: 4 ERC-7201 namespaces (`Registry`/`AdmittedLists`/`Quarter`/`Params`) and field layout, each block an independent slot (derived from `keccak256(namespace)`, never colliding).
- **Rationale**: divided by "data lifecycle × governance ownership" — Registry (long-lived identity, governance domain), AdmittedLists (isolated configuration, governance domain), Quarter (rolling quarterly data, mechanism domain, the only high-frequency write), Params (governance parameters, governance domain); future delegate division maps directly, zero storage migration.
- **Impact**: storage layout finalized; C6 found a design gap — the PRICE_BAND reference needed a storage field (later placed in the Quarter namespace).

#### S3 Largest-Remainder Method (standard practice)

- **Decision**: share rounding residue is distributed by remainder (`usdValue_i * SHARE_TOTAL % total`) descending; the first `residue` entries get `share_i += 1`, guaranteeing `Σ shares == 1e18` exactly.
- **Rationale**: f02 rejects Σ≠1e18 (📘 f02-design); residue < n ≤ 64 keeps the top-up loop bounded.
- **Impact**: 3/7/17-way split tests (I1) + random fuzzing (G7) verify the exact sum.

#### S4 Window Determination (standard practice)

- **Decision**: boundary expressions — posting `E < now ≤ E+POST`, verification `E+POST < now ≤ E+POST+VERIFY`, post-binding `now > E+POST+VERIFY`; all comparisons use the `Epoch` (uint64) type.
- **Rationale**: off-by-one hotspot; unified Epoch type + explicit boundary expressions.
- **Impact**: I5 boundary ±1 tests cover (E, E+POST, E+POST+VERIFY and ±1).

#### S5 Freeze Snapshot (✅ approved)

- **Decision**: `OrchestratorInfo` maintains `freezeEpochs`/`unfreezeEpochs` history arrays (one push per freeze/unfreeze execution); determining "whether the E+POST instant of quarter Q is frozen" does a paired-interval search; falling inside `[freeze[i], unfreeze[i])` → frozen.
- **Rationale**: strictly matches the spec's E+POST snapshot semantics; derivable at any point, independent of call ordering — SubmitShares/AggregatedFPV results do not depend on keeper call timing.
- **Impact**: E+POST snapshot positive/negative tests (`FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` and `UnfrozenAtPostEnd_FrozenInWindow_StillIncluded`); previously discussed alternatives (current-state determination / bitmap snapshot / single field) rejected.

#### S6 Parameter Const-ification (standard practice)

- **Decision**: `EPOCHS_PER_QUARTER`/`POST_PERIOD`/`VERIFICATION_WINDOW`/`SRA_CANCEL_HOLD`/`MAX_ORCHESTRATORS=64` are compile-time constants (constructor config); only `MIN_LOT`/`PRICE_BAND`/`MAX_PRICE_PERIODS` are governable.
- **Rationale**: reduces the governance attack surface (R1-related); the three pricing parameters are explicitly settable by governance per spec §3.3/§5.2.
- **Impact**: 10-parameter constructor signature (C2 aligned); setPricingParams governance method (G1 tests added).

#### S7 Recipient Wallet (✅ approved)

- **Decision**: the orch address is the wallet in the share map.
- **Rationale**: keep admit simple; wallet change goes through `replace`.
- **Impact**: no independent recipient-wallet field; replace takes on wallet-change duty (G6 adds failure-path tests).

#### S8 PRICE_BAND Reference (revised by deviation-D alignment — anchored reference)

- **Decision (final, deviation D aligned)**: reference the "last bound qualifying print" — the qualifying print of the previous quarter's **binding final state** (📄 §3.3's "bound" is the terminal state of posting→verification→binding). The anchor is updated at finalizeConversion (quarter binding time) and fixed within the quarter; "posting-time update" (chained reference) is rejected: under the optimistic-acceptance model print authenticity cannot be verified, chained stepping can push the reference arbitrarily far in a single transaction (×1.199³²≈218×); with an anchor the push rate is band/quarter and the verification window can correct (§394 prioritizes manipulation resistance). Only boundary: accepted when the system has never had a qualifying print (natural extension of spec semantics).
- **History**: the original S8 (spec-agreement reading) kept a "global continuous, posting-time reference"; that solution was revoked by deviation-D alignment (T11). The intermediate C6 ruling added the reference storage field (Quarter namespace).

#### S9 Rate Representation (standard practice)

- **Decision**: `PricePeriod` stores the `lotUsd/claimFil` rational (no floating-point rate); FinalizeConversion does integer multiply/divide `usd += attoFil * lotUsd / claimFil`.
- **Rationale**: avoids floating-point precision loss.
- **Impact**: integer precision test (1000/3 non-divisible scenario).

#### S10 Period Cap (standard practice)

- **Decision**: `filPeriods.length ≤ MAX_PRICE_PERIODS` enforced on-chain; over-limit merging is the off-chain indexer's job.
- **Rationale**: the spec says "at most MAX_PRICE_PERIODS entries"; the chain enforces the upper bound; on-chain merging is complex (not done).
- **Impact**: exactly-32 accepted / 33 rejected tests (G4); correctVolume over-limit rejection (CV2).

#### S11 correctVolume Signature (standard practice)

- **Decision**: `correctVolume`'s `value` uses the full FPV structure (incl. the FIL period vector).
- **Rationale**: corrections may involve erroneous prints and need the complete raw components.
- **Impact**: C3 FPV calldata full 4-field structure (usdValue=0, posted=false on posting; SRA sets posted internally).

#### S12 Read-Only Views (standard practice)

- **Decision**: `aggregatedFPV` (primary read) + supplementary views: `isAdmitted`/`isFrozen`/`bindingOf`/`fpvOf`/`isFinalized`/`admittedCount`/`getPricingParams`/`orchestratorCount` (+ C5 supplementary allowlist getter).
- **Rationale**: spec §4.2 "read-only views expose the registry, bound volume, USD-denominated AggregatedFPV".
- **Impact**: orchestratorCount view test (CV7); C5 adds `isStablecoinAdmitted`.

### 3.3 Conflict Rulings (C1-C8, found by the tester between the design and language/code facts)

> These are inconsistencies the tester found between the design and Solidity language/code facts. All of the following are implemented per this list; where the original design text said otherwise, the implementation follows the ruling.

| # | Ruling | Disposition |
|---|--------|-------------|
| **C1** | the design's `registerPairs((address, address)[] calldata)` inline tuple-array parameter **cannot compile** in Solidity 0.8.36 ("Expected type name", verified empirically) | use a named struct `Pair {address payer; address operator;}` (top-level definition, field names/ABI consistent with the design) |
| **C2** | the design gives no constructor signature | set 10 params `(owner1, owner2, epochsPerQuarter, postPeriod, verificationWindow, cancelHold, activationEpoch, minLot, priceBand, maxPricePeriods)` (test design derivation ✏️) |
| **C3** | the design does not define the FPV calldata structure | use the full 4 fields (stableUSD/filPeriods/usdValue/posted); usdValue=0, posted=false on posting (SRA sets posted internally) |
| **C4** | the design does not define the band's numeric representation | set **basis points** (2000 = allows ±20% deviation, test assumption H-band) |
| **C5** | the design's supplementary views do not list an allowlist getter, but the tests need to verify `setAdmittedLists` takes effect | add `isStablecoinAdmitted(address) view returns (bool)` (reasonable extension of spec §4.2 "read-only views expose the registry…") |
| **C6** | ⚠️ the design requires validating "against the last bound qualifying print" (global continuous, cross-quarter) but the data structures have no reference storage field | the SRA internally stores the latest qualifying print's rate (cross-quarter reference, placed in the **Quarter namespace**); later revised to the anchored reference by deviation-D alignment (T11) |
| **C7** | aggregatedFPV defined as a view (cannot trigger conversion); test asserts post-binding aggregation of already-finalized data | **later revised by deviation-A alignment (T11)**: `aggregatedFPV` is non-view and reading auto-triggers the idempotent finalize (see §2.3.5); the original "keep pure view" ruling is superseded |
| **C8** | local forge 1.3.5 incompatible with the project foundry.toml lint section (`code-size` etc. enums), and `--config-path` relative paths resolve from the config's directory | temporary config to compile; **resolved by the forge 1.7.1 upgrade** (P0), the project config is usable directly |

### 3.4 Test Decisions (T1-T11)

> T1 not listed separately (G1-G7 is the systematic coverage closure, see §3.5); T2-T6 are test-side or implementation-side defects found during implementation/review and their dispositions;
> T7-T9 are correctness-assurance additions (A1/A2/A3/E1, see §4.3.4); T10 is the A2 real-defect fix (caught during t7/t8 acceptance);
> T11 is the unified implementation of the spec-conformance deviations (user-reviewed one by one, principle: spec alignment first).

| # | Defect | Disposition |
|---|--------|-------------|
| **T2** | missing prank on re-submission after veto (test-side defect) | fixed the test (aligned with the governance library's real semantics) |
| **T3** | postVolume posting timing out of window (test-side defect) | fixed the test |
| **T4** | cap expectRevert misplaced on the second vote (test-side defect) | fixed the test |
| **T5** | makeAddr salt depending on block.number causing address collisions (test-side defect) | fixed the test |
| **T6** | ⚠️ **implementation defect (found in the final review, TDD fix)**: `registerPairs`'s AlreadyBound check uses `_isAdmitted(current)` instead of `_resolve(current)` — after replace the binding still points to the old address (admitted=false), the check is bypassed, and a third party can grab the binding pair | tester first wrote `test_RegisterPairs_AfterReplace_ThirdPartyReverts` (Red) → coder's 1-line fix `_isAdmitted(_resolve(current))` (Green); the invariant `invariant_OneBindingPerPair` is designed to catch this class of bugs |
| **T7** | SetShares system-call failure path never tested (mock has no failure injection) | t6 adds `test_SubmitShares_SetSharesFailed_Reverts` (mock `failSetShares` injection → revert SetSharesFailed + control success path) |
| **T8** | freeze-snapshot semantics lack persistent invariant verification | t6 adds `invariant_FrozenAtPostEnd_ExcludedFromShares` (handler freeze-interval tracking; frozen-at-POST shares always 0) |
| **T9** | D1 all-zero burn lacks invariant verification | t6 adds `invariant_ZeroTotal_BurnsToBurnAddress` (total==0 → single BURN record); t6 also lands E1 gas baseline (`.gas-snapshot`) |
| **T10** | ⚠️ **implementation defect (caught at t7/t8 acceptance, TDD fix)**: `replace(old→new)` sets `old.successor = new` → re-`admit(old)` leaves **successor residual** → `submitShares` freeze check `_frozenAtPostEnd(old)` (against old itself, not frozen, passes) but the wallet writes `_resolve(old) = new` (frozen at POST) → **a frozen orchestrator obtains a share through the resolve chain** (violating S5/S7); second face: `replace` keeps `old.frozen`/freeze history, re-admit carries frozen state in | **Option A (admit identity reset, symmetric with remove cleanup)**: `admit` appends clearing `successor = 0`, `frozen = false`, `delete freezeEpochs/unfreezeEpochs`. Coder first wrote 2 regression tests (R1: share map excludes the frozen successor; R2: re-admit clears frozen for normal operation; Red before the fix) → fixed the implementation (Green) + synced the invariant handler's admit/completeParked state cleanup. Rejected options B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5's requirement to check the reporting orchestrator itself; old's legitimate FPV dragged down by frozen new; other functions like aggregatedFPV inconsistent), C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple") |
| **T11** | **spec-conformance deviation unified implementation (user-reviewed one by one, principle: spec alignment first)**: the spec-conformance matrix's 5 deviations — **A** (aggregatedFPV trigger semantics): the spec's three literal statements "reading triggers FinalizeConversion" vs the implementation's pure view; changed to **read auto-triggers idempotent finalize** (rejected keeping a view that relies on the caller finalizing first — the SWA has no gating implementation, the contract dependency would be unmet); **B** (MIN_LOT): the implementation never participated in the pricing path (neither band reference nor conversion filtered); changed to **sub-MIN_LOT prints do not participate in pricing** (band check skipped, never become the reference, not counted in finalize, aligned with §3.3 qualifying-print semantics); **C** (MAX_PRICE_PERIODS): clarified as **not a deviation** (on-chain rejection of over-limit is the enforcement of the spec's "at most MAX_PRICE_PERIODS entries" format; adjacent-period merging is the off-chain indexer's job); **D** (PRICE_BAND reference): changed to **anchored reference** — reference = the qualifying print of the previous quarter's binding final state, updated at finalize; rejected "posting-time update" (chained reference: under the optimistic-acceptance model print authenticity cannot be verified; n chained steps within a single postVolume can push the reference ×(1+band)^n (n=32 ≈ 218×), taking effect immediately with no correction rollback; with an anchor the push rate is band/quarter with a verification-window correction opportunity, §394 "gating may only under-count, never over-count"); **E** (Replace identity transfer): status quo kept (necessary completion, no literal spec conflict) | **A/B/D source+test alignment (TDD)**: 6 new SRAQuarter tests (anchor prevents single-batch drift / cross-quarter anchor update / correctVolume does not update anchor / three sub-MIN_LOT filters) + SRAIntegration C3 rewrite (read auto-triggers → complete value + isFinalized) + differential model anchor-semantics sync (model 3 reference chain → anchor, model 2 + min_lot filter; 175 cases still all match) + base-class MIN_LOT dimension fix (1e18 → 100 USD, aligned with the spec's proposed "a few hundred USD"). C/E documentation clarification (§2.5.4) |

### 3.5 Coverage Gap Closure (G1-G7, 58 → 74 tests)

> Coverage gaps found by the scheduler's systematic assessment; the tester closed them with 16 tests.

| # | Gap | Added verification points |
|---|-----|---------------------------|
| **G1** | `setPricingParams`/`getPricingParams` untested | parameter update takes effect / gating / invalid-param rejection / new band applies to subsequent prints (4 tests) |
| **G2** | 64-full + submitShares combination untested | all 64 post → map has exactly 64 recipients (mock MAX_RECIPIENTS boundary), 64-way even split Σ exact |
| **G3** | band exact ±20% boundary untested | `_checkPriceBand` uses `>=`/`<=` boundary-inclusive: exactly-band accepted, 1bps over rejected (4 tests) |
| **G4** | MAX_PRICE_PERIODS exactly 32 untested | exactly 32 PricePeriods accepted (`<=`); 33 rejected already covered |
| **G5** | multi-quarter share isolation untested | quarter-1 posting does not leave residue affecting quarter 0 (multi-quarter map isolation) |
| **G6** | governance failure-path asymmetry | replace target already admitted / reassignBinding target not admitted / remove non-orchestrator / frozen orchestrator can be removed (errors thrown at the third permissionless execution) |
| **G7** | no fuzzing | 3 random usdValues → Σ shares always exactly == 1e18 (largest-remainder core invariant, 256 runs) |

> Supplement: P1 adds 3 persistent invariants (invariant_SumShares_IsShareTotal / invariant_OneBindingPerPair / invariant_GovernanceTasks_Consistent; handler encapsulates 14 random operations); P2 adds 14 more deterministic tests (CV1-CV7; line coverage 100%, branch 67.16% at the tool's statistical ceiling), see §4.3.2/§4.3.3.

### 3.6 Implementation-Layer Risks and Mitigations (I/R)

| # | Risk | Mitigation (landed) |
|---|------|---------------------|
| **I1** | share rounding Σ≠1e18 | largest-remainder method (S3) + 3/7/17-way split tests + G7 fuzz |
| **I2** | taskId deadlock (byte-level calldata differences) | normalization convention for array parameters + dual-Safe call tests (`TaskId_DifferentArrayOrder_DoesNotMerge` / `SameArrayOrder_Executes`) |
| **I5** | window off-by-one | Epoch type + boundary ±1 tests (I5) |
| **R1** | captured SRA inflated postings → gating step | AggregatedFPV reads only bound values (never reads unbound posted values); submitted values recomputable |

### 3.7 Approval Status Summary

| Group | Decision | Status |
|-------|----------|--------|
| D | D1 / D2 / D3(D3a) / D5 | ✅ settled (user-approved) |
| S | S1 / S2 / S5 / S7 | ✅ approved |
| S | S8 | ✅ aligned per deviation D (anchored reference, see T11; the original "spec agreement" old solution revoked) |
| S | S3 / S4 / S6 / S9 / S10 / S11 / S12 | ⏳ not individually reviewed (standard practice, verified by the implementation) |
| C | C1-C8 | ✅ ruled and landed (C8 closed with the forge 1.7.1 upgrade; C7 superseded by deviation-A alignment) |
| T | T2-T11 | ✅ disposed (T6/T10 implementation defects, TDD fix; T7-T9 correctness assurance landed; T11 spec-conformance alignment A/B/D + C/E clarification; post-review audit hardening V1/V2/V3 + B1/C1/E1/E2/F2 landed as T12) |
| G | G1-G7 | ✅ closed (58 → 74 → 77 → 91 → 94 → 96 → 100 → 103 → 109 → 123 → 151 tests) |
| I/R | I1 / I2 / I5 / R1 | ✅ mitigations landed (tests + implementation semantics double assurance) |

**Final acceptance**: the implementation aligns with all design rulings, and the spec-conformance deviations A/B/C/D/E were reviewed by the user one by one and uniformly landed (T11); **295/295 tests Green** (146 SRA deterministic + 5 invariant + 144 existing); SRA line coverage 100%, branch 67.16% (tool statistical ceiling; governance function-body require branches under-counted by the lcov modifier quirk); `forge fmt --check` / `forge lint` clean; Slither static analysis zero real risk; Halmos symbolic verification `_computeShares` 6/6 PASS; final code review PASS; the A2 real defect (T10) fixed with 2 deterministic regression tests guarding it; aggregatedFPV read auto-triggers finalize, PRICE_BAND anchored reference, and MIN_LOT filtering all locked by targeted tests; audit hardening V1/V2/V3 (overflow DoS, input-domain bounds) and B1/C1/E1/E2/F2 (remaining bounds + owner rotation) landed with 6 + 8 regression tests; QA-system fixes S1-S5 landed (adversarial input matrix 28 tests / security-claim-to-code map / evidence-condition annotation / threat model matrix / reviewer checklist).

## 4. Test Strategy and Coverage

### 4.1 Test File Inventory

| File | Responsibility | Test functions | Strategy points covered |
|------|----------------|----------------|------------------------|
| `test/SRATestBase.sol` | Common base: deploy SRA, build Safe owners, register service stream 2, quarterly time utilities, governance helpers | — (not a test) | — |
| `test/SRAGovernance.t.sol` | Governance flow | 16 | 6 |
| `test/SRARegistry.t.sol` | Orchestrator registry + freeze + cap | 28 | 3, 5 |
| `test/SRAQuarter.t.sol` | Quarter state machine + FPV + FIL pricing (incl. A/B/D deviation-alignment tests) | 44 | 2, 7, 8, 9, 11 |
| `test/SRAShares.t.sol` | Share computation + burn + freeze snapshot + SetShares | 17 | 1, 3, 4, 10, 12 |
| `test/SRAIntegration.t.sol` | **Integration contract tests** (simulate the SWA gating consumer of aggregatedFPV; deviation A disposition) | 4 | 11 |
| `test/SRAOverflowDoS.t.sol` | **Overflow DoS regression tests** (audit findings V1/V2/V3 — anchor pollution / finalizeConversion overflow / _computeShares overflow; input-domain hardening) | 6 | 2, 8, 9 (overflow-DoS hardening) |
| `test/SRAAdversarial.t.sol` | **Adversarial input matrix** (S1, QA system fix): boundary probes of the external write surface — q-window boundaries (future quarter / uint64.max), FPV exact-limit accept / limit+1 reject, zero-address probes, setPricingParams full parameter grid, empty-array semantics, multi-orchestrator aggregate bound | 28 | 2, 8, 9 (adversarial layer: every external write function's numeric/address/array parameters at their boundaries) |
| `test/SRAInvariant.t.sol` | **Invariant tests** (P1/A2/A3): handler random operations + 5 persistent invariants | 5 | I1 share conservation / I2 binding uniqueness / I3 governance consistency / A2 freeze-snapshot exclusion / A3 all-zero burn |
| `test/differential/DifferentialShares.t.sol` | **Differential tests** (t1): Python independent reference model cross-validates three computation cores (largest-remainder / FPV aggregation / PRICE_BAND), breaking same-source bias | 3 | 1, 9, 8 (independent reference model) |
| `test/halmos/QuarterWindowCheck.t.sol` | **State-machine symbolic verification** (blind spot 4 closed): Halmos formally proves parameter-independent quarter-window properties (T2a quarter boundary / T3 constant interval / T4 snapshot-time independence / T5b empty-history boundary); harness in `test/halmos/QuarterWindowHarness.sol` | 4 (halmos, not in the forge suite) | 2, 3, 4 (symbolic verification layer) |

**151 forge test functions in total** (146 deterministic + 5 invariant; of the 146 deterministic, 109 are in the 5 SRA suites above, 6 are overflow-DoS regressions in `test/SRAOverflowDoS.t.sol`, 28 are adversarial probes in `test/SRAAdversarial.t.sol`, and 3 are differential), plus 4 Halmos symbolic-verification checks (not in the forge suite); covers all 12 test strategies in §4.2 + 3 new persistent invariants from P1 + A2/A3 correctness invariants + A2 defect regression + integration contract tests + differential cross-validation + state-machine symbolic verification + A/B/D deviation alignment + overflow-DoS hardening (V1/V2/V3) + audit bound enforcement (B1/C1/E1/E2/F2) + adversarial input matrix (S1). Full suite: 151 SRA + 144 existing = **295 tests**.

### 4.2 Strategy Point Coverage Matrix

| # | Strategy point (design §3) | Test functions | Source |
|---|----------------------------|----------------|--------|
| 1 | Share rounding (largest remainder) | `SRAShares.test_SubmitShares_ThreeWayEqual_ExactSum` (3-way)<br>`..._SevenWayEqual_ExactSum` (7-way)<br>`..._SeventeenWayEqual_ExactSum` (17-way, remainder 15)<br>`..._UnevenSplit_Proportional` (30/70) | 🔍 I1 / ✏️ S3 |
| 2 | Window boundaries (E/E+POST/E+POST+VERIFY ±1) | `SRAQuarter.test_PostVolume_PostingWindow_Success` (E+1)<br>`..._AtQuarterEnd_Reverts` (E strictly less)<br>`..._AtPostEnd_Inclusive` (E+POST inclusive)<br>`..._AfterPostingWindow_Reverts` (E+POST+1)<br>`..._SecondPosting_Reverts` (posted flag)<br>`SRAQuarter.test_CorrectVolume_AtVerifyEnd_Inclusive`<br>`..._AfterVerificationWindow_Reverts` | 🔍 I5 / ✏️ S4 |
| 3 | Freeze semantics | `SRARegistry.test_Freeze_PreventsPostVolume`<br>`..._Unfreeze_RestoresOperations`<br>`..._RegisterPairs_Frozen_Reverts`<br>`..._Remove_ReleasesPairs_CanBeReclaimed`<br>`..._RegisterPairs_AfterReplace_ThirdPartyReverts` (**T6**: third-party pair grab after replace must revert)<br>`SRAShares.test_SubmitShares_FrozenExcluded_ExactSum`<br>`..._FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` (E+POST snapshot)<br>`..._UnfrozenAtPostEnd_FrozenInWindow_StillIncluded` (snapshot counterexample)<br>`SRARegistry.test_Replace_TransfersIdentity`<br>`..._ReassignBinding_ChangesBinding` | 📄 §4.2 + ✅ S5 |
| 4 | All-zero burn (D1) | `SRAShares.test_SubmitShares_AllZero_BurnsToF099` (nobody posted)<br>`..._AllFrozen_BurnsToF099` (all frozen/excluded)<br>**Both assert the mock accepts f099 as a recipient (D1 assumption verification)** | 🔍 D1 |
| 5 | Cap rejection (D2) | `SRARegistry.test_Admit_AtCapacity_Reverts` (64 full rejects)<br>`..._Admit_RemoveFreesSlot` (Remove frees)<br>`..._Admit_FrozenStillCountsTowardLimit` (freeze does not free) | 🔍 D2 |
| 6 | Governance flow | `SRAGovernance.test_Admit_TwoApprovalsPlusHold_Executes`<br>`..._HoldNotElapsed_ExecutionReverts` (HoldUntil)<br>`..._SingleApproval_NotExecuted`<br>`..._NonOwner_Reverts`<br>`..._TaskIdIsKeccakOfCalldata`<br>`..._Veto_CancelsPendingAdmit`<br>`..._Veto_NonOwner_Reverts`<br>`..._CorrectVolume_NoHold_SecondApprovalExecutesImmediately`<br>`..._SameOwnerTwice_Reverts`<br>`..._TaskId_DifferentArrayOrder_DoesNotMerge` (I2 deadlock)<br>`..._TaskId_SameArrayOrder_Executes` (control) | 📘 UnanimousGovernance + 🔍 I2 |
| 7 | CorrectVolume | `SRAQuarter.test_CorrectVolume_VerificationWindow_Upward` (up)<br>`..._Downward_Corrects` (down, D3a bidirectional)<br>`..._MultipleCorrections_LastWins` (whole replacement)<br>`..._BackfillUnposted` (backfill)<br>`..._AtVerifyEnd_Inclusive` / `..._AfterVerificationWindow_Reverts` | 📄 §4.2 + 🔍 D3a |
| 8 | PRICE_BAND | `SRAQuarter.test_PostVolume_PriceBand_ColdStartAccepts` (cold start)<br>`..._PriceBandExceeded_Reverts` (cross-quarter over-band)<br>`..._PriceBand_WithinBand_Accepts` (within band)<br>`..._AnchorPreventsSameBatchDrift` (anchor prevents single-batch chained drift)<br>`..._AnchorUpdatesOnFinalize` (cross-quarter anchor update)<br>`..._CorrectVolumeDoesNotUpdateAnchor` (correction does not update the anchor)<br>`SRAQuarter.test_MinLot_SubMinLotPrint_ExcludedFromPricing` (sub-MIN_LOT prints do not participate in pricing)<br>`..._NotCountedInConversion` (sub-MIN_LOT not counted in conversion)<br>`..._EqualToMinLot_Qualifies` (==MIN_LOT qualifies) | 📄 §3.3 (anchor reference: qualifying print of the previous quarter's binding final state; ✅ S8 aligned per deviation D) |
| 9 | FinalizeConversion | `SRAQuarter.test_FinalizeConversion_AfterBinding_Success`<br>`..._Idempotent` (idempotent)<br>`..._IntegerPrecision` (1000/3 not divisible)<br>`..._BeforeBinding_Reverts` | 📄 §4.2 + ✏️ S9 |
| 10 | SetShares encoding | `SRAShares.test_SubmitShares_MapSize_EqualsActiveOrchestrators` (map ≤ 64)<br>`..._AutoFinalize_IncludesFilValue` (Σ=1e18 + auto conversion)<br>All share tests assert Σ==1e18 and wallet resolution via mock `getShares(2)` | 📘 FVMRewards/mock |
| 11 | AggregatedFPV | `SRAQuarter.test_AggregatedFPV_BeforeBinding_Zero` (read-only bound value)<br>`..._AfterBinding_SumOfValues` (post-binding aggregation)<br>`..._FrozenExcluded` (frozen excluded) | 📄 §3.2 + 🔍 R1 |
| 12 | f02 mock driving | All tests inherit `MockRewardTest` (etch mock f02 + CALL_ACTOR_BY_ID); stream 2 registration follows the mock's RegisterStream queue semantics; Safe owner construction follows the SWA tests' `_makeSafeOwner` technique | 📘 PR #17 |

### 4.3 Assurance Registries

#### 4.3.1 G1-G7 Gap Closure Registry (58 → 74 tests)

> Coverage gaps found by the scheduler's systematic assessment of the test suite, closed by the tester. 16 new tests, all following existing naming conventions and reusing base-class helpers. Decision-level summary in §3.5.

| # | Gap | Added tests (file:line) | Verification point |
|---|-----|-------------------------|--------------------|
| **G1** | `setPricingParams`/`getPricingParams` untested | `SRAQuarter:475` `test_SetPricingParams_UpdatesParams_GetReturns`<br>`SRAQuarter:490` `..._NonOwner_Reverts`<br>`SRAQuarter:498` `..._InvalidParams_Reverts` (maxPricePeriods=0 / band>10000)<br>`SRAQuarter:532` `..._NewBand_AppliesToNewPrints` (+20% rejected after band change) | parameter management: update takes effect / gating / invalid params / new band applies to subsequent prints |
| **G2** | 64-full + submitShares combination untested | `SRAShares:304` `test_SubmitShares_AtFullCapacity_SixtyFourRecipients` | all 64 post → map has exactly 64 recipients (mock MAX_RECIPIENTS boundary), 64-way even split with 1e18/64 each, Σ exact |
| **G3** | band exact ±20% boundary untested | `SRAQuarter:245` `..._ExactlyPlusBand_Accepts` (+2000bps boundary inclusive)<br>`SRAQuarter:265` `..._ExactlyMinusBand_Accepts` (-2000bps boundary inclusive)<br>`SRAQuarter:285` `..._JustOverBand_Reverts` (+2001bps rejected)<br>`SRAQuarter:306` `..._JustUnderBand_Reverts` (-2001bps rejected) | `_checkPriceBand` uses `>=`/`<=` boundary-inclusive: exactly-band accepted, 1bps over rejected |
| **G4** | MAX_PRICE_PERIODS exactly 32 untested | `SRAQuarter:332` `test_PostVolume_MaxPricePeriods_ExactlyAccepted` | exactly 32 PricePeriods accepted (`<=`); 33 rejected already covered |
| **G5** | multi-quarter share isolation untested | `SRAShares:326` `test_SubmitShares_MultiQuarter_Isolated` | quarter 0 posts A/B → quarter 1 only C posts → quarter 1 map contains only C (no residue), quarter 0 result unaffected |
| **G6** | failure-path asymmetry | `SRARegistry:326` `test_Replace_AlreadyAdmittedTarget_Reverts` (replace target already admitted)<br>`SRARegistry:342` `test_ReassignBinding_NotAdmittedTarget_Reverts` (target not admitted)<br>`SRARegistry:361` `test_Remove_NotAdmitted_Reverts` (non-orchestrator)<br>`SRARegistry:373` `test_Remove_FrozenOrch_Succeeds` (frozen orchestrator can be removed; implementation does not block) | governance failure branches: errors thrown at the third permissionless execution of the function body |
| **G7** | no fuzzing | `SRAShares:369` `test_SubmitShares_Fuzz_SumAlwaysExact(uint256,uint256,uint256)` | 3 random usdValues (bounded < 1e30, aligned with the code-enforced MAX_STABLE_USD — S3: sampling domain = enforced input domain, not a test-side shrink) → Σ shares always exactly == 1e18 (largest-remainder core invariant, 256 runs) |

**Implementation issue found**: while writing the G1 tests it was found that the reference updates with each qualifying print (C6 semantics: the last one becomes the new reference) — the "new band applies" test was accordingly changed to directly verify that a value accepted under the old band is rejected after the band change (+20% over-band at band 10%, boundary at band 20%), avoiding reference-update interference with the assertion. (Later superseded by the anchored-reference semantics of deviation-D alignment, §4.3.9.)

#### 4.3.2 P1 Invariant Test Registry (74 → 77 tests)

> P1 quality assurance: Foundry-native invariant tests (random operation sequences + persistent invariant verification) covering the combination blind spots of single-scenario tests. The handler encapsulates 14 random operations (admit/remove/freeze/unfreeze/replace/reassignBinding/registerPairs/postVolume/correctVolume/finalizeConversion/submitShares/parkAdmit/completeParked/rollForward); each operation has a precondition check to keep the "expected success" paths reachable (invalid calls return directly without polluting state); target functions are explicitly limited via `targetSelector` (excluding the handler's `setUp()` — otherwise the fuzzer would treat it as a target and reset the sra instance).

| Invariant | Assertion | Bug classes it can catch |
|-----------|-----------|--------------------------|
| `invariant_SumShares_IsShareTotal` | after the most recent successful submitShares, the f02 share-map Σ is always == 1e18 | wrong share top-up direction, freeze-exclusion omission, recipient omission, all-zero burn path breakage |
| `invariant_OneBindingPerPair` | for every pair, `bindingOf` always == the handler's last-recorded binder (resolved along the replace chain) | **T6-class bugs** (third-party pair grab after replace), registerPairs bypassing the uniqueness check, reassignBinding write divergence |
| `invariant_GovernanceTasks_Consistent` | parked task bitmask nonzero and state not landed; executed task bitmask cleared; handler's expected orchestrator state == sra actual | bitmask residue after governance task execution, function-body state changes diverging from the governance flow, replace/remove identity-transfer state not synchronized |

**3 key handler↔implementation alignment fixes** (located through deterministic reproduction while writing the invariants; all were handler defects, not implementation bugs):

1. **replace overwrite semantics**: the implementation `replace` fully overwrites `orchestrators[newOrch]` (successor zeroed) — the handler must mirror `_successor[newOrch] = 0`, otherwise resolution diverges when an intermediate chain address is reused
2. **remove clears successor**: the implementation `remove` explicitly `orchestrators[orch].successor = 0` — the handler must mirror this, otherwise binding resolution still follows the old chain after remove
3. **parked-target mutual exclusion**: while `parkAdmit` is queued, the target address must not be pre-admitted by atomic `admit`/`replace` (newOrch), keeping I3 "parked-not-executed means state-not-landed" always true

**Run**: `forge test --match-contract SRAInvariant` (default 256 runs, ~3 minutes; handler operation stats show 0 reverts, proving the preconditions are complete).

#### 4.3.3 P2 Coverage Closure Registry (77 → 91 tests)

> P2 quality assurance: `forge coverage` baseline (77 tests) SRA contract line coverage **98.94%** (281/284, already above the 90% target), branch **58.21%** (39/67). 14 real blind spots identified and closed with 14 deterministic tests.
> ⚠️ Statistic finding: for governance function bodies with the `unanimous`/`unanimousNoHold` modifier, their require branches are **all recorded as 0 in lcov** (including remove NotAdmitted / reassignBinding NotAdmitted / replace AlreadyAdmitted / setPricingParams InvalidParameter, which G6 explicitly tests) — this is an lcov quirk for modifier-inlined function bodies, not a real gap, and was not re-tested. Real blind spots were double-confirmed with DA line coverage + one-sided BRDA gaps.

| # | Blind spot (line) | Added tests | Verification point |
|---|-------------------|-------------|--------------------|
| **CV1** | `postVolume` NotAdmitted (312) / `_checkPriceBand` ZeroClaimFil (660) | `SRAQuarter` `test_PostVolume_NotAdmitted_Reverts`<br>`test_PostVolume_ZeroClaimFil_Reverts` | non-admitted posting rejected; claimFil=0 divide-by-zero guard (require before division) |
| **CV2** | `correctVolume` NotAdmitted (481) / TooManyPricePeriods (482) / FIL-period loop body (489) | `SRAQuarter` `test_CorrectVolume_NotAdmitted_Reverts`<br>`test_CorrectVolume_TooManyPricePeriods_Reverts`<br>`test_CorrectVolume_WithFilPeriods_StoresAndResetsUsdValue` | non-admitted target rejected; over MAX_PRICE_PERIODS rejected; filPeriods whole-copy + defensive `usdValue=0` reset |
| **CV3** | `submitShares` NotBound (508) | `SRAShares` `test_SubmitShares_BeforeBinding_Reverts` | submit before binding (at E+POST+VERIFY) rejected (finalizeConversion's NotBound already tested; submitShares' own first line was missing) |
| **CV4** | `admit` AlreadyAdmitted (346) | `SRARegistry` `test_Admit_AlreadyAdmitted_Reverts` | re-admitting the same address rejected (G2 only tested AtCapacity full) |
| **CV5** | `freeze`/`unfreeze` four-way failure branches (371/372/381/382) | `SRARegistry` `test_Freeze_NotAdmitted_Reverts` / `test_Freeze_AlreadyFrozen_Reverts`<br>`test_Unfreeze_NotAdmitted_Reverts` / `test_Unfreeze_NotFrozen_Reverts` | NotAdmitted / AlreadyFrozen / NotFrozen gating failure paths |
| **CV6** | `replace` NotAdmitted(oldOrch) (396) | `SRARegistry` `test_Replace_OldNotAdmitted_Reverts` | old address not admitted rejected (G6 only tested the target-already-admitted reverse branch) |
| **CV7** | `aggregatedFPV` unposted continue (558) / `orchestratorCount` never called (596-597) | `SRAQuarter` `test_AggregatedFPV_UnpostedOrch_Excluded`<br>`SRARegistry` `test_OrchestratorCount_ReflectsAdmissions` | skip when some orchestrators did not post (!posted continue); read-only view count consistent with admittedCount |

**Implementation issue found**: no implementation defect was found during the closure (all new tests went Green directly, verifying existing behavior). Also fixed in passing the P1-leftover fmt difference in `test/SRAInvariant.t.sol` (`forge fmt`, not a semantic change), keeping the whole repo's `forge fmt --check` clean.

#### 4.3.4 Correctness Assurance Registry (91 → 94 tests + gas baseline)

> t6 correctness assurance (quality deepening after reviewer PASS): closed 3 test blind spots + 1 gas baseline.
> A1 covers the failure path of the SRA's only external interaction point with f02; A2/A3 bring the design's core security mechanisms (freeze snapshot, all-zero burn) under persistent invariant verification.

| # | Blind spot | Added tests | Verification point |
|---|------------|-------------|--------------------|
| **A1** | `SetSharesFailed` system-call failure never tested (mock had no failure-injection path) | `SRAShares` `test_SubmitShares_SetSharesFailed_Reverts` | mock adds a `failSetShares` failure-injection switch (`mockFailSetShares`) → `_setShares` unconditionally returns USR_FORBIDDEN → submitShares reverts `SetSharesFailed(USR_FORBIDDEN)`; with the switch off, a normal submit in the same quarter succeeds (control, proving the failure comes only from injection and SRA state is not polluted) |
| **A2** | the 3 invariants did not cover the "freeze snapshot" semantics (frozen-at-E+POST shares always 0, the design's core security mechanism) | `SRAInvariant` `invariant_FrozenAtPostEnd_ExcludedFromShares` | handler adds freeze-interval tracking (`_freezeAt`/`_unfreezeAt`, aligned with the implementation's `freezeEpochs`/`unfreezeEpochs`: freeze/unfreeze push, remove delete, replace deep-copy) → active orchestrators frozen at the POST instant of the latest submit quarter (**the address itself**; the implementation's `_frozenAtPostEnd continue` excludes that orchestrator, producing no wallet) must not appear in the share map |
| **A3** | D1 all-zero burn branch had no invariant verification (total==0 → single BURN record) | `SRAInvariant` `invariant_ZeroTotal_BurnsToBurnAddress` | before snapshotting, `finalizeConversion` first (idempotent with submitShares's internal call); usdValue read directly from the implementation's `sra.fpvOf(q, orch).usdValue` (**same data source as submitShares' traversal**) → when Σ of non-frozen-with-usdValue>0 at POST == 0 → share map is the single record `{BURN_ADDRESS, 1e18}`; when Σ>0 → map is a non-empty subset of the active orchestrators, all shares non-zero (trimmed of 0-share entries) |
| **E1** | no gas regression baseline | `.gas-snapshot` (generated by `forge snapshot`) | full-suite gas snapshot, preventing future gas regressions |

**Key handler↔implementation alignment points** (confirmed while writing A2/A3; all handler state tracking, not implementation bugs):
1. **Freeze-interval pairing**: `_isFrozenAtHandled` replicates the implementation's `_isFrozenAt` half-open `[freeze, unfreeze)` interval determination (already-unfrozen intervals `continue` to the next)
2. **replace deep-copy**: the implementation `replace` fully overwrites `orchestrators[newOrch]` (incl. freezeEpochs/unfreezeEpochs arrays) — the handler must deep-copy the freeze history, otherwise A2's determination for post-replace identity transfers diverges
3. **remove clears**: the implementation `remove` `delete`s the freeze arrays — the handler mirrors the clearing
4. **admit identity reset**: the implementation `admit` **resets** the freeze history and alias chain (semantics after the A2 defect fix: re-admit = fresh identity, clears successor/frozen/freezeEpochs/unfreezeEpochs) — the handler mirrors the cleanup (see §4.3.5)
5. **freeze set uses the address itself**: the implementation's `_frozenAtPostEnd continue` excludes the orchestrator **itself** (produces no wallet) — the handler pushes the orch address into the freeze set, not `resolve(orch)` (in a replace scenario resolve may point to an unfrozen successor, causing false positives)
6. **usdValue same-source read**: the fuzzer's `vm.roll` can rewind time, constructing a pseudo-timeline where "correctVolume/postVolume write after submitShares (finalize)" — here the implementation's `usdValue` keeps the finalized value and is not recomputed (correctVolume resets usdValue=0 + finalize is idempotent). The handler does not track usdValue manually; before snapshotting it calls `finalizeConversion` first, then reads `sra.fpvOf(q, orch).usdValue`, exactly matching submitShares' traversal

#### 4.3.5 A2 Real Defect Regression Registry (94 → 96 tests)

> t11 A2 real-defect fix (the A2 invariant failed randomly during t7/t8 toolchain verification acceptance; the coder reproduced it deterministically). Defect root cause and decision: see §3.4 (T10 entry).

**Defect chain**: `replace(old→new)` sets `old.successor = new` (old becomes an alias) → re-`admit(old)` before the fix leaves **successor residual** → `submitShares` freeze check `_frozenAtPostEnd(old)` (against old itself, not frozen, passes) but the wallet writes `_resolve(old) = new` (frozen at POST) → **a frozen orchestrator obtains a share through the resolve chain**, violating S5 freeze snapshot (frozen-at-E+POST shares are 0) and S7 (orch address is the wallet). Second residual face: `replace` only touches admitted/successor; `old.frozen`/freeze history remain — a previously frozen old address re-admits with frozen state carried in.

**Fix (option A: admit identity reset, symmetric with remove cleanup)**: `admit` appends `successor = address(0)`, `frozen = false`, `delete freezeEpochs`, `delete unfreezeEpochs` after setting admitted=true.
For fresh addresses admit is unaffected (fields are already empty); rejected options B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5's requirement to check the reporting orchestrator itself; old's legitimate FPV would be dragged down by frozen new, and other functions would be inconsistent) and C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple").

| # | Regression test | Assertion | Pre-fix (Red) failure message |
|---|-----------------|-----------|-------------------------------|
| **R1** | `SRAShares` `test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares` | `replace(old→new)` + `freeze(new)` + re-`admit(old)` + `correctVolume(old)` → after `submitShares` the share map does not contain new (frozen), old gets all 1e18, Σ==1e18 | `frozen successor must not receive shares: 1000000000000000000 != 0` (new got the entire share through the resolve chain) |
| **R2** | `SRARegistry` `test_ReAdmit_ResetsFrozenState` | `admit(old)` + `freeze(old)` + `replace(old→new)` (new inherits the freeze) + re-`admit(old)` → `isFrozen(old) == false`, old can postVolume normally next quarter | `re-admit must reset frozen state` (old.frozen residual) |

**Handler sync**: after the implementation's admit identity reset, the SRAInvariant handler's atomic `admit()` and `completeParked()` success branches both clear `_frozen[orch]`, `_successor[orch]`, `delete _freezeAt[orch]`, `delete _unfreezeAt[orch]` — otherwise I3c (isFrozen consistency) and A2 (freeze-interval tracking) keep false-positiving.

#### 4.3.6 Integration Contract Test Registry (96 → 100 tests)

> Spec-conformance deviation A disposition (found by the spec-conformance matrix):
> FIP-0118 states in three places that "reading AggregatedFPV(Q) triggers FinalizeConversion(Q) (if not yet run)" (§3.2/§4.1/§4.2),
> whereas the implementation `aggregatedFPV` was a pure view (approved design C7) — when not finalized it aggregates only stableUSD (missing the FIL component).
> The SWA reference implementation has no gating implementation, so a real SWA integration test is impossible; this file uses a test contract as the "gating consumer".
> **After deviation-A alignment (T11), the read auto-triggers the idempotent finalize (§2.3.5)** — the scenarios below lock the final contract behavior.

| # | Scenario | Assertion | Verification point |
|---|----------|-----------|--------------------|
| **C1** | `test_Contract_FinalizeFirst_AggregatedMatchesSubmitTotal` | after finalize, `aggregatedFPV(0) == 900e18` (incl. FIL component 500e18); `submitShares`'s `SharesSubmitted.totalUsd` captured via `vm.expectEmit` == 900e18 | core no-divergence: gating finalizes first → aggregatedFPV strictly equals submitShares' final value (negative verification: the test fails when totalUsd is changed to 901e18, proving the assertion is real) |
| **C2** | `test_Contract_SubmitSharesAutoFinalize_ThenReadConsistent` | direct `submitShares` (auto-triggers conversion) → `isFinalized(0) == true`, `aggregatedFPV(0) == 900e18`; shares a:b = 2:1 (666...667/333...333), Σ==1e18 | after submitShares auto-finalizes, subsequent reads of aggregatedFPV are consistent with the final value |
| **C3** | `test_Contract_ReadAutoFinalizes_ReturnsComplete` (rewritten by deviation-A alignment) | after binding, without explicit finalize, a read of `aggregatedFPV(0)` auto-triggers finalize → returns the complete 900e18 (incl. FIL component) + `isFinalized(0) == true` | read auto-triggers the idempotent finalize (spec §3.2/§4.1/§4.2); caller does not need to pre-finalize; no divergence from submitShares' total |
| **C4** | `test_Contract_StableOnly_ViewCompleteWithoutFinalize` | pure-stablecoin orchestrator: after binding without finalize, `aggregatedFPV(0) == 100e18` (stableUSD is the final value) | with no FIL component the view is complete without finalize |

**Value setup**: orchestrator a = 100e18 stable + 0.5 FIL at 1000 USD/FIL (`_period(5000, 1000, 1, 0.5e18)`, cold start no reference band-accepted) → 600e18;
orchestrator b = 300e18 pure stable → 300e18; total = 900e18; when unfinalized only 400e18 (stableUSD components).

#### 4.3.7 Differential Test Registry (100 → 103 tests)

> Breaking same-source bias (high-level correctness review blind spot 3): the current test mock and the SRA implementation share the same FVMRewards encoding library; if the encoding library / mathematical-semantics understanding is wrong, both fail together (the A2 defect proved this risk real). Differential tests use a **fully independent Python reference model**
> (`.ghost/references/014-differential/model.py`, derived independently from FIP-0118's mathematical semantics, not reading the Solidity implementation)
> to cross-validate the three computation cores; expected values are entirely computed by Python (seed=42 reproducible); on-chain outputs are compared entry by entry against the actual implementation calls.
> Detailed verification report: `.ghost/references/014-sra-differential.md`.

| # | Test | Cases | Cross-validation point |
|---|------|-------|------------------------|
| **D1** | `test_Diff_Share_MaxRemainder_AllCases` | 120 | largest-remainder share allocation: n∈{1,2,3,4,5,7,8}, divisible/indivisible/3-way-remainder/extreme ratios (1:1e6)/with-0 entries; ties broken by input order; Σ==1e18 conservation |
| **D2** | `test_Diff_Aggregate_Fpv_AllCases` | 30 | FPV aggregation: multiple orchestrators/periods, 6 rates (incl. claim>1 integer rounding: 1000/3, 1001/7, 2000/5); after finalize aggregatedFPV == Python expectation |
| **D3** | `test_Diff_Band_AllCases` | 25 | PRICE_BAND determination: cold start accepts / within-band accepts / out-of-band rejects / exact-boundary accepts / band=0 rejects any deviation / rational-rate cross multiplication; 3-print reference chains under the **anchor semantics** (deviation-D aligned) |

**Result: 175/175 all matched, no deviation found** — the implementation faithfully matches the spec's mathematical semantics (largest-remainder incl. tie-breaking, FPV aggregation integer rounding,
PRICE_BAND cross-multiplication determination all consistent with the independent derivation), substantially excluding the same-source bias risk on the three core computations.

**Case generation**: `python3 .ghost/references/014-differential/gen_cases.py` (seed=42) → `test/differential/DifferentialCases.sol`
(AUTO-GENERATED, committed for CI reproducibility; harness in `test/differential/DifferentialSharesHarness.sol`).

#### 4.3.8 State-Machine Symbolic Verification Registry (blind spot 4 closed, halmos not in the forge suite)

> Formal verification for the quarter-window determination (previously `_computeShares` had a Halmos symbolic proof but the windows did not).
> Run: `halmos --contract QuarterWindowCheck --loop 64 --no-test-constructor --solver-timeout-branching 2000 --solver-timeout-assertion 60000`
> Detailed verification report (incl. tool-limit probe experiments): `.ghost/references/015-sra-statemachine-verification.md`.

| # | check | Formal proposition (parameter-independent) | Result |
|---|-------|--------------------------------------------|--------|
| **T2a** | `check_T2a_QuarterEndNotInPosting` | now = E_q → ¬posting (posting is left-open; E_q belongs to the previous quarter's binding tail) | ✅ PASS |
| **T3** | `check_T3_QuarterProgression` | qEnd(q+1) − qEnd(q) == qEnd(1) − qEnd(0) (equal quarter spacing, no cross-quarter gaps) | ✅ PASS |
| **T4** | `check_T4_SnapshotTimeInvariant` | `_frozenAtPostEnd` is independent of the calling block.number (S5 anti-timing-game) | ✅ PASS |
| **T5b** | `check_T5b_IsFrozenAtEmpty` | no freeze history → never frozen at any epoch (empty-array boundary) | ✅ PASS |

**4/4 PASS**. The original proposition set T1 (full coverage + mutual exclusion) / T5 (interval search vs mathematical definition) / T6 (pairwise mutual exclusion) was **downgraded due to halmos 0.1.13 tool limits** (probe experiments confirmed): ① immutables become symbolic after skipping the constructor (window constants have no concrete values) → absolute boundary membership cannot be verified; ② `vm.warp` does not work on symbolic parameters (block.number cannot be symbolized) → universal verification of completeness relying on `currentEpoch()` is infeasible; ③ storage array element reads after push are wrong (length correct but elements symbolic) → freeze-interval search cannot be verified with storage-preset data. The downgraded propositions are covered by dynamic tests: window boundary ±1 on both sides 8 cases (SRAQuarter.t.sol), freeze/unfreeze in both directions + invariant A2 random freeze-history exclusion, 100% line coverage with no unexecuted paths — blind spot 4 is substantially closed within the tool's capability.

> **Evidence conditions (S3 annotation)** — the symbolic domain here is the **weak form** "arbitrary window config (immutables symbolized) + q small-domain enumeration + block.number = 0" (tool limits ①/②); it is **not** a universal-domain proof. The strong boundary semantics (now = E / E+1 / E+P / E+P+1 / E+P+V / E+P+V+1) are covered by the dynamic ±1 test set. The `_computeShares` Halmos proof (t8) additionally uses a symbolic usd domain of MAX_USD = 1e3 — a **proportional-space** sample (shares depend only on usd ratios, invariant under scaling); the enforced absolute domain (MAX_STABLE_USD = 1e30) is covered independently by the §5.5 domain-math bounds (band ≤ 1.2e64 / finalize ≤ 1e57 / per-orch ≤ 3.3e58 / total ≤ 2.1e60 ≪ 2^256), whose premise is now enforced in code (`_validateFpvBounds` at both input entries). Full report: `.ghost/references/012-sra-toolchain-verification.md` (t8) and `.ghost/references/015-sra-statemachine-verification.md` (t8's successor).

#### 4.3.9 Spec-Conformance Alignment Registry (deviation A/B/D unified implementation, 103 → 109 tests)

> After the user reviewed the 5 deviations one by one (principle: spec alignment first), the unified implementation landed: **A/B/D source+test alignment, C/E documentation clarification**.
> Changes: `src/ServiceRewardsActor.sol` (aggregatedFPV non-view auto-trigger / MIN_LOT filtering / anchored reference),
> tests (SRAQuarter +6, SRAIntegration C3 rewrite, differential model anchor semantics), base-class MIN_LOT dimension fix (1e18→100 USD).

**A — aggregatedFPV read auto-triggers finalize (aligned with spec §3.2/§4.1/§4.2)**:
- Implementation: `aggregatedFPV` changed from pure view to non-view; after binding a read auto-calls idempotent `_finalizeConversion(q)` (same path as submitShares), returning the complete USD value
- Tests: `SRAIntegration.test_Contract_ReadAutoFinalizes_ReturnsComplete` (C3 rewrite) — after binding without explicit finalize, a read yields the complete 900e18 + `isFinalized==true`; C1/C2/C4 unchanged (reading after explicit finalize is idempotent)

**B — MIN_LOT filtering (aligned with spec §3.3 qualifying-print semantics)**:
- Implementation: `_checkPriceBand` skips sub-MIN_LOT prints, `_updateLastBoundPrint` never makes them the reference, `_finalizeConversion` does not count their FIL amount
- Tests: `test_MinLot_SubMinLotPrint_ExcludedFromPricing` (sub-MIN_LOT does not pollute the reference), `..._NotCountedInConversion` (not counted in finalize), `..._EqualToMinLot_Qualifies` (==MIN_LOT qualifies, >= semantics)
- Base class: `MIN_LOT` 1e18 (mislabeled attoFIL) → **100 USD** (the spec's proposed "a few hundred USD" magnitude), so existing prints (lotUsd≥799) all qualify and the new low-lot cases can trigger the filter

**D — PRICE_BAND anchored reference (aligned with the spec's "last bound qualifying print"; prevents single-batch chained-drift manipulation)**:
- Implementation: `postVolume` removed the posting-time reference update; `_finalizeConversion` updates the anchor = the quarter's last qualifying print on completion (no qualifying print → anchor unchanged); `correctVolume` does not update the anchor
- Tests: `test_PostVolume_PriceBand_AnchorPreventsSameBatchDrift` (second print in a batch beyond band vs anchor → whole batch reverts; chained would pass), `..._AnchorUpdatesOnFinalize` (cross-quarter anchor update), `..._CorrectVolumeDoesNotUpdateAnchor` (correction does not affect next quarter's reference); the original 7 cross-quarter band tests gained a "quarter-0 finalize establishes the anchor" step
- Differential: model 3's reference chain changed to anchor semantics (print3 decided vs the anchor), model 2 gained min_lot filtering; `DifferentialCases.sol` regenerated (175 cases still all match)

**C/E clarification (documentation)**: C — the on-chain rejection of filPeriods.length>MAX_PRICE_PERIODS is an enforcement of the spec's "at most MAX_PRICE_PERIODS entries" format requirement (adjacent-period merging is the off-chain indexer's job), not a deviation; E — Replace's identity transfer (alias chain + frozen state) is a necessary completion of the spec's intent, no literal spec conflict, status quo kept. See §2.5.4 and §3.4 (T11).

#### 4.3.10 Post-Review Audit Hardening Registry (V1/V2/V3 + B1/C1/E1/E2/F2, 109 → 123 tests)

> A second review of PR #24 (post-squash) probed three overflow-DoS findings (**V1 anchor pollution / V2 finalizeConversion overflow / V3 _computeShares overflow**) — all confirmed real: `postVolume`/`correctVolume` had **no business-domain upper bounds** on `stableUSD`/`lotUsd`/`claimFil`/`attoFil`, so the §5.5 "Integer overflow ✅ Safe" conclusion rested on an **unenforced "business domain ~1e6" assumption** (see the QA-system diagnosis: no adversarial-input test layer, hypothesis-driven security claims, evidence-application-condition breaks, single threat model — documented in `.ghost/references/016-sra-qa-review.md`). The user arranged the V1/V2/V3 fix; the remaining audit backlog (B1/C1/E1/E2/F2) was completed in this pass.

**V1/V2/V3 — input-domain bounds enforced (fix commits `29293da` test + `ddbace4` fix)**:
- Implementation: `_validateFpvBounds` now rejects `stableUSD > MAX_STABLE_USD(1e30)` / `lotUsd > MAX_LOT_USD(1e30)` / `claimFil > MAX_CLAIM_FIL(1e30)` / `attoFil > MAX_ATTO_FIL(1e27)` / `claimFil == 0` at **both** input entries (postVolume + correctVolume); `_updateLastBoundPrint` additionally refuses domain-out-of-range prints from becoming the anchor (deep defense)
- Domain arithmetic: band products ≤ 1e30×1e30×12000 ≈ 1.2e64, finalize ≤ 1e27×1e30 = 1e57, per-orch usd ≤ 3.3e58, total ≤ 2.1e60 — all ≪ 2^256
- Tests: `test/SRAOverflowDoS.t.sol` (6): V1 anchor-pollution permanent-DoS / V2 finalize-overflow DoS / V3 computeShares-overflow DoS (each with Panic(0x11) precise assertion + post-fix "system stays usable" control), plus claimFil==0 / correctVolume-entry / anchor-refusal cases

**B1/C1/E1/E2/F2 — remaining bounds + owner rotation (this pass, 8 tests)**:
- **B1** `setPricingParams`: adds `minLot <= MAX_LOT_USD` (was only `maxPricePeriods > 0 && priceBand <= BASIS_POINTS`) — prevents minLot=max from silently skipping every print (FIL-pricing silent loss) — `SRAQuarter:test_SetPricingParams_MinLotTooLarge_Reverts`
- **C1** `registerPairs`: adds `pairs.length <= MAX_PAIRS(64)` with new `error TooManyPairs()` (aligns with MAX_ORCHESTRATORS; keeps the §5.5 DoS "traversals hard caps" premise) — `SRARegistry:test_RegisterPairs_TooManyPairs_Reverts` + `..._MaxPairs_Accepted` (64 boundary)
- **E1** `replaceOwner(address prevOwner, address newOwner)` (new governance write, `unanimousNoHold`): owner rotation — newOwner must be a Safe proxy (`isProbablyASafe`), revokes prevOwner (`removeOwner`), adds newOwner; **byte-identical to upstream SWA's replaceOwner** — closes the "no owner-rotation path → owner compromise/loss cannot be contained" gap (E1; the n-of-n key-loss residual risk is a shared-model design choice, documented §5.6) — `SRAGovernance:test_ReplaceOwner_SecondApproval_ExecutesImmediately` + `..._NonSafeNewOwner_Reverts` + `..._NonOwner_Reverts`
- **E2** constructor: adds the same parameter validation as setPricingParams (`maxPricePeriods > 0 && priceBand <= BASIS_POINTS && minLot <= MAX_LOT_USD`) plus `epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0` — deployment-time misconfiguration fails fast — `SRAGovernance:test_Constructor_InvalidParams_Reverts` (4 illegal configs)
- **F2** `setAdmittedLists`: adds `stablecoins.length <= MAX_ALLOWLIST(64) && filecoinPayContracts.length <= MAX_ALLOWLIST` (other arrays already had 64/32 caps) — `SRAGovernance:test_SetAdmittedLists_TooManyEntries_Reverts`

Final: SRA deterministic **118/118 Green** (SRAQuarter 44 + SRARegistry 28 + SRAShares 17 + SRAIntegration 4 + SRAGovernance 16 + SRAOverflowDoS 6 + differential 3), invariant 5/5, full suite **267/267** (123 SRA + 144 existing) no regression, `forge fmt --check` / `forge lint` clean.

#### 4.3.11 QA-System Fix Registry (S1-S5, 123 → 151 tests)

> The V1/V2/V3 finding was a **symptom of a QA-system gap**, not an isolated bug: every verification layer (deterministic/fuzz/invariant/differential) exercised inputs inside the "business domain" and none probed malicious extreme inputs; the security review was hypothesis-driven ("business domain ~1e6 → safe") rather than code-driven; evidence application conditions were broken (a bounded-domain Halmos proof was cited as whole-domain evidence; the fuzz `vm.assume(<1e30)` was a test-side shrink to dodge overflow); the threat model covered only honest-but-faulty callers; the reviewer default-trusted document "Safe" marks. The structural fixes S1-S5 close these gaps (diagnosis: `.ghost/references/016-sra-qa-review.md`).

**S1 — adversarial input test layer** (`test/SRAAdversarial.t.sol`, 28 tests, this pass):
- q-parameter window boundaries: postVolume/correctVolume/finalizeConversion/submitShares × (future quarter / uint64.max) → exact `NotInPostingWindow` / `NotInVerificationWindow` / `NotBound` selectors (7 tests)
- FPV field exact limits: each of stableUSD/lotUsd/claimFil/attoFil at its MAX accepts, MAX+1 rejects `InvalidParameter` (8 tests, Q0 cold start isolates `_validateFpvBounds` from the band check)
- zero-address probes: admit(0) accepted (governance semantics locked), freeze(0) NotAdmitted, registerPairs zero payer accepted, replaceOwner(0) NotSafeProxy, reassignBinding(0) NotAdmitted (5 tests)
- setPricingParams full parameter grid: priceBand ∈ {0, 10000} accepted (10001 rejected already covered), maxPricePeriods = 1 accepted, minLot ∈ {0, 1e30} accepted (1e30+1 rejected already covered, B1) (5 tests)
- empty-array semantics: registerPairs empty no-op, setAdmittedLists empty clears both allowlists (2 tests)
- multi-orchestrator aggregate bound: 2 × MAX_STABLE_USD posts → shares still Σ == 1e18 (1 test)
- every revert uses an **exact error selector** (no bare `expectRevert` — zero added, satisfying the §4.3.10 N3 requirement)

**S2 — security-claim → code-enforcement map** (§5.1 table): every "Safe"/"Conditionally safe" conclusion now cites the enforcing code point (require / mechanism, file:line); a claim without an enforcement reference fails review. Maps all 8 categories (e.g. Integer overflow → `_validateFpvBounds` @ postVolume:351 + correctVolume:545; DoS caps → MAX_PAIRS:329 / MAX_ALLOWLIST:492 / MAX_ORCHESTRATORS:395).

**S3 — evidence-application-condition annotation**: the fuzz sampling domain `(0,1e30)` is re-annotated as **equal to the code-enforced MAX_STABLE_USD** (not a test-side shrink — `SRAShares:369` + `SRAInvariant:255,268`); the Halmos `MAX_USD=1e3` symbolic domain is annotated as a **proportional-space** proof with the enforced absolute domain's arithmetic safety independently covered by the §5.5 domain-math bounds (docs §4.3.8 S3 note; `.ghost/references/012` + `015`).

**S4 — threat model matrix** (§5.13): all 15 external write functions × (malicious orchestrator / compromised owner) → impact → mitigation → sufficiency; every function is closed either by unanimous dual-Safe governance or by code-enforced input bounds + timing gates.

**S5 — reviewer checklist** (§5.14): 6 items forcing the reviewer to challenge premises — security-claim→code map verified against source / evidence conditions satisfied by code / adversarial internal party in scope / adversarial input coverage complete / test-claim correspondence (no bare `expectRevert`) / Red-first regression after any new finding.

Final: SRA deterministic **146/146 Green** (SRAQuarter 44 + SRARegistry 28 + SRAShares 17 + SRAIntegration 4 + SRAGovernance 16 + SRAOverflowDoS 6 + SRAAdversarial 28 + differential 3), invariant 5/5, full suite **295/295** (151 SRA + 144 existing) no regression, `forge fmt --check` / `forge lint` clean.

### 4.4 Key Test Design Decisions

#### 4.4.1 Test Constants (constructor config)

| Constant | Test value | Design rationale |
|----------|------------|------------------|
| `EPOCHS_PER_QUARTER` | 1000 | easy manual window-boundary arithmetic |
| `POST_PERIOD` | 300 | **> 2×SRA_CANCEL_HOLD**: guarantees two consecutive freezes (each 2 votes + 100 hold) within the posting period complete before E+POST (the timing prerequisite for all-frozen → burn) |
| `VERIFICATION_WINDOW` | 400 | — |
| `SRA_CANCEL_HOLD` | 100 | — |
| `ACTIVATION_EPOCH` | 100_000 | far past the block after "registering stream 2 requires advancing SWA_TIMELOCK(20160)", quarter-0 window is clean |
| `MIN_LOT` | 100 | 100 USD (lot face value; design §2.6 proposes "a few hundred USD"; a small test value keeps all existing prints qualifying) |
| `PRICE_BAND` | 2000 | **basis points** (2000 = allows ±20% deviation), test assumption H-band |
| `MAX_PRICE_PERIODS` | 32 | design §2.6 proposed value |

#### 4.4.2 Timeline Model

- `Epoch = block.number` (controlled by `vm.roll`, 📘 Epoch.sol)
- Quarter windows (§2.5.1): posting `(E, E+POST]` → verification `(E+POST, E+POST+VERIFY]` → post-binding
- Governance hold: two votes → `vm.roll(+SRA_CANCEL_HOLD)` → third call (permissionless) completes execution
- correctVolume (unanimousNoHold): the second vote executes immediately, no roll needed

#### 4.4.3 Mock Integration

- service stream 2 is registered by the test base as a "temporary swa" (`mockSwa(address(this))` → `FVMRewards.tryRegisterStream(2, EXPLICIT, writer=address(sra), activation)` → roll past SWA_TIMELOCK → `mockAwardBlockReward(0)` triggers `_settle`), matching f02-design's "migration pins service = 2"
- Share assertions read the mock's `getShares(2)`: the mock validates Σ==1e18, ≤64 recipients, writer permission (📘 FVMRewardActor._setShares); the main-branch mock additionally validates each share non-zero and wallets non-duplicate (`_sharesValid`) — which surfaced the zero-share filtering fix in §2.5.3

### 4.5 How to Run

```bash
# project foundry.toml usable directly (forge 1.7.1; P0 fixed fmt/lint)

# --- deterministic + contract tests (default suite) ---
forge test --match-contract SRA          # SRA tests (deterministic + invariant + differential + contract)
forge test                               # full suite (SRA + existing f02/governance tests)

# --- invariant only (handler-based randomized sequences, ~3 minutes) ---
forge test --match-contract SRAInvariant

# --- differential tests (Python independent reference model, 175 cases, seed=42) ---
forge test --match-contract DifferentialShares

# --- symbolic verification (halmos) ---
# 前置: forge 1.7+ 默认不为 test 合约输出 AST, 而 halmos 从 out/ 读取 ast 字段 —— 先 `forge build --ast`
# (若跳过此步, halmos 报 "KeyError: 'ast'"; 自 halmos 0.1.13 起 extra_output=["ast"] 已被 forge 移除, 改为 --ast flag)
forge build --ast
# 两个 harness 的父构造器含 Safe 检查(isProbablyASafe), halmos 符号执行 constructor 会路径超限
# ("ValueError: constructor: # of paths")——必须 --no-test-constructor; --loop 64 展开余数补位循环;
# 默认 SMT branching timeout=1ms 太短, 需加大
halmos --contract ComputeSharesCheck --no-test-constructor --loop 64 --solver-timeout-branching 2000 --solver-timeout-assertion 60000   # _computeShares 6/6 (~125s)
halmos --contract QuarterWindowCheck --loop 64 --no-test-constructor --solver-timeout-branching 2000 --solver-timeout-assertion 60000   # quarter-window state machine 4/4
# ("Skipped console2.json ... KeyError: 'metadata'" 是无害 warning, forge-std 库文件, 可忽略)

# --- static analysis (slither 0.11.x) ---
slither . --exclude-dependencies         # 0 high / 0 medium (2 style-class findings, see §5.10)

# --- quality gates (CI) ---
forge fmt --check
forge lint --deny notes --quiet
forge coverage --match-contract SRA      # SRA line coverage 100% (branch 67% is the lcov tool ceiling, see §5.11)
```

**Development history (progression of the SRA suite; kept for traceability)**:

- Initial implementation: `src/ServiceRewardsActor.sol` implemented (coder phase); 91 SRA tests + 219 full-suite tests passed (88 SRA + 3 invariant + 128 existing). During implementation 7 test-side defects were found (T2-T5: missing prank on re-submission after veto, postVolume posting timing out of window, cap expectRevert misplaced on the second vote, makeAddr salt depending on block.number causing address collisions) and fixed by the tester — test intent and coverage strategy unchanged, only aligned with the governance library's real semantics.
- **T6 (found in the final review, TDD test-first)**: the final code review found `registerPairs`'s AlreadyBound check uses `_isAdmitted(current)` instead of `_resolve(current)` — after replace the binding still points to the old address (admitted=false), the check is bypassed, and a third party can grab the binding pair. The tester added `test_RegisterPairs_AfterReplace_ThirdPartyReverts` (Red before the fix; coder's 1-line fix `_isAdmitted(_resolve(current))` made it Green).
- **G1-G7 (systematic assessment closure, 58 → 74 tests)**: after the scheduler's systematic assessment of the test suite, the tester closed 7 coverage gaps (16 new tests, see §4.3.1) — setPricingParams parameter management, 64-full combination, exact band boundaries, MAX_PRICE_PERIODS exactly 32, multi-quarter share isolation, governance failure paths, share-Σ fuzzing. After closure: SRA 74/74 Green, full suite 202/202 no regression.
- **P1 (invariant tests, 74 → 77 tests)**: quality assurance P1 — Foundry-native invariant tests (§4.3.2), the handler encapsulates 14 random operations persistently verifying 3 invariants (share conservation / binding uniqueness / governance consistency). 3 handler state-tracking defects found and fixed during writing (replace overwrite semantics, remove clears successor, parked-target mutual exclusion; all handler-side, not implementation bugs). Final: SRA 77/77 Green, full suite 205/205 no regression.
- **P2 (coverage closure, 77 → 91 tests)**: quality assurance P2 — `forge coverage` baseline SRA line coverage 98.94% (281/284) already above the 90% target; branch 58.21% (39/67) was the main blind spot. 14 real gaps confirmed (§4.3.3) and closed with 14 deterministic tests covering error branches (NotAdmitted/AlreadyAdmitted/AlreadyFrozen/NotFrozen/ZeroClaimFil/NotBound/TooManyPricePeriods) and rare paths (correctVolume with FIL periods, aggregatedFPV unposted exclusion, orchestratorCount view). After closure: SRA deterministic 88/88 Green, full suite 219/219 no regression, `forge fmt --check` clean (incl. the P1-leftover invariant file fmt fix).
- **t6 (correctness assurance, 91 → 94 tests + gas baseline)**: quality deepening after the final review PASS (§4.3.4) — A1 system-call failure injection (mock `failSetShares` switch → submitShares reverts SetSharesFailed + control success path), A2 freeze-snapshot invariant (handler freeze-interval tracking; frozen-at-POST shares always 0), A3 all-zero burn invariant (total==0 → single BURN record), E1 `forge snapshot` gas baseline (`.gas-snapshot` committed). A2/A3 found no implementation defect (handler state tracking aligned point by point with the implementation's freeze semantics, then Green directly). Final: SRA deterministic 89/89 Green, invariant 5/5, full suite 222/222 no regression, `forge fmt --check` clean.
- **t11 (A2 real defect fix, 94 → 96 tests)**: during the t7/t8 toolchain verification acceptance's full-suite run, the A2 invariant **failed randomly** (t6's 5/5 Green was a probability miss); the coder reproduced it deterministically, confirming a **real implementation defect** (§4.3.5) — after `replace(old→new)`, re-`admit(old)` did not clear the successor; the `submitShares` freeze check passes for old itself but the wallet resolves to the frozen new → a frozen orchestrator obtains a share through the resolve chain (violating S5/S7). The fix (option A: admit identity reset) appends clearing successor/frozen/freezeEpochs/unfreezeEpochs to `admit` (symmetric with remove cleanup), and syncs the SRAInvariant handler's admit/completeParked state cleanup. 2 deterministic regression tests added (R1/R2; pre-fix Red failure messages in §4.3.5). Final: SRA deterministic 91/91 Green, invariant 5/5 stable, full suite 224/224 no regression, `forge fmt --check` clean, `.gas-snapshot` baseline re-run.
- **A2 contract tests (spec-conformance deviation A disposition, 96 → 100 tests)**: the spec-conformance matrix found deviation A — spec "reading AggregatedFPV triggers FinalizeConversion" vs implementation pure view (C7). The SWA reference implementation has no gating consumption code, so `test/SRAIntegration.t.sol` (§4.3.6) was added with the test contract simulating the gating consumer, initially locking the contract "finalize first then read == submitShares final value (no divergence)" (C1 verified via expectEmit negative testing). Design §2.3.5 gained the contract declaration. Final: SRA deterministic 95/95 Green, full suite 228/228 no regression, `forge fmt --check` clean.
- **t1 (differential tests, 100 → 103 tests)**: breaking same-source bias (§4.3.7) — the Python independent reference model (derived from FIP-0118 mathematical semantics, not reading the Solidity implementation) cross-validates the three computation cores: largest-remainder share allocation (120 cases, incl. tie-breaking/extreme ratios/with-0), FPV aggregation (30 cases, incl. claim>1 integer rounding), PRICE_BAND determination (25 cases, incl. cold start/boundaries/reference chains). **175/175 all matched, no deviation found** — the implementation faithfully matches the spec's mathematical semantics; the same-source bias risk is substantially excluded. Cases seed=42 reproducible; `test/differential/DifferentialCases.sol` committed for CI. Final: SRA deterministic 98/98 Green, full suite 231/231 no regression, `forge fmt --check` clean, `.gas-snapshot` updated.
- **State-machine symbolic verification (blind spot 4 closed, halmos not in the forge suite)**: formal verification for the quarter-window determination (§4.3.8) — Halmos proves 4 **parameter-independent** propositions (T2a quarter boundary / T3 constant interval / T4 snapshot-time independence / T5b empty-history boundary) **4/4 PASS**. The original T1/T5/T6 were downgraded due to halmos 0.1.13 tool limits (immutable symbolization / warp not supporting symbols / storage array element defect, confirmed by probe experiments), covered instead by dynamic tests (window boundary ±1 8 cases + freeze/unfreeze in both directions + invariant A2 random freeze history + 100% line coverage). The forge suite 231/231 is unaffected (halmos checks run only under halmos).
- **Spec-conformance alignment (deviation A/B/D unified implementation, 103 → 109 tests)**: after the user reviewed the 5 deviations one by one (principle: spec alignment first), the unified implementation landed (§4.3.9) — **A** aggregatedFPV changed to non-view with read auto-triggering finalize (C3 rewrite locks "read yields the complete value"); **B** MIN_LOT filtering (sub-MIN_LOT prints do not participate in pricing: band check skipped, never become the reference, not counted in finalize; base-class MIN_LOT corrected to 100 USD); **D** PRICE_BAND anchored reference (reference update moved to quarter-binding finalize, preventing chained stepping within a single postVolume from pushing the anchor arbitrarily far). Differential model synced to anchor semantics (model 3 reference chain → anchor, model 2 + min_lot filter); 175 cases still all match. Final: SRA deterministic 104/104 Green (SRAQuarter 43 + SRARegistry 26 + SRAShares 17 + SRAIntegration 4 + SRAGovernance 11 + differential 3), invariant 5/5, full suite 253/253 (109 SRA + 144 existing) no regression, `forge fmt --check` clean.

## 5. Security Review

> Scope: Issue #4 Service Rewards Actor (FIP-0118) `src/ServiceRewardsActor.sol` (721 lines) and its dependency libraries
> (`src/lib/`: governance, f02 interaction, time, ownership).
> Purpose: a **systematic security review checklist** for maintainers and future security reviewers — walk through the contract by vulnerability class,
> recording each class's review conclusion (why it is safe / what residual risk exists / what premises it depends on), for reuse in PR review and future audits.
> Supporting evidence: `.ghost/references/012-sra-toolchain-verification.md` (t7 Slither + t8 Halmos full report, agent-internal, not committed);
> decisions: §3 (full D/S/C/T/G); design: §2; tests: §4.

### 5.1 Review Conclusion Summary

> **S2 security-claim → code-enforcement map**: each "Safe" conclusion below must cite the enforcing code point (require / mechanism); a claim without an enforcement reference fails review.

| # | Category | Conclusion | Key basis | Code-enforcement point |
|---|----------|------------|-----------|------------------------|
| 1 | Reentrancy | ✅ Safe | no value transfer; the only external call is an fvm precompile with no callback surface | no value transfer (no `payable`/`call`/`transfer` anywhere in `src/ServiceRewardsActor.sol`); the only external call is `FVMRewards.setShares` (fvm precompile, no callback), `submitShares:577` |
| 2 | Denial of Service (DoS) | ⚠️ Conditionally safe | all traversals have hard caps (64/32); freeze-history arrays and the replace chain are theoretical growth points | `registerPairs` `pairs.length <= MAX_PAIRS(64)` `:329`; `setAdmittedLists` `length <= MAX_ALLOWLIST(64)` `:492`; `postVolume`/`correctVolume` `filPeriods.length <= maxPricePeriods` `:351`/`:545`; `admit` `admittedCount < MAX_ORCHESTRATORS(64)` `:395`. Freeze-history / replace-chain growth is unbounded by design (needs n unanimous governance actions to construct — theoretical only, no code cap) |
| 3 | Access control | ✅ Safe | governance dual-Safe unanimous + hold; orchestrator self-operations gated; constructor validates Safe proxy | `unanimous`/`unanimousNoHold` modifiers gate every governance method (`admit:395` / `remove:410` / `freeze:424` / `unfreeze:434` / `replace:447` / `reassignBinding:473` / `replaceOwner:484` / `setAdmittedLists:492` / `setPricingParams:520` / `correctVolume:545`); `_veto` requires `msg.sender.isOwner()` (cancelPending:533); constructor `newOwner.isProbablyASafe()` (E2 `:256`) |
| 4 | Integer overflow | ✅ Safe | 0.8.x checked arithmetic fully on; **input-domain bounds enforced at the entries** (MAX_STABLE_USD=1e30 / MAX_LOT_USD=1e30 / MAX_ATTO_FIL=1e27 / MAX_CLAIM_FIL=1e30, audit V1/V2/V3 fix); Halmos P6 no overflow (symbolic domain MAX_USD=1e3 — proportional-space proof; the enforced absolute domain's arithmetic safety is independently covered by the domain-math bounds below, S3: proof premise = code-enforced domain) | `_validateFpvBounds` enforces all four field bounds at **both** input entries — `postVolume:351` and `correctVolume:545` (plus `claimFil > 0`); `_updateLastBoundPrint` refuses domain-out-of-range prints from becoming the anchor (deep defense, `:803`); checked arithmetic (0.8.36 default) |
| 5 | Encoding and boundaries (ABI/CBOR) | ⚠️ Conditionally safe | input side protected by the ABI decoder; output side bounded CBOR; wire contract pending f02 implementation check | input side: Solidity ABI decoder (compile-time, rejects malformed calldata); output side: bounded CBOR in f02 mock (`test/mocks/FVMRewardActor.sol`); wire contract vs real f02 implementation is a protocol-layer premise (no contract-layer code can enforce it) |
| 6 | Precision issues | ✅ Safe | floor + largest-remainder Σ==1e18; rational rates; Halmos conservation/monotonicity/floor bound | `_computeShares` largest-remainder method `:735` (Σ shares == SHARE_TOTAL exactly, remainder descending + residue top-ups); rational rates (`attoFil * lotUsd / claimFil`) kept in integer math |
| 7 | Governance path | ✅ Safe | three-phase + dual Safe + event traceability; re-admit semantics closed after T10 | three-phase `unanimous` modifier (approve/approve/hold → permissionless execution, `UnanimousGovernance.sol`); re-admit identity reset in `admit:395` (clears successor/frozen/freezeEpochs — T10 A2 fix) |
| 8 | Front-running | ✅ Safe | E+POST snapshot semantics independent of keeper timing; permissionless triggers have no privilege and no MEV | `_frozenAtPostEnd` derives the frozen snapshot from the freeze-history arrays at the E+POST instant (`:303`), independent of when the caller invokes finalize/submitShares; permissionless `finalizeConversion:572` / `submitShares:577` / `aggregatedFPV:635` have no privileged action |

**Overall conclusion**: the SRA is a **value-transfer-free** pure state machine (writes f02 shares); the attack surface concentrates on **governance authority** and **data correctness**.
The governance surface is strongly constrained by dual-Safe unanimous + hold; data correctness is assured by 100% line-coverage tests + 5 invariants + Halmos symbolic verification + Slither static analysis
as a four-layer assurance, and 1 real defect has been caught and fixed (T10 A2: re-admit identity residue letting a frozen orchestrator obtain a share through the resolve chain).
All residual risks are **theoretical boundaries** or **protocol-layer premises** (the f02 wire contract not upstream-confirmed, dual-Safe private-key security); no known exploitable contract-layer vulnerability.

### 5.2 Reentrancy

**Conclusion: ✅ Safe (no reentrancy surface)**

**Basis**:

- **No value transfer**: the SRA declares no `receive`/`fallback`, never receives or holds ETH/FIL (design §1 "SRA never receives or holds value"), no `transfer`/`call` to arbitrary addresses.
- **The only external call is an fvm precompile**: `submitShares` ends by calling `FVMRewards.setShares` (`src/lib/FVMRewards.sol:trySetShares`), whose base is `delegatecall(gas(), CALL_ACTOR_BY_ID, ...)` — `CALL_ACTOR_BY_ID` is a **precompile address constant** of the Filecoin VM (`fvm-solidity/FVMPrecompiles.sol`), not an arbitrary contract address; **no attacker-controllable callback surface exists**. f02's SetShares is a pure state write and does not call back into the SRA.
- **CEI ordering**: the external call sits at the end of `submitShares` (collect shares, compute, then write to f02), and a failed f02 share write reverts the whole transaction (`SetSharesFailed`, covered by A1 injection tests) — atomic state rollback, no "mutate-then-external-call" window.
- **Toolchain confirmation**: the Slither scan across 102 detectors **did not trigger** reentrancy detectors (012 report §B1); invariant handler random operations show 0 reverts (tests doc §4.3.2).

**Residual risk**: none substantive. The only theoretical point is f02 precompile determinism (an f02 implementation defect would surface as an exit code, with revert semantics wrapped as `SetSharesFailed`, not affecting SRA state).

### 5.3 Denial of Service (DoS)

**Conclusion: ⚠️ Conditionally safe (all computation bounded; two theoretical growth points)**

**Basis**:

- **Traversals have hard caps**:
  - `admittedList` ≤ 64 (`MAX_ORCHESTRATORS`, D2; `admit` rejects when full, only `remove` releases) → `submitShares`/`_finalizeConversion`/`aggregatedFPV` traversals O(64) bounded; `_computeShares` remainder top-up O(n²) = 4096 iterations bounded (§2.5.3).
  - `filPeriods.length ≤ MAX_PRICE_PERIODS` (32, S10) → `postVolume`/`correctVolume`/`_finalizeConversion` period loops bounded.
  - `_isFrozenAt` freeze-interval search O(freeze count): each freeze/unfreeze requires two governance votes + hold; frequency is naturally constrained by governance cadence.
- **No externally expandable input**: `admittedList` can only be modified by governance `admit`/`replace`; pair-binding uniqueness is guaranteed by `registerPairs` (checked along the resolve chain after the T6 fix).
- **Covered by tests**: 64-full rejection / 64-all-posted map boundary (G2), exactly-32 periods accepted (G4), share-Σ fuzz (G7), `orchestratorCount` view (CV7).

**Residual risk (theoretical growth points, not exploitable vulnerabilities)**:

1. **Freeze-history arrays have no hard cap**: `freezeEpochs`/`unfreezeEpochs` push one entry per governance freeze/unfreeze; array length grows linearly with governance operations; `_isFrozenAt` and `_isFrozenAtHandled` (invariant handler) are O(array length). Constrained by the governance consensus threshold, decades of operation yield tens of entries (O(tens) negligible); if governance frequency becomes extremely high, an array cap could be evaluated.
2. **Replace-chain length has no hard cap**: `_resolve` resolves along the successor chain with a while loop. Chain formation requires one governance `replace` per step (old becomes an alias, admitted=false; chain-intermediate nodes cannot be removed or replaced), so chain length is naturally constrained by governance frequency; but there is no explicit cap, and under extreme governance abuse the resolve cost in `submitShares` grows linearly. **Recommended: future reviewers evaluate adding a chain-length cap** (currently constrained by governance cadence, not urgent).

### 5.4 Access Control

**Conclusion: ✅ Safe (layered permission model)**

**Basis**:

- **Governance write operations** (`admit`/`remove`/`freeze`/`unfreeze`/`replace`/`reassignBinding`/`setAdmittedLists`/`setPricingParams`) all go through `unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)` (`src/lib/UnanimousGovernance.sol`):
  - dual-Safe bitmask check (`Owners.sol:isOwner`/`asOwnerSet`; non-owner `NotOwner` reverts; the same owner approving twice `AlreadyApproved` reverts);
  - both votes in place + permissionless execution after the hold elapses (`HoldUntil` time lock);
  - taskId = `keccak256(msg.data)` — both Safes must submit byte-identical calldata (I2 array normalization convention, covered by `TaskId_DifferentArrayOrder_DoesNotMerge`).
- **correctVolume** goes through `unanimousNoHold`: dual-Safe full-vote immediate execution (design D3: the verification window itself is the hold), with in-body window validation.
- **cancelPending** goes through `_veto`: either Safe alone cancels a pending task (can stop a malicious governance proposal during the hold).
- **Orchestrator self-operations** (`registerPairs`/`postVolume`): `require(_isAdmitted(msg.sender))` + `require(!_isFrozen(msg.sender))`.
- **Mechanism operations** (`finalizeConversion`/`submitShares`): permissionless — read only bound aggregated state and write f02 shares; no permission-sensitive surface (any keeper trigger yields the same result).
- **Constructor validation**: the constructor runs `isProbablyASafe` on both owners (`IsASafe.sol`: code-size range + masterCopy code-size check), preventing non-Safe addresses from being bound at deployment.
- **Toolchain confirmation**: Slither did not trigger permission-class detectors (no tx.origin, no unprotected writes); the governance flow's 11 tests (SRAGovernance) cover three-phase/hold/veto/taskId fully.

**Residual risk/premises**:

- The permission model depends on **the security of the two Safe private keys** (off-chain key management is a protocol trust premise, not contract-mitigable).
- `setAdmittedLists` array parameters require both Safes to agree on a **normalization order** (sorting, consistent encoding), otherwise taskId mismatch causes governance deadlock (I2 — an availability risk, not a security vulnerability; control cases covered by tests).
- Governance operation execution is permissionless (anyone can trigger completion after the hold elapses) — this is by design (keeper triggering), not unauthorized access.

### 5.5 Integer Overflow

**Conclusion: ✅ Safe — conditional on the input-domain upper bounds enforced at the entries (audit V1/V2/V3 fix)**:
`MAX_STABLE_USD = 1e30` / `MAX_LOT_USD = 1e30` / `MAX_ATTO_FIL = 1e27` / `MAX_CLAIM_FIL = 1e30`, validated by
`_validateFpvBounds` in `postVolume`/`correctVolume`, locked by the `SRAOverflowDoS.t.sol` regression tests (6 cases).

**Basis**:

- **Checked arithmetic**: Solidity 0.8.36 reverts on overflow by default; the whole contract has **no `unchecked` blocks**; Slither did not trigger unchecked/integer-overflow detectors.
- **Input-domain bounds (audit V1/V2/V3 fix)**: the §5.5 "business domain ~1e6" assumption is now **enforced at the code level** by `_validateFpvBounds` (rejects `stableUSD > MAX_STABLE_USD`, `lotUsd > MAX_LOT_USD`, `claimFil > MAX_CLAIM_FIL`, `attoFil > MAX_ATTO_FIL`, `claimFil == 0` at both input entries). The bound chain closes the overflow arithmetic:
  - `_checkPriceBand` (V1): `lotUsd × claimFil × (BASIS_POINTS+band) ≤ 1e30×1e30×12000 ≈ 1.2e64 ≪ 2^256`;
  - `_finalizeConversion` (V2): `attoFil × lotUsd ≤ 1e27×1e30 = 1e57 ≪ 2^256` (`MAX_ATTO_FIL = 1e27` ≈ 1e9 FIL — network supply is ~2e9 FIL, a single print physically cannot exceed it);
  - `_computeShares` (V3): per-orchestrator usd ≤ `1e30 + 32×1e57 ≈ 3.3e58 < 2^256/1e18`; total (≤ 64) ≤ `2.1e60 ≪ 2^256`.
  - Deep defense: `_updateLastBoundPrint` also skips out-of-domain prints, so the PRICE_BAND anchor can never be polluted even via a future entry bypassing `_validateFpvBounds`.

**Bound-value rationale (why 1e30 / 1e27, and why the MAX_CLAIM_FIL / MAX_ATTO_FIL asymmetry)**:

  - **Loose-by-design**: the assumed business domain is ~1e6 USD/quarter. All three USD/FIL value bounds sit at 1e30 — ~24 orders of magnitude above the business domain and ≈1e16× Earth's annual GDP (~1e14 USD) — so no realistic service revenue can ever approach the cap. The bounds are immutable (`constant`), so the looseness is a deliberate trade: permanent headroom in exchange for a cap that is not tight. The arithmetic chain above still closes with ≥3.5× headroom at its tightest link (V3 per-orch usd 3.3e58 vs `2^256/1e18 ≈ 1.16e59`).
  - **MAX_ATTO_FIL = 1e27 (= 1e9 FIL) — the chain's keystone and its only *physical* bound**: Filecoin's total supply is ~2e9 FIL; a single print's attoFil can physically never exceed 1e9 FIL. This is the only bound resting on a physical invariant rather than a business assumption. Loosening it to 1e30 would make per-orch usd ≈ 3.2e61 > `2^256/1e18` and re-open V3 — the keystone cannot be relaxed without re-deriving the chain.
  - **MAX_CLAIM_FIL = 1e30 is intentionally *not* tightened to the FIL supply**: `claimFil` sits in the **denominator** of `_finalizeConversion` (`attoFil × lotUsd / claimFil` — a larger value only shrinks the result; the only dangerous value is 0, guarded by `ZeroClaimFil`), and in `_checkPriceBand` it multiplies as `lotUsd × claimFil × (BASIS_POINTS+band)` where 1e30×1e30×12000 ≈ 1.2e64 still leaves ~13 orders of magnitude below 2^256. So claimFil does not constrain the overflow closure the way attoFil does — the symmetric 1e30 is kept for simplicity (tightening buys no arithmetic safety). Note the `PricePeriod` struct comment marks claimFil as `attoFIL`; read that way, 1e30 attoFIL = 1e12 FIL still exceeds the physical supply — harmless for the same denominator reason, and `2e9 FIL (= 2e27 attoFIL)` is the natural value if a tighter semantic cap is ever desired.
  - **⚠️ Maintenance warning**: the closure above assumes all four bounds + `MAX_PRICE_PERIODS(32)` + `MAX_ORCHESTRATORS(64)` hold **together** — the links are interdependent, not independent. If any of these constants is ever changed (e.g. raising MAX_PRICE_PERIODS or MAX_ATTO_FIL), re-derive this chain before shipping.
- **Other input-domain bounds (audit B1/C1/E2/F2)**: beyond the FPV value fields, the remaining length/value inputs are bounded so the "DoS conditionally safe (traversals hard caps 64/32)" premise holds everywhere:
  - **B1** `setPricingParams` validates `minLot <= MAX_LOT_USD` (a minLot=max would silently skip every print with lotUsd ≤ MAX_LOT_USD — FIL pricing silent loss, worse than a revert);
  - **C1** `registerPairs` validates `pairs.length <= MAX_PAIRS(64)` (`error TooManyPairs`), aligned with MAX_ORCHESTRATORS;
  - **F2** `setAdmittedLists` validates `stablecoins.length <= MAX_ALLOWLIST(64) && filecoinPayContracts.length <= MAX_ALLOWLIST`;
  - **E2** the constructor validates the same pricing-parameter bounds as setPricingParams plus `epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0` — deployment misconfiguration fails fast instead of silently misbehaving.
- **Share computation** (*historical magnitude note* — superseded as the primary argument by the entry-enforced input-domain bounds above; kept for its Halmos reference): `_computeShares`'s `usds[i] * SHARE_TOTAL` (×1e18) — usd aggregation at business magnitude ~1e6 (USD face value); 1e6 × 1e18 = 1e24 ≪ 2^256 ≈ 1.16e77; Halmos P6 `check_NoOverflow_Boundary` proves no overflow within the symbolic domain (012 report §C1).
- **Window computation**: `_qEnd` uses `uint256(ACTIVATION_EPOCH) + uint256(q) * uint256(Epoch.unwrap(EPOCHS_PER_QUARTER))` as an intermediate guard (S1C, §2.5.1), then casts to Epoch(uint64).
- **PRICE_BAND cross-multiplication**: `_checkPriceBand`'s `lhs = p.lotUsd * lastClaimFil * BASIS_POINTS` (domain ~1e18 × 1e18 × 1e4 = 1e40 < 2^256), and `priceBand ≤ BASIS_POINTS` is validated by `setPricingParams` (`InvalidParameter`).
- **Epoch magnitude**: Epoch is uint64 (2^64 ≈ 1.8e19 epochs, ~1.7e13 years) — quarter number Q × EPOCHS_PER_QUARTER at normal business scale is far below this, and the `_qEnd` range guard rejects anything beyond the width.

**Residual risk/premises**:

- `Epoch.sol`'s `add`/`sub` are implemented in assembly (no overflow check) — a design trade-off at the uint64 magnitude, with the `_qEnd` range guard bounding inputs (unreachable in normal use).
- Theoretical boundary: if a malicious huge `q` (uint64 max) is passed and the deployment config's EPOCHS_PER_QUARTER is also huge, the `_qEnd` cast to uint64 could truncate — but the range guard rejects `end > type(uint64).max` first (`InvalidParameter`), so this is closed. Normal quarter numbers (~90 days each) reaching 2^64 quarters takes 5e19 years. **Listed as a theoretical boundary; no action needed**.

### 5.6 Encoding and Boundaries (ABI input / CBOR output)

**Conclusion: ⚠️ Conditionally safe (input side ABI-decoder-protected + output side bounded CBOR; wire contract depends on the f02 implementation check)**

**Basis**:

- **Input side (FPV posting)**: `postVolume`/`correctVolume`'s `FPV calldata` is Solidity ABI-decoded (compiler-generated decoder protects array bounds); `filPeriods.length` explicitly validated `≤ MAX_PRICE_PERIODS` (`TooManyPricePeriods`); `claimFil > 0` divide-by-zero guard requires before division (`ZeroClaimFil`, covered by CV1). **No handwritten decoding logic**.
- **Output side (setShares CBOR)**: the only f02 write interaction's params are `FVMRewards.trySetShares`'s handwritten assembly CBOR encoding — addresses are fixed-encoded as f410 22 bytes (`0x56 0x04 0x0a + 20 bytes`); share uint64 uses `writeCborUint64` length-branched encoding (1/2/3/5/9 bytes); the array header `writeCborArrayHeader` covers <24/≤255/≤65535 lengths; **encoding is bounded** (n ≤ 64, share ≤ 1e18 magnitude).
- **Return side**: the SRA does not parse f02 return values (setShares reads only the exit code); CBOR BigInt decoding only exists in `tryClaim` (used by the SWA, not called by the SRA), and `signByte`/`magLen > 32` guards with `revert(0,0)`.
- **Mock verifies the wire contract**: the test base etches a mock f02 + `CALL_ACTOR_BY_ID` routing; the mock validates Σ==1e18, ≤64 recipients, writer permission (`test_SubmitShares_MapSize_EqualsActiveOrchestrators`, `AutoFinalize_IncludesFilValue`, etc., tests §4.4.3).

**Residual risk/premise (protocol layer, not a contract defect)**:

- `FVMRewards.sol`'s header comment states explicitly: f02 **does not yet exist** (filecoin-project/builtin-actors#1764); the current wire format is this repo's **best-effort encoding of the FIP draft method signature, not upstream-confirmed ABI**. **Before launch, the wire contract must be checked against the final f02 implementation** (method number, CBOR field order, f410 address encoding, BigInt return format) — this is the largest premise risk on the SRA's security surface; it belongs to FIP ecosystem advancement and is not contract-logic-mitigable.

### 5.7 Precision Issues

**Conclusion: ✅ Safe (floor + largest-remainder, proof at the symbolic level)**

**Basis**:

- **Share allocation**: `_computeShares` gives each share `floor(usd_i × 1e18 / total)`, residue topped up +1 by remainder (`usd_i × 1e18 % total`) descending, guaranteeing `Σ shares == 1e18` **holds exactly** (hard f02 encoding constraint):
  - Halmos P1-P3 symbolic exhaustive proof of conservation (n=1/2/3, any usd combination Σ==1e18);
  - Halmos P4 monotonicity (larger usd gets ≥ share), P5 floor bound (each share ∈ {floor, floor+1});
  - forge 3/7/17-way split tests (I1) + G7 random fuzz (256 runs) double verification.
- **FIL→USD conversion**: `usd += attoFil × lotUsd / claimFil` integer multiply/divide (S9 rational rates, no floating point), covered by `test_FinalizeConversion_IntegerPrecision` (1000/3 non-divisible).
- **PRICE_BAND comparison**: cross-multiplication `lhs ≥ lower && lhs ≤ upper` avoids division precision loss (G3 exact ±20% boundary tests cover the boundary-inclusive semantics).

**Residual risk**: none substantive. The Halmos value-domain constraint is 1e3 — **this only certifies the share-allocation ratio properties** (shares depend only on usd ratios rather than absolute values); the no-overflow property over absolute magnitudes is now covered by the **entry-enforced input-domain bounds** (`_validateFpvBounds`, audit V1/V2/V3 fix) rather than by the 1e3-domain Halmos proof, which does not weaken the ratio-space coverage (012 report §C1 "value-domain constraint note") — proving over the full uint256 domain would require extended solver timeouts (significant cost, marginal benefit).

### 5.8 Governance Path

**Conclusion: ✅ Safe (three-phase + dual Safe + event traceability; re-admit semantics closed after T10)**

**Basis**:

- **unanimous three-phase**: submit (first vote `Submitted`) → approve (second vote completes `Approved`) → permissionless execution after the hold elapses; second approval does not re-execute; the same owner approving twice `AlreadyApproved` reverts; non-owner `NotOwner` reverts; hold not elapsed `HoldUntil` reverts (fully covered by `SRAGovernance` tests).
- **unanimousNoHold**: the second vote executes immediately (correctVolume; the window is the hold, D3).
- **_veto**: either Safe alone cancels a pending task (`cancelPending`, covered by `Veto_CancelsPendingAdmit`).
- **Task mutual exclusion**: parked governance targets are mutually exclusive (I3; `invariant_GovernanceTasks_Consistent` persistently verifies parked-not-landed / executed-clears-bitmask).
- **T10 defect closure**: `admit` identity reset (clears successor/frozen/freezeEpochs/unfreezeEpochs) — the boundary semantics of governance operations (replace→re-admit) are closed, guarded by 2 deterministic regression tests (R1/R2) + the A2 invariant (tests §4.3.5).
- **Timelock constant**: `SRA_CANCEL_HOLD` compile-time constant (constructor config; S6 const-ification reduces the governance attack surface).

**Residual risk/premises**:

- Dual-Safe private-key security (off-chain trust premise, same as category 3).
- `cancelPending` can only cancel **queued** tasks; already-executed tasks (e.g. an effective SetShares) cannot be revoked — f02's SetShares **binds immediately** (no quarter-window enforcement; the quarterly cadence is the SRA's own discipline, §2.5.6). If governance is compromised/mistaken, shares take effect immediately; mitigation: dual Safe + hold already substantially reduce this risk, and shares only affect service-stream allocation (can be overwritten by next quarter's correct values), not direct fund loss.

### 5.9 Front-Running

**Conclusion: ✅ Safe (deterministic snapshot semantics + no MEV value)**

**Basis**:

- **E+POST snapshot semantics (S5)**: freeze determination uses the `freezeEpochs`/`unfreezeEpochs` history arrays + paired-interval search (`_frozenAtPostEnd`/`_isFrozenAt`) — **derivable at any point, independent of keeper call timing** (§2.5.2). `submitShares` results are deterministic; there is no "submit before the freeze" or "delay until after unfreeze" front-running window; snapshot positive/negative tests (`FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` / `UnfrozenAtPostEnd_FrozenInWindow_StillIncluded`) + the A2 invariant cover it.
- **Permissionless triggers have no privilege**: `finalizeConversion`/`submitShares` callable by anyone with identical results (idempotent: finalize idempotent, repeated submitShares rewrites the same shares) — zero front-running gain, no MEV.
- **Read auto-triggers conversion (T11/A aligned)**: `aggregatedFPV` after binding auto-triggers the idempotent `finalizeConversion` on read (aligned with spec §3.2/§4.1/§4.2) — returns the complete USD value with no divergence from `submitShares`'s final value; the conversion is idempotent, result independent of call timing, not observable-manipulable.
- **PRICE_BAND anchored reference (T11/D aligned)**: band validation is against the "qualifying print of the previous quarter's binding final state" (anchor, updated at finalize, fixed within the quarter) — prevents chained stepping of multiple prints within a single postVolume (each just inside the band) from pushing the reference arbitrarily far (×1.199³²≈218×); with an anchor the push rate is band/quarter with a verification-window correction opportunity.
- **MIN_LOT filtering (T11/B aligned)**: prints below MIN_LOT do not participate in pricing (band check skipped, never become the reference, not counted in finalize) — prevents dust lots (competitive bids fail on dust; Dutch-style prices may fall far below fair value) from polluting the pricing anchor (spec §3.3 qualifying-print semantics).

**Residual risk**: none substantive. An attacker can at most execute early an operation "that would execute anyway" (eventual consistency), changing no participant's share result.

### 5.10 Toolchain Verification Evidence (t7 Slither + t8 Halmos)

> Full report: `.ghost/references/012-sra-toolchain-verification.md` (incl. run commands, parameters, value-domain decisions).

#### Slither (B1): zero real risk

- Scanned 9 contracts × 102 detectors (`--exclude-dependencies`), result **0 high / 0 medium**, only 2 style-class findings:
  - `assembly` × 4 (`_registry`/`_lists`/`_quarter`/`_params` ERC-7201 storage-slot access) — **intentional design**, standard ERC-7201 practice, not a risk;
  - `naming-convention` × 5 (immutable uppercase constants) — Solidity convention, not a risk.
- Not triggered: reentrancy / unchecked / integer-overflow / tx.origin / delegatecall risk detectors.

#### Halmos (C1): 6/6 symbolic verification PASS

- Target: `_computeShares` (largest-remainder method, pure function).
- Properties: conservation (n=1/2/3, Σ==1e18) ✅ | monotonicity (larger usd gets ≥ share) ✅ | floor bound (each share ∈ {floor, floor+1}) ✅ | no overflow (business domain) ✅.
- Run: 前置 `forge build --ast`（forge 1.7+ 默认不为 test 合约输出 AST；halmos 0.1.13 读 out/ 需要 ast 字段），然后 `halmos --contract ComputeSharesCheck --no-test-constructor --loop 64 --solver-timeout-branching 2000 --solver-timeout-assertion 60000`, ~125s. 完整命令见 §4.5.
- **Value-domain note**: symbolic domain 1e3 (shares depend only on usd ratios; equal scaling does not change allocation, so the ratio space is fully covered; 012 report §C1 details the 1e40→1e3 tightening process and SMT-solving trade-offs).

#### State-machine verification (quarter windows): 4/4 PASS

- Target: `test/halmos/QuarterWindowCheck.sol` — 4 parameter-independent propositions (T2a/T3/T4/T5b), see §4.3.8.

### 5.11 Handled Defects and Same-Pattern Residual Risk Checklist

> Honest presentation: during SRA development the toolchain/tests caught **2 real implementation defects** (T6, T10), both TDD-fixed with regression tests left behind. The following checklist is for future reviewers to focus on re-checking **the same patterns**.

#### Handled defects

| # | Defect | Root cause | Fix | Regression guard |
|---|--------|------------|-----|------------------|
| **T6** | `registerPairs` bypasses binding uniqueness | the AlreadyBound check uses `_isAdmitted(current)` instead of `_resolve(current)` — after replace the binding still points to the old address (admitted=false), so a third party can grab the binding pair | 1-line fix `_isAdmitted(_resolve(current))` | `test_RegisterPairs_AfterReplace_ThirdPartyReverts` + `invariant_OneBindingPerPair` |
| **T10 (A2)** | a frozen orchestrator obtains a share through the resolve chain | `replace(old→new)` sets `old.successor = new` → re-`admit(old)` leaves successor residual → `submitShares`'s freeze check targets old itself (not frozen, passes) but the wallet resolves to the frozen new | `admit` identity reset (clears successor/frozen/freezeEpochs/unfreezeEpochs, symmetric with remove cleanup); invariant handler synced | R1/R2 regression + A2 invariant (exposed by random failure at t7/t8 acceptance; stable for 2 rounds after the fix) |

#### Same-pattern residual risk checkpoints (for future reviewers)

1. **remove then re-admit**: ✅ safe (double protection) — `remove` already clears successor/frozen/freeze history, `admit` resets again; semantics = fresh identity.
2. **replace chain length**: ⚠️ theoretical DoS — `_resolve` resolves along the successor chain with a while loop; chain length has no hard cap (naturally constrained by governance frequency); recommend evaluating a chain-length cap (see §5.3).
3. **freeze × replace interaction**: ✅ semantics defined — `replace` copies old's frozen state and freeze history to new (identity transfer, covered by `test_Replace_TransfersIdentity`); frozen state follows the identity, consistent with S5 snapshot semantics.
4. **replace then re-admit (T10 main defect pattern)**: ✅ fixed — `admit` identity reset cuts the residual chain; regression tests R1/R2 guard it.
5. **freeze-history array growth**: ⚠️ theoretical growth point (see §5.3), constrained by governance frequency; current magnitude negligible.

#### Coverage and statistics notes

- SRA line coverage **100%**, statements 99.45%, functions 100%; branch 67.16% (`forge coverage`) is the **tool's statistical ceiling** — require branches of governance function bodies with the `unanimous`/`unanimousNoHold` modifier are all recorded as 0 in lcov (including remove NotAdmitted / reassignBinding NotAdmitted / replace AlreadyAdmitted / setPricingParams InvalidParameter, which G6 explicitly tests); an lcov quirk for modifier-inlined function bodies, **not a real gap** (detailed in §4.3.3).
- Full suite **253/253 Green** (104 SRA deterministic + 5 invariant + 144 existing); 5 invariants (share conservation / binding uniqueness / governance consistency / A2 freeze snapshot / A3 all-zero burn); `.gas-snapshot` gas baseline committed (E1).

### 5.12 Pre-Launch Prerequisite Checklist

> Final confirmations for deployment/launch (mostly protocol-layer / off-chain premises, not contract defects):

- [ ] **f02 wire contract check**: `FVMRewards`'s CBOR encoding (method number/field order/f410 address/BigInt return) matches the final f02 implementation (§5.6's largest premise).
- [ ] **Deployment parameters**: EPOCHS_PER_QUARTER / POST_PERIOD / VERIFICATION_WINDOW / SRA_CANCEL_HOLD / ACTIVATION_EPOCH set per mainnet config; MIN_LOT / PRICE_BAND / MAX_PRICE_PERIODS governance-initialized sensibly.
- [ ] **Dual Safe addresses**: confirm real Safe proxies (constructor `isProbablyASafe` check); private keys held by distinct entities.
- [ ] **service stream 2 registration**: f02-side stream 2's writer points to the SRA address (the mock simulates this flow; tests §4.4.3).
- [ ] **replace chain length and freeze-history growth monitoring**: if governance frequency rises significantly, evaluate adding hard caps (§5.3 residual risk).

### 5.13 Threat Model Matrix (S4, adversarial-internal-party coverage)

> **S4 fix**: the previous threat model covered only "honest-but-faulty" callers; V1/V2/V3 showed the missing dimension — a **malicious / compromised internal party** (an admitted orchestrator, or a compromised owner) must be in scope. For each external write function: threat party × impact × mitigation × sufficiency.

| Function | Threat party | Impact | Mitigation | Sufficient? |
|----------|--------------|--------|------------|-------------|
| `registerPairs` | malicious orchestrator | binding spam / pair squatting (uniqueness keeps 1-pair-1-owner) | `MAX_PAIRS(64)` batch bound + `NotAdmitted`/`NotFrozen` gates; `AlreadyBound` uniqueness; pairs claimable after Remove | ✅ (data hygiene; no value at stake) |
| `postVolume` | malicious orchestrator | extreme FPV → overflow DoS (V1/V2/V3); band deviation | `_validateFpvBounds` (4 field bounds + claimFil>0) at entry `:351`; `_checkPriceBand` vs anchored reference (deviation ≤ band); `TooManyPricePeriods`; `AlreadyPosted` once-per-quarter | ✅ (bounds + band both enforced in code; S1 adversarial suite locks 28 edges) |
| `admit` / `remove` | compromised owner | arbitrary orchestrator admission/removal | unanimous dual-Safe + hold (3-phase); `MAX_ORCHESTRATORS(64)`; re-admit identity reset (T10) | ✅ (needs both Safe keys — private-key security is a protocol premise) |
| `freeze` / `unfreeze` | compromised owner | suspend/restore orchestrator; freeze keeps slot (D2) | unanimous + hold; freeze-history arrays enable `_frozenAtPostEnd` snapshot | ✅ |
| `replace` | compromised owner | identity transfer (frozen state + bindings) | unanimous + hold; alias chain (`_resolve`) keeps binding resolution correct; re-admit reset | ✅ |
| `reassignBinding` | compromised owner | disputed-pair reassignment | unanimous + hold; target must be admitted | ✅ |
| `replaceOwner` | compromised owner | owner rotation | unanimousNoHold (immediate) + `isProbablyASafe`; `CannotRemoveLastOwner` protects the last owner | ✅ (E1 added; rotation only, n-of-n loss is a protocol premise) |
| `setAdmittedLists` / `setPricingParams` | compromised owner | allowlist / pricing-parameter manipulation | unanimous + hold; `MAX_ALLOWLIST(64)`; pricing bounds (`minLot ≤ MAX_LOT_USD`, `priceBand ≤ BASIS_POINTS`, `maxPricePeriods > 0`) | ✅ |
| `cancelPending` | compromised owner | veto queued change | `_veto` requires `msg.sender.isOwner()` | ✅ |
| `correctVolume` | compromised owner | overwrite posted volume (governance path into FPV) | unanimousNoHold + in-body `_inVerificationWindow`; same `_validateFpvBounds` as postVolume (A1) | ✅ (bidirectional correction by design, D3a) |
| `finalizeConversion` | external caller | trigger conversion early? | `_afterBinding` gate (E+POST+VERIFY); idempotent; permissionless → no privilege/MEV | ✅ |
| `submitShares` | external caller | trigger share settlement | `_afterBinding` gate; permissionless; frozen snapshot from E+POST instant (timing-independent); all-zero → burn (D1) | ✅ |

**S4 conclusion**: every external write function is closed against a malicious internal party — either by unanimous dual-Safe governance (owner surface), or by code-enforced input bounds + timing gates (orchestrator surface). The only residual exposures are protocol-layer premises (dual-Safe private-key security; f02 wire contract), not contract-layer vulnerabilities.

### 5.14 Reviewer Checklist (S5, challenge-the-premise)

> **S5 fix**: review PASS must no longer default-trust a document's "Safe" mark — the checklist forces the reviewer to verify each claim's premise is enforced in code.

- [ ] **S5.1 — Security-claim → code map**: for every "Safe"/"Conditionally safe" conclusion in §5.1, the cited code-enforcement point must exist and match the claim (no enforcement reference = review fails). The §5.1 table is the map; verify at least rows 2/3/4 against the source.
- [ ] **S5.2 — Evidence conditions**: every verification evidence (Halmos symbolic domain, fuzz sampling domain, invariant bound) must have its applicability condition annotated, and the condition must be satisfied by the code (e.g. the fuzz domain `(0,1e30)` equals the enforced `MAX_STABLE_USD`; the Halmos `1e3` symbolic domain is a proportional-space proof with the absolute domain covered by §5.5 domain-math bounds). A proof whose premise is not code-enforced is inadmissible (§5.5 row 4, §4.3.8 S3 note).
- [ ] **S5.3 — Adversarial internal party**: the threat matrix (§5.13) must include the malicious-orchestrator and compromised-owner parties for every external write function; a function missing from the matrix is a review finding.
- [ ] **S5.4 — Adversarial input coverage**: the S1 adversarial suite must cover every external write function's numeric/address/array parameters at their boundary values (0 / 1 / limit / limit+1 / max / zero-address); a parameter class not exercised at its boundary is a review finding.
- [ ] **S5.5 — Test-claim correspondence**: every test asserted in §4 must be runnable and green; a test whose assertion cannot be invalidated (e.g. bare `expectRevert`) does not count as coverage.
- [ ] **S5.6 — Regression after hardening**: any new audit finding (V1/V2/V3-style) must first add a Red regression test, then fix, then re-run the full suite (295 SRA+existing + 5 invariant, incl. the 28-test adversarial matrix) — no finding is closed by documentation alone.

## 6. References

- 📄 `.ghost/spec/001-fip-0118-spec.md` (FIP-0118 technical spec, §3.2/§3.3/§4.2/§5/§11; agent-internal, not committed)
- 📘 `docs/f02-design.md` (f02 design: SetShares immediate binding, pull settlement, MAX_RECIPIENTS=64, Σ=1e18)
- 📘 `src/lib/UnanimousGovernance.sol` (unanimous/unanimousNoHold/_veto), `Owners.sol`, `Epoch.sol`, `PendingTask.sol` (ERC-7201 precedents, Epoch type), `IsASafe.sol` (Safe proxy validation incl. stripped support)
- 📘 `src/lib/FVMRewards.sol` + `FVMRewardTypes.sol` + `FVMRewardMethod.sol` (trySetShares, Share, SET_SHARES=2414422607)
- 📘 `src/StreamWeightActor.sol` (upstream swa branch — reference implementation precedent: thin contract + library delegation + unanimousNoHold; not part of this commit)
- 📘 `test/mocks/FVMRewardActor.sol` + `MockRewardTest.sol` (mock validation semantics), `test/mocks/FVMCallActorByIdWithReward.sol`
- 📘 `test/StreamWeightActor.t.sol` (upstream swa branch — Safe owner construction / mock driving precedents; not part of this commit)
- 🔍 `.ghost/references/008-sra-risk-assessment.md` (D1-D5/I1-I5/R1-R4 risk analysis; agent-internal, not committed)
- 🔍 `.ghost/references/009-sra-design-implementation-details.md` (design implementation details + source annotations; agent-internal, not committed)
- 🔍 `.ghost/references/011-sra-handover.md` (process handover; agent-internal, not committed)
- 🔍 `.ghost/references/012-sra-toolchain-verification.md` (t7 Slither + t8 Halmos full report; agent-internal, not committed)
- 🔍 `.ghost/references/013-sra-spec-conformance.md` (spec-conformance matrix, deviations A-E; agent-internal, not committed)
- 🔍 `.ghost/references/014-differential/` + `014-sra-differential.md` (differential reference model + report; agent-internal, not committed)
- 🔍 `.ghost/references/015-sra-statemachine-verification.md` (state-machine symbolic verification report; agent-internal, not committed)
