## BUG-2406 · 统计「最近会话」标题单行截断且不带合集名
- **报告**：2026-09-10（用户：统计中心 › 观看 › 最近会话，「Re：从零开始的异世界生活…」被省略号截断；其余行只有「暗中行动」「威胁」这种分集名，看不出属于哪部作品）
- **真实性**：✅ 真 bug。两处根因都在展示层：
  - 截断：`fushi/lib/src/pages/implementations/stat_session_list.dart:164` 的 `FushiListItem` 没传 `titleMaxLines`，吃默认值 1（`fushi/lib/src/utils/components/fushi_material_components.dart:160`，BUG-1184 起故意保留默认 1，放宽必须逐调用点显式做）。会话行承载的正是长媒体名，手机宽度下单行 ellipsis 只剩开头几个字。
  - 缺合集名：会话的 `title` 是段 title 快照 = **条目名**（`fushi/lib/src/stats/study_sessions.dart:44`），合集里就是分集 / 分册名。四个挂会话区块的页面（阅读 / 视频 / 游戏三个域 tab + 统计中心总览）的 `titleOf` 都只回传条目名，而合集归属映射 `_primaryCollectionByEntry` / `_collectionNamesById` 四个页面本来就已加载（时段明细 sheet 用它做组头）——会话流是扁平时间序，没有组头兜底，合集名就此掉了。
- **[x] ① 已修复** — `stat_session_list.dart` 新增 `StatSessionCollectionOf` 解析器：命中合集的行在条目名上方挂共享的 `buildStatCollectionLabel`（与「按书 / 按视频」tile 同一视觉），删除确认文案走 `合集名 - 条目名`；行标题放宽到 `titleMaxLines: 2`（本区块父容器是页面 sliver / sheet 的 Column，高度自由）。四个页面各按自己的域键契约接线：视频 `video|<bookUid>`、阅读 `epub|<uid>`（经 `_epubUidByBookKey` 换算）、游戏 `game|<galgames.id>`、总览按 `mediaKind` 分派。
- **[x] ② 已加自动化测试** — `fushi/test/pages/stat_session_list_test.dart`：命中合集的行同时显示合集名与条目名、未命中不挂标签；合集名进删除确认文案；手机宽度（400dp）下长标题真的排到第二行（`RenderParagraph.size.height > 1.5 * preferredLineHeight` 且 `didExceedMaxLines` 为 false）。外加 `fushi/test/pages/stat_pages_skeleton_guard_static_test.dart` 的源码守卫：四个页面的 `buildStatSessionSection(` / `showStatSessionsSheet(` 调用点一个都不许漏传 `collectionOf`（反证过：抽掉视频页那一行守卫即红）。
- **备注**：合集名与条目名同名时不去重，与 `collectionQualifiedTitle` / 时段明细组头同一惯例。
