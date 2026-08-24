## BUG-1808 · 视频首页横滚行卡不显示标签（拆 section 后首页只剩横滚卡，标签层只画在墙格卡上）
- **报告**：2026-08-24（用户：「首页少了标签，我打好的标签没在首页显示」→ 澄清为「视频的首页的视频不显示标签」）
- **真实性**：✅ 真 bug（回归）。根因 `fushi/lib/src/pages/implementations/home_video_page.dart:3497`（`_buildRowMediaCard` 封面 Stack 无标签层）。
  标签 chip 只画在墙格散卡 `_buildCard`（同文件 `_buildTagLabels` 调用处）与合集墙卡 `_buildCollectionCoverCard`。
  `fde80d7189`（series-first 拆库）把页面拆成 `home / series / allVideos` 三个 section 后，墙格 sliver
  （`_buildLocalVideoSlivers` / `_buildAllVideoSlivers`）只挂在 `series` / `allVideos` 上，`home` 只剩
  `_buildOverviewSection`（hero + 继续观看 / 下一集 / 最近添加 三条横滚行）。横滚卡 `_buildRowMediaCard`
  自引入起就没有标签层，于是拆分当天起首页的视频卡一个标签都不显示——标签本身写穿了 DB，只是没人画。
- **[x] ① 已修复** — `_buildRowMediaCard` 增加 `tags` 参数并在封面左上角（top:6/left:6，与墙卡同位同形）渲染
  `_buildTagLabels`；继续观看散卡 / 继续观看合集卡 / 最近添加卡三个调用点接上数据源。同时把散卡与合集卡
  各自 inline 的 `ref.watch(...)` 收敛成 `_videoBookTags(bookUid)` / `_collectionTags(collectionId)` 两个
  helper，墙卡与横滚卡共用同一口径（首页当初漏画，正是因为标签只跟着墙卡那一处写法走）。远端占位卡无本地
  条目、无标签，保持不传。提交：见本分支 `fix(video): 视频首页横滚行卡补回标签层 (BUG-1808)`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_home_row_tags_test.dart`（3 条 widget 行为断言：
  继续观看散卡显示自己的标签且不铺到邻卡、最近添加卡显示标签、继续观看合集卡显示合集标签）。
  变异实测：给标签层加 `&& !kMutationProbe1808` 关掉渲染 → 3 条全红；还原后文件 SHA-256 与变异前逐字节一致
  （`6dee4a45…2eecf`），排除恒真断言。
- **备注**：首页 hero 轮播（backdrop 大图）仍不画标签——那是整幅背景图版式，与卡片角标口径不同，本次未动。
