## BUG-728 · 书架有声书进度条听书时不更新

- **报告**：2026-07-11（用户）
- **真实性**：✅ 真 bug（用户真实生产库 `D:\APP\HIBIKI_date\support\hibiki.db` 只读实测坐实）。
  - 根因 `hibiki/lib/src/media/sources/reader_hibiki_source.dart:49` `computeBookProgress`：章内进度只认精确 `charOffset`，`charOffset < 0` 时 `intra = 0`；而**听书 cue 派生位置无精确字符偏移**（`packages/hibiki_audio/lib/src/audiobook/reader_position_repository.dart:26-30` 保存时 `charOffset=null → -1`），章内进度只落在归一化 `normCharOffset`（0-10000 章内分数）里。旧实现完全丢弃 `normCharOffset` → 听书进度停在章边界甚至显 0%。
  - `ReaderPositions.charOffset` 列注释本就写明 `-1 = 无精确偏移（恢复回退 normCharOffset 分数）`（`packages/hibiki_core/lib/src/database/tables.dart:109-111`）；阅读器 restore 已用这条回退，书架 `computeBookProgress` 漏了。
  - 生产库实测 6 本有声书书架进度：安達1 80.1%（真读过 charOffset=22059，正常）／安達2 19.4%（听书 charOffset=-1、norm=9105=章内91% 被丢弃）／謎解き 30.9%（同）／安達4 0%（从未在阅读器打开）等。normCharOffset 语义验证：安達1 `charOffset/本章字数=0.857 ≈ normCharOffset/10000=0.858`，确认为「章内归一化」。
- **[x] ① 已修复** — **两段合起来才对用户可见**（关键：EPUB-backed 有声书在书架**只渲染成 SRT 卡**——其 EpubBooks 行被 `srtBookKeys` 从 EPUB 卡列表过滤掉，`reader_hibiki_history_page.dart` `epubBooks = books.where(...!srtBookKeys...)`；生产库 6 本有声书 srt_books 全部 `epub_match=1`）：
  - **A（进度算法）** `hibiki/lib/src/media/sources/reader_hibiki_source.dart`：`computeBookProgress` 新增 `normCharOffset` 参数，`charOffset < 0`（听书哨兵）时 `intra = round(clamp(normCharOffset,0,10000)/10000 × 本章字数)`，与阅读器 restore 回退口径一致；调用点 `_bookToMediaItem` 传 `pos?.normCharOffset ?? 0`。正常阅读书 `charOffset≥0` 不走新分支、零破坏。
  - **B（SRT 卡渲染进度条）** `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart` + `reader_history/books.part.dart`：过滤前把每本 EpubBooks 行**已算好的** position/duration 收进 `_epubProgressByBookKey`（复用 A 的结果，零重算）；`_srtBookMediaItem` 改用该映射（不再硬编码 `0/1`）；`_buildSrtCard` 对 EPUB-backed 书（`_srtBookHasProgress`）渲染与 EPUB 卡同一个 `_progressBar`。纯字幕书无字符进度真值 → 不传 `metadata`，保持无进度条（不灌水）。
  - 提交：见分支 `worktree-shelf-audiobook-progress`（PR#33）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/sources/reader_hibiki_source_test.dart` 新增 group `computeBookProgress normCharOffset 回退 (BUG-728)`：6 条（norm=5000 半章前进／norm=10000 满章／norm=0 章首诚实／charOffset≥0 优先／norm 越界 clamp／源码守卫）。既有 `charOffset==-1 当 0`（不传 norm）因默认 `normCharOffset=0` 仍通过。
  - `hibiki/test/pages/shelf_srt_card_progress_guard_test.dart` 新增 3 条源码守卫：进度映射过滤前装配／`_srtBookMediaItem` 用映射非硬编码 0/1／`_buildSrtCard` 按 `_srtBookHasProgress` 门控渲染 `_progressBar`。
  - 相关文件全绿（源测 49→55，含 override 守卫）。
- **备注**：
  - **剩余独立缺口（未做）**：**纯字幕书**（无 EPUB backing、`bookKey` 空或无 epub 行）仍无进度条——它们没有字符进度真值，需要 cue-based 听书进度来源，另开 BUG。用户当前 6 本有声书全是 EPUB-backed，不受此限。
  - 真机验证待办：本机 Windows/安卓装此分支包，听书推进后回书架，确认 SRT 有声书卡出现进度条且随听书前进（安達2 应从 ~19% 升到 ~35%，安達4 无 reader_position 仍 0%=预期）。
