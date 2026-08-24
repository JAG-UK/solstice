# id 身份模型 × mirror 重构融合实现方案

## 1. 目标和核心功能

### 目标

在 `sra@b521e61`（已含全部 review 修复：A3 三态 submitShares、B1 守卫+一步跳转、S1 remove 排除语义、时间驱动化 `_quarterOf`/`_syncMirror`/`_pendingSharesQuarter`）基础上，将 SRA 身份模型从"address 即身份 + successor alias 链"改为 **uint64 内部 id 即身份 + activeIdOf 地址重映射**。**mirror 层（季度数据组织：activeQ/lastSubmittedQ/totalUsd/fpv/prevFpv/frozenSince/frozenAtPostEnd）必须保留不动**，本次只重构身份层。

参考源材料（磁盘上早期实现 实现，基于旧基线）：`/tmp/ghost-worktrees/refactor/sra-orch-id/`。

### 核心功能

- replace = **O(1) wallet 重映射**（activeIdOf 重映射 + wallet 更新），删除基线"复制 OrchestratorInfo"逻辑；历史季度 FPV 天然跟随 id
- re-admit（remove/replace 后同地址） = **新 id fresh identity**，零清理逻辑，T10 缺陷类从结构消除
- remove 惰性清理 bindings（bindings 按 id 存，认领时查 `orchestrators[id].admitted`）
- 删除 `_resolve`/`successor` 全部链逻辑（字段 + 辅助函数 + 3 个调用点：registerPairs/submitShares/bindingOf）
- 外部 ABI（方法签名、事件）不变；mirror 语义不变

## 2. 技术方案

### 2.1 技术栈

Solidity 0.8.36 + Foundry（forge test/fmt/lint）、halmos（symbolic verification，本次**无需改动**）。仓库不变。

### 2.2 技术选型与关键决策

**决策依据（源自 sra-pr24 review 结论 + 本方案核验）：**

| 决策点 | 结论 | 理由 |
|---|---|---|
| 身份模型 | **uint64 内部 id**（弃 alias 链） | alias 链的 T10 缺陷类（replace 后 re-admit 残留链致冻结者获份额）是结构性影子——任何实现都必须在 admit 防御；id 方案从结构消除。新基线已通过"replace 复制贡献槽 + admit fresh identity 兜底"实现部分收益，但保留链 = 保留结构性风险 |
| mirror 层 | **完全保留不动** | mirror 是季度数据组织（fpv/prevFpv/totalUsd），id 是身份组织（wallet→id），两者**正交**；id 融合后 replace 还能删掉基线"复制贡献槽"逻辑（数据天然跟随 id），比基线更简化 |
| replace 语义 | O(1) 重映射，历史季度 FPV 保留 | 与基线"复制贡献槽"行为目标一致（S13 决策已记录），实现更简 |
| ABI | 不变 | 方法签名/事件保持 address 语义（FIP 规格），id 是纯内部实现细节 |

**排除方案：** ① 保持 alias 链（基线现状）——T10 结构性风险仍在；② 在新基线上重放早期实现 diff——存储模型已分叉（冻结数组→frozenSince 标志、fpv mapping→实体槽），文本冲突是表象、语义冲突是实质，必须按新存储模型重做而非搬 diff。

### 2.3 存储结构设计（核心决策）

`src/lib/SraStorage.sol` 改造（namespace 常量不变）：

```solidity
struct OrchestratorInfo {
    address wallet;       // 当前有效地址（replace 更新；submitShares 写这个）— 20B
    bool admitted;        // admitted — 1B
    bool frozenAtPostEnd; // mirror 快照标志（保留基线语义）— 1B
    Epoch frozenSince;    // 当前冻结状态（保留基线语义）— 8B
    // 30B 打包进 slot0。与基线同为 3 slots/实体：基线是 admitted/frozenAtPostEnd/frozenSince/successor
    // （30B 全部打包 slot0，无 successor 独占槽）+ fpv + prevFpv；id identity 是 successor → wallet 的字段等量替换
    // （30B 打包 slot0）+ fpv + prevFpv —— 不省 slot，而是去掉 successor 链字段本身（id 模型无需链）。
    FixedU18 fpv;         // mirror 活跃季度贡献（保留）— slot1
    FixedU18 prevFpv;     // mirror 前季度贡献（保留）— slot2
    // successor 删除
}

struct SraStorageRegistry {
    mapping(uint64 id => OrchestratorInfo) orchestrators; // slot0 — id 是身份（单调递增、不重用）
    mapping(address orch => uint64 id) activeIdOf;        // slot1 — 0 = 未注册哨兵
    mapping(bytes32 pairId => uint64 id) bindings;        // slot2 — 存 id（替代 address）
    uint64 nextId;                                        // slot3 — id 分配器（构造器置 1）
    uint64[] admittedIds;                                 // slot4 — 可枚举 admitted（替代 admittedList address[]，length 即 count）
    // admittedCount 删除（admittedIds.length 派生，与基线一致）
}

struct SraStorageQuarter { /* 不变：activeQ / lastSubmittedQ / totalUsd */ }
```

