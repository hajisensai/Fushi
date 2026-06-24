## BUG-418 · 连续模式书籍历史恒回章首(reflow非自愿归零·795/797未修好)
- **报告**：2026-06-24（用户：滚动/连续模式书籍历史记录又没了，每次都回到章节开头；TODO-797 声称修复但本地 Debug EXE 真机实测仍未修好 = TODO-798）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:631`（`_refreshProgress` 无条件落库），触发链根在 `hibiki/lib/src/reader/reader_pagination_scripts.dart:927`（JS `_reportReaderScroll` 无法区分用户滚动 vs reflow 自发归零）
- **[x] ① 已修复** — commit 见提交哈希；改 `_refreshProgress`（navigation.part.dart）+ 新增纯函数 `readerContinuousProgressSnapIsInvoluntary`（reader_hibiki_page.dart）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_continuous_snap_guard_test.dart`（纯函数真值表 7 例 + 接线守卫 1 例）
- **备注**：

### 真因（795/797 没修到的地方）
连续模式阅读位置是裸 `window.scrollY`。退出再进恢复落定后，WebView 平台视图自发 reflow
（box.size 抖动 / 图片或 SVG 异步 settle）把 `window.scrollY` **瞬时归 0**。归零产生的 scroll
事件经 JS `_reportReaderScroll`（reader_pagination_scripts setup 脚本）回传 `onReaderScroll`
→ `_handleReaderScroll` → `_refreshProgress` 读到 `progress≈0` → `_debouncedSavePosition`
落库章首。

既有抗归零的两墙**都是时间边界**的，而它们要防的 reflow 是**时间无边界**的：
- JS `_reanchorPending` 旗：只在 `begin` 后约 1 帧的 `commit` 就清（rAF / postFrame）；
- Dart B-3 `readerScrollWithinReanchorSettle`：清旗后只有 250ms 窗。

大章 + 图片首开的 reflow 远超 250ms → 晚到的归零穿过两墙落库章首。797 的修复只是给恢复
重锚 / appUiScale 重锚的 `commit` 也打点 `_reanchorClearedAt` 武装 B-3 窗——但 B-3 窗本身
（250ms）就是错的数据结构，故真机仍回章首。

旧 B-4（`readerProgressDropIsSpurious`，已于 `ea096d866` 删）用「无近期输入=伪」判伪，被
惯性甩动到真章首（momentum 期无新输入）误伤 → 因果倒置。

### 根因式修复（位置不连续判据，非时间窗、非输入时序）
正确判据是**位置不连续**：非自愿 reflow 归零是从一个实质性已提交位置**单步**塌缩到章首
（`prior≈0.5 → new≈0`）。用户真滚到章首（含惯性甩动）经 rAF 节流逐帧上报一串递减进度
（0.5→0.4→…→0.05→0），每发更新 prior，到 0 那一发 prior 已≈0 → 不触发。

- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`：新增纯函数
  `readerContinuousProgressSnapIsInvoluntary({continuousMode, priorProgress, newProgress,
  hasCommittedAnchor})`（仅连续模式；`new≤epsilon` 且 `prior≥minPrior` 且有锚 → true）。
- `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart` `_refreshProgress`：
  落库前捕获 `priorProgress=_lastProgressValue` + `committedAnchor`（`_lastProgressCharOffset`
  否则 `_initialCharOffset`），命中判据则用 `scrollToCharOffsetInvocation` **复位到已提交锚**
  （把视口滚回，不止跳过落库）并 `return`，保留 `_lastProgress*` 不被归零覆盖。

### 相邻保护
- 样式重锚（TODO-736 B-1/B-3）、appUiScale 重锚（693）、恢复重锚（718）路径与 `_reanchorPending`
  全部不动；本判据是它们之后无时间边界的兜底网。
- 用户真滑到章首（含惯性甩动）：逐帧递减上报，到 0 时 prior 已≈0 → 不触发，章首正常保存。
- 分页模式：有 snap/lock 保护，`continuousMode==false` 恒 false。
- 手动跳章到章首：`_beginNavigation` 置 `_lastProgressValue=0` → prior=0 → 不触发。

### 验证
- `dart format` + `flutter analyze`（改动文件 No issues）
- `flutter test test/reader/`：678 passed（含新 `reader_continuous_snap_guard_test.dart` 8 例、
  `reader_progress_save_wiring_guard_test`、`reader_progress_drop_guard_test`、
  `reader_vertical_pitch_invariant_test` 全绿；`reader_inchapter_progress_diag_log_test` 窗口宽度
  随函数体加长同步放宽）。
- **真机门禁待办**：连续/滚动模式打开一本大章（含图片）书 → 滚到章节中段 → 退出 → 重进 →
  断言回到中段而非章首（重复 3 次）；横排 + 竖排各一遍；改字号 / 界面缩放后翻页不跳章首
  （相邻保护回归）。
