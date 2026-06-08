## BUG-162 · 书籍退出再进位置漂移（持久化恢复走粗粒度进度分数而非精确字符偏移）
- **报告**：2026-06-08（用户：退出再进不是同一个位置，参考上一层 Hoshi-Reader-Android）
- **真实性**：✅ 真 bug。阅读器存两套坐标系：① 精确**绝对字符偏移**
  `getFirstVisibleCharOffset`→`scrollToCharOffset`（`lib/src/reader/reader_pagination_scripts.dart:1074/1107`，是「存→取」不动点，BUG-109 已让切样式/chrome-inset 重锚改用它）；
  ② 粗粒度**进度分数** `calculateProgress`→`scrollToProgressPaged`/`findNodeAtProgress`+`alignToPage`
  （`reader_pagination_scripts.dart:965/269/251`，非不动点、`alignToPage` 取整落相邻页）。
  **退出再进的持久化恢复**漏修，仍走 ②：保存
  `lib/src/pages/implementations/reader_hibiki_page.dart:3505` 存 `normCharOffset=round(progress*10000)`，
  恢复 `reader_hibiki_page.dart:501`→`restoreProgress($initialProgress)`→`reader_pagination_scripts.dart:1004`→`scrollToProgressPaged`。
  即使布局一致也系统性前移约一节点≈一页（节点大/页窄更甚），与项目自己在
  `reader_pagination_scripts.dart:1259-1264` 注释写明的 BUG-109 失效模式相同。
  Hoshi-Reader-Android 原版用精确字符坐标（`range.setStart` 到具体字符+`alignToPage`）故不漂。
- **[x] ① 已修复** — 持久化恢复改走精确字符偏移坐标，复用成熟路径，不破坏旧数据：
  - DB 新增 `reader_positions.char_offset`（section 内绝对字符偏移恢复锚，schema v23→v24，
    `tables.dart` + `database.dart` `if (from < 24)`）。**保留** `ttu_char_offset` 不动——它非死列，
    `sync_manager.dart:420/474/525/606` 用它缓存 whole-book `exploredCharCount`（范围不同→独立成列，
    upsert 各留对方列 absent 互不覆盖）。
  - 保存：`hoshiProgressDetails` 追加第三段 `getFirstVisibleCharOffset()`（`reader_hibiki_page.dart:1771`），
    `_persistPosition` 写入 `char_offset`（`reader_hibiki_page.dart:3517`，`repo.save(charOffset:)`）。
  - 恢复：新增 `restoreToCharOffset`（分页 `reader_pagination_scripts.dart:1016` + 连续，复用精确
    `scrollToCharOffset`）；shell builder 加 `initialCharOffset`，`>=0` 走 `restoreToCharOffset`、否则回退
    `restoreProgress(分数)`（旧存档/书签/翻章 `initialCharOffset=-1`，行为不回归）。
  - 连续模式 `scrollToCharOffset` 抽自 `setChromeInsets` 内联体并令其复用（DRY）。
  - 提交：`a00fbb63c`（DB v24）/ `39ae6a8ca`（保存端）/ `23c5da2f6`（恢复端+Dart 接线）。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/restore_charoffset_guard_test.dart`（源码守卫，仿
  `reanchor_charoffset_guard_test.dart`）：保存端报精确偏移 / 分页+连续都定义 `restoreToCharOffset` /
  恢复脚本 `initialCharOffset>=0` 优先精确路径 / Dart 保存写 charOffset·恢复读 saved.charOffset·setup 传
  initialCharOffset。+ `hibiki/test/database/reader_positions_test.dart` 加 `char_offset` 默认/往返且不污染
  `ttu_char_offset` 的 DB 测试。全量 `flutter test` 3175 绿（2 golden 门控 skipped），含 v23→v24 迁移与
  BUG-109 reanchor 守卫未回归。
- **备注**：真机复测待用户——分页/连续 × 横排/竖排，翻到中段→退出→重进应落回同页（旧存档首次回退分数属
  预期，翻一页 re-save 后即精确）。`_reloadWithCurrentSettings` 全量重载仍沿用粗粒度分数重锚（与改前一致、
  未回归），精确化是后续可做增量。