**id 单调性测试的 slot 偏移**（测试侧读 `REGISTRY_SLOT + 3` 取 nextId 低 64 位；早期实现 是 `+3` 高 64 位因 admittedCount 打包，新布局 nextId 独占 slot3 低 64 位）。

### 2.4 方法改造清单（逐一列出）

| 方法 | 改造 | mirror 相关逻辑 |
|---|---|---|
| 构造器 | 追加 `_registry().nextId = 1` | — |
| `_advanceMirror` | 遍历 `r.admittedIds`（uint64[]），`o = r.orchestrators[r.admittedIds[i]]` | **保留**（prevFpv 快照/fpv 清零/frozenAtPostEnd 复位） |
| `registerPairs` | `id = activeIdOf[msg.sender]`；`require(id != 0 && o.admitted)`；唯一性改 `boundId != 0 && orchestrators[boundId].admitted`（**无 _resolve**）；`bindings[pairId] = id` | — |
| `postVolume` | id 解析（`activeIdOf[msg.sender]`） | **保留**（advance 触发/fpv 实体槽/AlreadyPosted/MAX_FPV_USD/totalUsd） |
| `admit` | `require(activeIdOf[orch] == 0, AlreadyAdmitted)`；`require(admittedIds.length < MAX, AtCapacity)`；`id = nextId++`；新实体 `wallet=orch; admitted=true`（其余零，天然 fresh）；`activeIdOf[orch]=id; admittedIds.push(id)` | — |
| `remove` | `id = activeIdOf[orch]`；`require(id != 0 && o.admitted)`；**保留归档 id 记录**（wallet/fpv 供审计），`o.admitted=false`；`activeIdOf[orch]=0`；`_swapRemove(admittedIds, id)` | **保留**（pending 守卫/镜像扣减 `!frozenAtPostEnd && fpv>0`） |
| `freeze`/`unfreeze` | id 解析 | **保留**（frozenSince/frozenAtPostEnd/totalUsd 扣减与恢复） |
| `replace` | **核心改造**：`id = activeIdOf[oldOrch]`；require admitted；`require(activeIdOf[newOrch] == 0, AlreadyAdmitted)`；`activeIdOf[oldOrch]=0; activeIdOf[newOrch]=id; orchestrators[id].wallet=newOrch`；**删除基线整块"复制 OrchestratorInfo"逻辑**（fpv/prevFpv/frozenSince/frozenAtPostEnd 跟随 id，不复制不迁移）；admittedIds 不动 | — |
| `reassignBinding` | `id = _requireAdmittedId(orch)`；`bindings[pairId] = id` | — |
| `correctVolume` | id 解析 + `_requireAdmittedId`；frozenSince 检查在 id 实体 | **保留**（advance/fpv 覆盖/totalUsd 调整/NotFrozen 约束） |
| `submitShares` | 遍历 `admittedIds`；`o = r.orchestrators[admittedIds[i]]`；**`wallets[count] = o.wallet`（无 _resolve）** | **保留**（usePrev 判定/frozenAtPostEnd 过滤/prevFpv 读取/all-zero no-op/lastSubmittedQ 防重放） |
| `aggregatedFPV` | **无改动**（totalUsd[q] O(1)） | 保留 |
| `bindingOf` | `id = bindings[pairId]`；`return id == 0 ? address(0) : orchestrators[id].wallet`（**无 _resolve**；unbound 显式返 0） | — |
| `fpvOf` | `id = activeIdOf[orch]`；`id == 0 → return FPV({usd: 0})`；否则读 id 实体 | **保留**（q==activeQ 读 fpv / q==activeQ-1 读 prevFpv / 更早返 0） |
| `isAdmitted` | `id = activeIdOf[orch]; return id != 0 && orchestrators[id].admitted` | — |
| `isFrozen` | `id = activeIdOf[orch]; return id != 0 && !(orchestrators[id].frozenSince == Epoch.wrap(0))` | — |
| `admittedCount`/`orchestratorCount` | `uint64(r.admittedIds.length)` | — |
| `_requireAdmittedId` | **保留**（id 解析辅助：`id != 0 && admitted`，revert NotAdmitted） | — |
| `_resolve` | **删除**（调用点 registerPairs/submitShares/bindingOf 已改为直接 id/wallet 读取） | — |
| `_swapRemove` | 签名 `address[] → uint64[]`（实现逻辑不变） | — |
| `_pairId` | 不变 | — |

