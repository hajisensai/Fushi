## BUG-2423 · 同步冲突卡片书名单行省略，同系列多条冲突只剩同一前缀无法分辨
- **报告**：2026-09-10（用户截图：手机端「本地 vs 远端」弹窗里两条冲突都显示为「無職転生 ～異世界行った…」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/sync_compare_dialog.dart:1341`（`_buildEntry` 里标题 `Text` 写死 `maxLines: 1` + `TextOverflow.ellipsis`）。
  书名是冲突行唯一的身份（裁决结果 `_choices` 也是按 `entry.title` 索引），而轻小说 / 有声书标题动辄二三十字，
  分岐点（卷号、副标题）在尾部。省略号恰好把那段切掉，同一系列的两条冲突渲染结果逐像素相同，
  用户无法判断自己在给哪一本选「本地 / 跳过 / 远端」——而选错直接覆盖阅读进度，不可撤销。
- **[x] ① 已修复** — `maxLines: 1` 改为 `maxLines: 3`（换行展示，3 行封顶避免异常长标题把卡片拉得无界），
  `fushi/lib/src/sync/sync_compare_dialog.dart`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_compare_layout_test.dart`：「长书名换行展示：同系列的两条冲突不能只剩同一个前缀」。
  真 widget 行为：播两本只差尾部卷号的长标题冲突，对标题 `RenderParagraph` 断言 `didExceedMaxLines == false`（没被省略）
  且 `getBoxesForSelection` 行数 > 1（真的换了行，否则对 `maxLines: 1` 也会误绿）。已反向验证：把 `maxLines` 改回 1 这条即红。
- **备注**：同弹窗的词典行（`_buildDictEntry`）也是 `maxLines: 1`，本次未动——词典名普遍短且未被报告，
  若后续出现同类报告再按同一处方修。
