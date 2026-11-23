## BUG-5359 · 对比弹窗「应用」章节式互联漫画时书级进度抛 ArgumentError，并短路有声书断点
- **报告**：2026-11-24（外部审查报告 HBK-AUDIT-002 P2，针对 #4297 互联漫画进度）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/sync_compare_dialog.dart` 只在加载期 live 探测（约 374-382 行）用 `InterconnectBookProgressSync.syncsBookProgress` 过滤章节式互联漫画；条目仍带 `remoteLiveTitle`，本机 `reader_positions` 留着章内页码 → `autoDirection` 推断为「推向远端」、默认选「用本地」。「应用」走 `_applyLiveChoice`（约 1221 行）只看 `liveAction != null || remoteLiveTitle != null` 就进 `_applyLiveProgressChoice` → `remoteProgress` → `InterconnectBookProgressSync._hostKey`（`interconnect_book_progress_sync.dart:164-175`）抛 `ArgumentError`，这本书记失败，后面的有声书断点同步被跳过。
- **[x] ① 已修复** — 新增 `_rowSyncsBookProgress`（互联通道 = `syncsBookProgress`，云通道恒真），加载期 live 探测、条目新字段 `SyncCompareEntry.syncsBookProgress` 与「应用」入口共用它。不参与书级同步的行 `hasConflict=false` / `isSynced=true` / `autoDirection=synced`（默认跳过，不再误报「推向远端」）；用户显式选了一侧时 `_applyLiveChoice` 跳过书级、有声书维度照常执行。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_compare_interconnect_live_progress_test.dart`「章节式互联漫画：对比不判书级方向…」：加载后该行不冲突、方向 synced、默认 skip；分别以「用远端」「全部用本地」应用，断言书级端点零调用、`putProgress` 为空、无失败，有声书断点分别落回本机 / 推给 host，章内页码不被改写（修复前 errors=['BookA']）。
- **备注**：无。
