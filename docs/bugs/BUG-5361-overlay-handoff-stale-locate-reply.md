## BUG-5361 · 覆盖窗转交高级制卡：定位往返途中手动查别的词，旧回包仍开对话框
- **报告**：2026-11-24（外部审查报告 HBK-AUDIT-003 P2，针对 #4296 覆盖窗转交主窗高级制卡）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/pages/implementations/home_dictionary_page.dart`（修前）：`_onResultRendered` 只在向 WebView 请求词条下标**之前**核对查询代（:531），`_openHandedOffAdvancedMining` 回包后只核 `identical(_pendingAdvancedMining, handoff)`（:560）；手动查词 `_search` 铸新代（:1948 `++_searchGeneration`）/ `_resetQuery`（:768）不动 `_pendingAdvancedMining`，所以同一个 handoff 对象还在，旧回包照样用旧 DOM 下标打开对话框，下标可能落到新结果的另一个词条上。顺带：旧回包被判作废时不看往返途中来过的渲染信号，新转交那次的 `popupRendered` 会被吞掉）
- **[x] ① 已修复** — 转交状态机抽成纯 Dart `fushi/lib/src/lookup/advanced_mining_handoff_gate.dart`（`AdvancedMiningHandoffGate`）：页面所有铸查询代的地方统一走 `_mintSearchGeneration()`，铸代即 `revoke()`；回包后再核「同一转交 + 同一查询代 + 同一结果对象 + 同一 WebView」，任一不符不开对话框，若往返途中来过渲染信号则按新状态立刻重走一遍
- **[x] ② 已加自动化测试** — `fushi/test/lookup/advanced_mining_handoff_gate_test.dart`（可手动完成的定位 Future：A 在途 → 手动查 B → A 先回包 → 不开对话框；同代换结果；新转交撞上旧往返；-2 / -1 / dispose）；`fushi/test/lookup/advanced_mining_handoff_test.dart` 源码守卫钉住查询代只从 `_mintSearchGeneration` 铸出
- **备注**：同批 [BUG-5362](BUG-5362-overlay-handoff-reading-mismatch.md)