**唯一外化行为**（与基线一致、与 FIP 文本对齐）：replace 后历史季度 FPV 保留（fpv 按 id 存）——基线靠"复制贡献槽"实现，id identity 靠"id 不动"实现，行为目标相同。

### 2.5 测试计划

#### 新增 5 个行为锁定测试（移植早期实现，mirror 语义适配）

helper 命名与新基线测试基类一致（`_admit/_postAs/_rollTo/_qEnd/_qPostEnd/_qVerifyEnd/_correctVolume/_fpv/_pair/_registerPairsAs/_walletShare/_sumShares`，见 `test/SRATestBase.sol`），早期实现 测试几乎原样可移植。

| 测试 | 文件 | 断言要点 | mirror 适配 |
|---|---|---|---|
| `test_Replace_HistoricalQuarterFPV_Kept` | SRAShares | post q0 → replace → submit q0：newOrch 得 1e18、`aggregatedFPV(0)==100e18` | 直接成立（fpv 按 id 存，submitShares(0) usePrev=false 读 fpv） |
| `test_Replace_ShareMap_WritesNewWallet` | SRAShares | 双 orchestrator 各 50 → replace → newOrch 5e17、oldOrch 0、Σ==1e18 | 直接成立 |
| `test_Replace_CorrectVolume_NewAddress_CorrectsHistoricalQuarter` | SRAShares | post 100 → replace → correctVolume(newOrch,0,200) → submit：200 生效 | 成立（activeQ==0 不 advance，`o.fpv=200; totalUsd[0]=+200-100`） |
| `test_ReAdmit_FreshIdentity_NoBindingsNoFPV` | SRARegistry | remove → re-admit：pair 可被第三方认领、fpvOf 空 | **fpvOf 断言改**：旧 `!f.posted` 删（新 FPV 仅 usd 字段），断言 `usd == 0` |
| `test_Admit_IdMonotonic_NeverReused` | SRARegistry | nextId 从 1、每次 admit +1、re-admit 不重用 | **slot 计算改**：`REGISTRY_SLOT + 3` 低 64 位 = nextId（不再有 admittedCount 打包） |

#### 保留并更新注释的既有测试

- `test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares`（SRAShares T10 回归）：断言**不变**（newOrch 冻结 0 份额、oldOrch 1e18），注释从"admit identity reset 清链"更新为"re-admit = 新 id，无链可解析"。
- SRARegistry 既有 replace 测试（`test_Replace_TransfersIdentity` / `test_Replace_AlreadyAdmittedTarget_Reverts` / `test_Replace_OldNotAdmitted_Reverts`）：断言需逐一核对——TransfersIdentity 若断言"复制"语义（frozen 转移/历史转移），id 方案下语义等价（跟随 id）但测试内部构造可能依赖 address 键控，tester 核对并同步。

#### invariant handler 改造（移植早期实现 generation 机制）

新基线 handler（`test/SRAInvariant.t.sol`）用 `_successor` 映射模拟 replace 链（4 处：128/154/207-208/356 + resolveHandled 430-431）；id identity 融合后改为 **generation 代际机制**（早期实现已验证，移植）：

1. 删 `mapping(address => address) _successor` → 加 `mapping(address => uint256) _idGen` + `uint256 _genSeq`
2. `PairRecord` 加 `uint256 gen`（绑定时代际）
3. `admit`：`_genSeq++; _idGen[orch] = _genSeq`（替换 `_successor[orch]=0`）
4. `remove`：删 `_successor[orch]=0` 行（id 方案无链可清）
5. `replace`：`_idGen[newOrch] = _idGen[oldOrch]`（同代际转移）；pairs 迁移**仅当前代际**（`boundOrch==oldOrch && gen==_idGen[oldOrch]` → `boundOrch=newOrch`，归档身份的 pair 不迁）；`_frozen[newOrch]=_frozen[oldOrch]` 与冻结历史迁移（`_freezeAt/_unfreezeAt`）保留——handler 的冻结模拟是业务语义期望值，与 id 无关
6. `_claimable`：改代际判定——`!_admitted[p.boundOrch] || _idGen[p.boundOrch] != p.gen` → claimable
7. `_setBound`：记录 `gen: _idGen[orch]`
8. I2 invariant：期望值从 `resolveHandled(boundOrch)` 改为 **`boundOrch` 直接相等**（handler replace 已把当前代际 pair 的 boundOrch 同步到新 wallet，与链上 `bindingOf` 返回一致）；`resolveHandled` 函数删除
9. `completeParked` 成功分支：`_genSeq++; _idGen[orch] = _genSeq`

