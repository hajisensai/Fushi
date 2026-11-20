## BUG-4912 · LNReader 状态读不出来时扩展页与已装源显示成空态
- **报告**：2026-11-20（路线图 #3722 遗留（docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md 第 3 节），c02 留下的「读盘失败时扩展页 / 已装源列表没有读取失败提示」）
- **真实性**：✅ 真 bug。c02（BUG-4799 那条 LNReader 状态读盘）让 `state.json` 读不出来时 `LnReaderManager` 不进「已加载」、`installed` / `stores` 是空占位、所有改动被 `ensureReady` 拒绝，但界面不看 `stateError`：`fushi/lib/src/media/novel/online/lnreader_installed_sources_section.dart:279`（`all.isEmpty` → 「还没有小说源」）、`fushi/lib/src/media/novel/online/lnreader_extensions_section.dart:468`（`stores.isEmpty` → 「还没有仓库」+ 添加入口）。用户被引去重新安装 / 添加，每一步都失败。
- **[x] ① 已修复** — 06c89f7110：新增 `LnReaderStateErrorNotice`（错误态 + 重试，重试即再调 `initialise`，失败不缓存），已装源段、仓库段、只显示扩展目录时的目录段在 `stateError != null` 时用它代替空态。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/lnreader_ui_test.dart`（根目录位置放一个文件让 `rootDirectory.create` 必抛：已装源段 / 仓库段 / 扩展目录各自出错误态而非空态，删掉阻挡后点重试恢复；cdd0bdbbd4 把用例按段拆开）。
- **备注**：未在真机 / 真 app 上复现读盘失败（需人为制造占用 / 权限错误）。
