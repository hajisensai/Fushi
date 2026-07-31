## BUG-1291 · 销毁确认弹窗勾选行文案被单行省略号截断

- **报告**：2026-07-31（用户：截图「删除合集」弹窗，勾选行显示为「同时删除其中的视频（保留你的原始视…」）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/utils/components/hibiki_destructive_confirm_dialog.dart:90`（勾选行）
  + `hibiki/lib/src/utils/components/hibiki_material_components.dart:153,245`（`HibikiListItem.titleMaxLines` 默认 1 + `TextOverflow.ellipsis`）

### 根因

`HibikiDestructiveConfirmDialog` 的可选勾选行直接把整句解释文案塞进 `HibikiListItem.title`。
`HibikiListItem` 是为**列表标题短语**设计的：`titleMaxLines` 默认 1，且外层
`DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis)` 强制单行省略。

对话框 `maxWidth: 420`，扣掉 body 内边距与 Checkbox 宽度后，可用文本宽度装不下
「同时删除其中的视频（保留你的原始视频文件）」，于是括号里的免责说明——恰好是用户
最需要看清的那半句（「原始视频文件不会被删」）——被整段吃掉，只剩「…保留你的原始视…」。

同一弹窗的正文 `message` 是裸 `Text`，没有行数限制，所以只有勾选行被截断，视觉上像是
「这一行本来就该这么短」，不易察觉是截断。

`titleMaxLines` 的默认值 1 是 BUG-1184 有意保留的（部分调用点把列表项放在固定高度容器
里，换行会撑破父容器），其注释明确要求「放宽必须逐调用点显式进行」。因此根治点在调用方，
而不是改默认值。本调用点的父容器高度自由：外层 `HibikiDialogFrame.scrollable` 默认 true
（`hibiki_material_components.dart:1184,1230`），整个 sheet 被 `SingleChildScrollView` 包裹，
放开行数不会 overflow。

**影响范围**：所有传 `checkboxLabel` 的销毁确认路径，共 5 处调用，全部是同类整句文案——
- `home_video_page.dart:3363` / `reader_hibiki_history_page.dart:1699`（两个库页的合集长按菜单，经 `collection_context_dialog.dart:210`）
- `media_collection_detail_page.dart:257`（视频合集详情页）
- `media_collection_grid_detail_page.dart:148`（书籍合集详情页）
- `collection_detail_shared.dart:124`（详情页共享删除流程）

### 修复

- **[x] ① 已修复** — `hibiki/lib/src/utils/components/hibiki_destructive_confirm_dialog.dart`
  勾选行显式传 `titleMaxLines: 3`，文案改为换行显示完整。一处修复覆盖上列全部 5 条路径。

- **[x] ② 已加自动化测试** — `hibiki/test/widgets/hibiki_destructive_confirm_dialog_test.dart`
  新增用例「BUG-1291 长勾选文案换行显示完整，不被省略号截断」，widget 行为层双断言：
  1. `RenderParagraph.didExceedMaxLines == false`（文案没被省略号截断）；
  2. 长文案渲染高度 > 短文案高度（证明该宽度下**确实发生了换行**，堵死「哪天对话框变宽
     到一行装得下，maxLines 退回 1 也照样绿」的假绿）。

  **变异实测**：把 `titleMaxLines: 3` 改回 `1` 重跑，用例在断言 ① 处失败（`+3 -1`）；
  还原后 4/4 绿。守卫有效。

### 备注

不改 `HibikiListItem.titleMaxLines` 默认值——那正是 BUG-1184 回退过的动作。