handler 的 `_snapshotPostEnd`/`_isFrozenAtHandled`/`_claimable`（读链上 `sra.fpvOf/bindingOf/isAdmitted` 的部分）**不需要改**——它们经链上接口读值，天然适配 id 模型。

#### halmos：无需改动

新基线 `test/halmos/QuarterWindowHarness.sol` 只验证窗口纯函数（`_qEnd/_inPostingWindow/_inVerificationWindow/_afterBinding`），与身份模型无关（mirror 重构已删除冻结区间判定函数）。**与早期实现 不同**（早期实现 需改 harness 冻结判定），本次零改动。验证：`halmos` 跑 QuarterWindowCheck 全绿。

### 2.6 风险与边界

| 风险 | 等级 | 说明与对策 |
|---|---|---|
| **全零季度 bug**（他人并行修复中） | 🟡 | 修复改动集中在 `submitShares`/`_pendingSharesQuarter`（advance 触发条件），与 id identity 的 submitShares 改动（遍历 admittedIds + wallet 读取）同函数不同段。实施时若修复分支已合入，以合入后代码为基线 rebase；本重构 **不修**该 bug |
| **体积 EIP-170** | 🟡 | 基线 runtime 23,938B（余量 638B，`forge build --sizes` 实测）。id identity 融合（每方法 id 解析 + activeIdOf SLOAD）预计 +1~1.5KB，**可能超 24,576B**。对策：仓库既定合约拆分路径（docs/sra-design.md §5.12 #5：logic-to-library / proxy split）；实施时实测，超限则标注为已知问题 |
| namespace 不变 + 布局变 | 🟢（文档） | 破坏性存储变更，不支持原地升级；S13 决策记录补充声明（参照早期实现 S13） |
| 归档 id 数据可达性 | 🟢（文档） | remove 后 activeIdOf 清 0，`fpvOf` 不可达归档 id（仅 `bindingOf` 可读归档 wallet）；S13 注明归档数据仅链下（事件/索引器）可审计 |
| nextId 溢出 | 🟢 | uint64 递增，0.8.x checked arithmetic revert（治理频率不可达） |
| `_swapRemove` 边界 | 🟢 | 空数组/末位元素逻辑不变（循环查找 + pop），仅类型改 uint64 |

## 3. 验收方案

### 3.1 验收标准与验收步骤

1. **构建**：`forge build --sizes` → 编译干净；记录 ServiceRewardsActor runtime 体积（超 24,576B 则标注为 §5.12 已知问题，由合约拆分解决）
2. **单元测试**：`forge test` → 全绿（基线 303 + 新增 5 = 308 passed；T10/SRARegistry replace 系列语义同步后无失败）
3. **invariant fuzz**：`forge test --match-contract SRAInvariant` → I1/I2/I3/A2/A3 全绿（handler generation 改造后）
4. **halmos**：halmos 跑 `QuarterWindowCheck` → 全绿（零改动应保持通过）
5. **格式与 lint**：`forge fmt --check` + `forge lint --deny notes` → 通过
6. **行为锁定**：5 个新测试真实锁定核心外化行为（replace 历史季度连续性、share map wallet 指向、correctVolume 新地址语义、re-admit fresh identity、id 单调性）

## 4. 参考资料

- 早期实现 实现（id 方案参考，基于旧基线）：`/tmp/ghost-worktrees/refactor/sra-orch-id/`（src/ServiceRewardsActor.sol、src/lib/SraStorage.sol、test/SRAInvariant.t.sol generation 机制、test/SRAShares.t.sol + SRARegistry.t.sol 5 个测试）
- 新基线：`src/ServiceRewardsActor.sol`（757 行）、`src/lib/SraStorage.sol`、`test/SRAInvariant.t.sol`（700 行 handler）
- 设计文档：`docs/sra-design.md`（不含 S13；本次实施补充 S13 决策记录，参照早期实现 的 S13 段落改写以匹配 mirror 语义）
