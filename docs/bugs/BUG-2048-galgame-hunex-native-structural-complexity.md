## BUG-2048 · HUNEX 原生适配层 9 处结构性复杂度待清（认知复杂度 55/44/43/40/35、24 字段类、13/12/8 参函数）
- **报告**：2026-09-02（合并 PR#1116 时按用户决策记账，不阻塞合入）
- **真实性**：✅ 真问题，但不是缺陷——是新代码的可维护性欠账。SonarCloud 在 PR#1116 上报出：
  - `cpp:S3776` 认知复杂度超限 5 处：
    - `native/galgame_hook/hook/adapters/hunex_gge_lookup_core.h:301`（55，限 25）
    - `native/galgame_hook/hook/adapters/hunex_gge_selected_text.h:240`（44）
    - `native/galgame_hook/hook/adapters/hunex_gge_lookup_core.h:199`（43）
    - `native/galgame_hook/hook/adapters/hunex_gge_capture_bridge.h:443`（40，`SubmitGlyphInternal`）
    - `native/galgame_hook/hook/adapters/hunex_gge_lookup_core.h:700`（35）
  - `cpp:S107` 参数过多 3 处：`hunex_gge_capture_bridge.h:443`（13 参）、`:187`（12 参，`SubmitGlyphWithLine`）、`hunex_gge_lookup.h:850`（8 参）
  - `cpp:S1820` 字段过多 1 处：`hunex_gge_capture_bridge.h:111`（`TraversalCaptureBridge` 24 个成员，限 20）
- **为什么没有随 PR#1116 一起修**（用户 2026-09-02 决策）：
  1. **修了也翻不了盘**。实测该 PR 新代码总技术债 9684 分钟，这 9 处合计 237 分钟 = **2.4%**；`cpp:S8417` 一条就占 8100 分钟 = **83.6%**，是 `new_maintainability_rating` 从 1 掉到 2 的唯一实质原因。
  2. **S8417 对这段代码的建议本身是错的**。它要求把显式 `memory_order` 一律换成 `seq_cst`，而 `native/galgame_hook` 的共享内存是真无锁结构：`hunex_gge_capture_bridge.h` 顶上就是 `static_assert(std::atomic<uint32_t>::is_always_lock_free)`，槽位发布走 `compare_exchange_strong(acq_rel, acquire)` + release/relaxed store，`voice_hook_ipc.h` 的 admission 字是 seqlock。acquire/release 在这里是**语义**（标明哪一对读写构成 happens-before），不是随手写的优化。
  3. **规则级屏蔽在本仓做不到**。见 `.sonarcloud.properties` 里记的实验：Automatic Analysis 不认 `sonar.issue.ignore.*`。
  4. 参数打包会改 `SubmitGlyphInternal` / `SubmitGlyphWithLine` 的公开签名，涟漪到原生测试与 `hunex_gge_adapter.inc`；塞进一条已经 9500 行、且引擎侧 `implemented_unverified`、无 E2E 的 PR 里是额外风险。
- **[ ] ① 未修复** — 建议单开一条 PR 做，且按风险从低到高分批：先 `cpp:S1820`（把 `TraversalCaptureBridge` 里单线程独占的 active-traversal 暂存态归到一个嵌套结构，原子成员不动）→ 再 `cpp:S107`（把每字形/每行/精确行三组参数各打成一个结构体）→ 最后 `cpp:S3776`（纯函数提取）。每一步都用 MSVC 本地编 + 跑 `hunex_gge_capture_bridge_test` / `hunex_gge_lookup_test` / `hunex_gge_selected_text_test` 把关（`/utf-8 /EHsc /std:c++17 /O2 /DNDEBUG`，注意必须带 `/utf-8`，否则 codepage 936 会把中文注释误解成续行）。
- **[ ] ② 未加自动化测试** — 重构是行为保持的，覆盖面由上述三个原生测试提供；本条不需要新增守卫。
- **备注**：合入 PR#1116 时 Sonar 的可靠性与安全性评分均为 1（干净），只有可维护性为 2。这也是本仓最近连续 5 条合入 PR（#1119/#1134/#1127/#1126/#1122）里第一条 Sonar 非 OK 的合入，破例依据即上面四条。