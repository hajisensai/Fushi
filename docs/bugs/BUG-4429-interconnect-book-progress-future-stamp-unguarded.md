## BUG-4429 · 互联书籍进度没接未来时间戳防护，毒戳在 LWW 里永远胜出并扩散到各端
- **报告**：2026-11-10（用户：审计 sync-live 修复包 D8）
- **真实性**：✅ 真 bug。视频 / 有声书 PUT 早已截上报戳、把已存毒戳按 0 比较（BUG-3367），书籍通道漏接：
  - host：`packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:481` `putBookProgress` 把上报戳原样交给 `resolveBookProgressSync`，不截上报戳也不降权已存毒戳——时钟走快的设备一旦写下 `now + 1 天`，之后所有端的正常上报都被 no-op。
  - client：`fushi/lib/src/sync/interconnect_book_progress_sync.dart:320` `pushLocal` 按 `remote.updatedAtMs + 1` 抬戳，把毒戳 +1 推回 host 并写进本端 `reader_positions.updatedAt`；`:377` `alignSynced` 直接按戳取胜者，host 毒戳被对齐写进本端。播放位置 `fushi/lib/src/sync/interconnect_playback_position_sync.dart:285` `alignSynced` 同样直接比戳；两个 `applyRemote` 把 host 毒戳原样落到本端。
- **[x] ① 已修复** — e5baec1a4e7：`fushi_library_host_service.dart` 新增纯函数 `withTrustedStoredStamp` / `withCappedStamp`；host `putBookProgress` 事务内截上报戳、按可信戳视图比较（胜者是已存那份就 no-op，不把 0 戳视图写回库；胜者是上报那份时与原始行逐字段比较，毒戳行一定被覆盖）；client 书籍 `pushLocal` 与播放位置同纪律（可信戳比较 + 截戳），书籍 / 播放位置 `alignSynced` 按 host 可信戳比较（毒戳 → 本端胜出、推本端戳），两个 `applyRemote` 落本端时截戳。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_library_host_service_book_progress_test.dart`（真 `LocalLibraryHostService` + 内存库：毒戳行被正常上报覆盖、未来上报戳被截、毒戳行收 0 戳同位置仍 no-op）；`fushi/test/sync/interconnect_future_stamp_guard_test.dart`（书籍 pushLocal / alignSynced / applyRemote 与视频 alignSynced / applyRemote，记录 PUT 的假后端）。修复前 7 条断言红。
- **备注**：不改 wire 字段，host 侧对新旧 client 一致生效；存量毒戳按 0 比较，下一次正常上报覆盖。本端 `reader_positions.updatedAt` / 播放 `_at_` pref 只有超过 `now + 5min` 的戳会被截。
