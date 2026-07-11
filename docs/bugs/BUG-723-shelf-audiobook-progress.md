## BUG-723 · 书架有声书进度条听书时不更新

- **报告**：2026-07-11（用户）
- **真实性**：✅ 真 bug（用户真实生产库 `D:\APP\HIBIKI_date\support\hibiki.db` 只读实测坐实）。
  - 根因 `hibiki/lib/src/media/sources/reader_hibiki_source.dart:49` `computeBookProgress`：章内进度只认精确 `charOffset`，`charOffset < 0` 时 `intra = 0`；而**听书 cue 派生位置无精确字符偏移**（`packages/hibiki_audio/lib/src/audiobook/reader_position_repository.dart:26-30` 保存时 `charOffset=null → -1`），章内进度只落在归一化 `normCharOffset`（0-10000 章内分数）里。旧实现完全丢弃 `normCharOffset` → 听书进度停在章边界甚至显 0%。
  - `ReaderPositions.charOffset` 列注释本就写明 `-1 = 无精确偏移（恢复回退 normCharOffset 分数）`（`packages/hibiki_core/lib/src/database/tables.dart:109-111`）；阅读器 restore 已用这条回退，书架 `computeBookProgress` 漏了。
  - 生产库实测 6 本有声书书架进度：安達1 80.1%（真读过 charOffset=22059，正常）／安達2 19.4%（听书 charOffset=-1、norm=9105=章内91% 被丢弃）／謎解き 30.9%（同）／安達4 0%（从未在阅读器打开）等。normCharOffset 语义验证：安達1 `charOffset/本章字数=0.857 ≈ normCharOffset/10000=0.858`，确认为「章内归一化」。
- **[x] ① 已修复** — `hibiki/lib/src/media/sources/reader_hibiki_source.dart`：`computeBookProgress` 新增 `normCharOffset` 参数，`charOffset < 0` 时 `intra = round(clamp(normCharOffset,0,10000)/10000 × 本章字数)`，与阅读器 restore 回退口径一致；调用点 `_bookToMediaItem` 传入 `pos?.normCharOffset ?? 0`。正常阅读书 `charOffset≥0` 不走新分支、行为不变，零破坏。提交哈希：（见分支 `worktree-shelf-audiobook-progress`）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/sources/reader_hibiki_source_test.dart` 新增 group `computeBookProgress normCharOffset 回退 (BUG-723 听书进度)`：6 条覆盖 norm=5000 半章前进／norm=10000 满章／norm=0 章首诚实／charOffset≥0 优先／norm 越界 clamp／源码守卫「_bookToMediaItem 传 normCharOffset」。既有 `charOffset == -1 当 0`（不传 norm）因默认 `normCharOffset=0` 仍通过，向后兼容。全文件 49 条全绿。
- **备注**：
  - **独立缺口（本次不动）**：纯字幕/SRT 有声书卡（`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:58`）调 `_bookCardLayout` 时不传 `metadata:`，且 `_srtBookMediaItem` 硬编码 `position:0, duration:1`（`:120-121`）→ SRT 卡完全无进度条。属另一处设计，需要额外的 cue 进度来源，另开 BUG 处理。
  - 真机验证待办：本机 Windows/安卓装此分支包，听书推进后回书架，确认进度条随听书前进（安達2 应从 ~19% 升到 ~35%）。
