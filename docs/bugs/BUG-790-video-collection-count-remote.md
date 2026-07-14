## BUG-790 · 视频合集行计数只数本地成员导致全云端合集显示0集
- **报告**：2026-07-14（用户：截图圈出「0 集查看全部」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart`（旧 `_buildVideoCollectionRow` 内 `localCount = group.items.where((it) => it.payload.local != null).length`）。
- **[x] ① 已修复** — 行头计数改与行体 `itemCount` 同源（`memberCount = group.items.length`），见 `home_video_page.dart:2089/2100-2101`。提交见本轮 commit。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/unified_collections_architecture_guard_test.dart` 新增守卫「BUG-790：视频合集行头集数 = 行体成员数（本地+远端占位同源）」：① 禁 `localCount` 只数本地过滤喂 `video_playlist_episodes`；② 断言行头 `countLabel` 的 count 与 `itemCount` 引用同一变量（同源）。已实证：注回旧 `localCount` 口径该守卫转红，修复后转绿。
- **备注**：
  - 现象：多端库联合视图（任务10）把「远端有本地无」的未下载剧集折进本地合集行，行体（`itemCount`）渲染全部成员（本地 + 远端云占位卡供流播/下载），但旧口径行头**只数本地成员**。全为未下载远端剧集的合集（如「小林さんちのメイドラゴン」「Senpai wa Otoko」）行里明明有云占位卡，行头却显示「0 集」，与眼前所见割裂。有 12 集本地的「からかい上手」显示「12 集」正常，佐证是「远端成员不入计数」而非计数彻底坏。
  - 根因层：`RemoteVideoInfo` 远端占位在 `_groupVideos` 里以 `video.id` 为 entryKey 混入 `_VideoSlot` union，`payload.local == null`；旧 `localCount` 过滤掉它们。
  - 用户拍板口径（方案一）：行头集数 = 行里看得见的全部卡片数（本地 + 云端占位）。已落地。
  - **未在本 bug 内处理的联合视图第二部分**：合集详情页（点「查看全部」→ `MediaCollectionDetailPage`）目前仍只读本地成员（`getCollectionItems` → `getByBookUid` 映射，纯远端成员无本地行被排除），故纯云端合集点进详情页会是空/少。这是**该 develop 既有行为**（非本次改动引入），且远端成员是 host 下发 `RemoteCollectionMembership` 的**内存匹配临时占位**、并非 `MediaCollectionItems` 真实条目，让详情页也联合展示涉及拖拽落盘/串流/移出等设计问题，属 feature 级改动，另行规划。
