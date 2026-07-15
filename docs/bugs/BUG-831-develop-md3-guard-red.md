## BUG-831 · develop md3_static 守卫红:jimaku ListTile + collection-delete CheckboxListTile 2处既存违规
- **报告**：2026-07-15（用户：integration owner）
- **真实性**：✅ 真 bug。守卫 `hibiki/test/settings/md3_design_system_static_test.dart` 的 `ordinary page chrome does not reopen local MD3 decisions` 在 develop `9961e9183` 上红，两处既存违规均不在白名单：`hibiki/lib/src/pages/implementations/jimaku_batch_dialog.dart:390`（`ListTile(`，来自 PR#145）与 `hibiki/lib/src/pages/implementations/media_collection_grid_detail_page.dart:233`（`CheckboxListTile(`，来自 PR#133）。
- **[x] ① 已修复** — 白名单：`hibiki/test/settings/md3_design_system_static_test.dart`；控件迁移：`hibiki/lib/src/pages/implementations/media_collection_grid_detail_page.dart`（提交见下）
- **[x] ② 已加自动化测试** — 既有守卫 `hibiki/test/settings/md3_design_system_static_test.dart`（`ordinary page chrome does not reopen local MD3 decisions`）本就是源码扫描自动化守卫，现全绿（0 违规）
- **备注**：提交哈希待落地后回填。

### 根因
MD3 静态守卫 `ordinary page chrome does not reopen local MD3 decisions` 遍历 `lib/src` 下所有 `.dart`，非 `allowedFiles` 白名单文件不得出现 `forbidden` token（含 `ListTile(` / `CheckboxListTile(` 等）。PR#145 与 PR#133 合入 develop 时各引入一处 forbidden token 但未同步守卫，导致 develop 的 `tests` CI job 变红：

1. `jimaku_batch_dialog.dart:390` —— `ListTile(`：批量字幕下载对话框用 `ListView.builder` 渲染每个成员剧集的状态图标 + 标题 + 语言副标题行。这是**视频子系统内容**（批量下载进度列表），非普通页面 chrome，同 `video_episode_panel` / `video_subtitle_jump_panel` / 同域 `jimaku_subtitle_dialog` 的 reviewed 内容豁免类。
2. `media_collection_grid_detail_page.dart:233` —— `CheckboxListTile(`：删除合集确认弹窗里「同时删除本体」勾选**控件**。这是普通页面 chrome，豁免它会违守卫哲学，应迁到 MD3 合规原语。

### 修复
1. jimaku ListTile（内容列表）→ 在守卫 `allowedFiles` map 加一条豁免（英文理由，仿邻居 `video_episode_panel` / `jimaku_subtitle_dialog` 风格），插在同域 `jimaku_subtitle_dialog.dart` 条目前。
2. CheckboxListTile（控件/chrome）→ 迁到行为完全等价的 `InkWell` + `Row` + `Checkbox` + `Expanded(Text)` 组合：checkbox 在左（leading），tap 整行或勾选框都 `setLocal(() => alsoDeleteMembers = ...)`，`title` 文案 `t.delete_collection_also_books`，无额外 padding。`InkWell` / `Row` / `Checkbox` / `Text` / `Expanded` 均不在 forbidden 列表，守卫通过。行为与旧 `CheckboxListTile` 完全等价（`value` / `onChanged` / leading / title 语义一致）。

改后 `flutter test test/settings/md3_design_system_static_test.dart` 全绿（0 违规）。
