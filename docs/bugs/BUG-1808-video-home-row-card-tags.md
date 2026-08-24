## BUG-1808 · 视频首页横滚行卡不显示标签（拆 section 后首页只剩横滚卡，标签层只画在墙格卡上）
- **报告**：2026-08-24（用户：「首页少了标签，我打好的标签没在首页显示」→ 澄清为「视频的首页的视频不显示标签」）
- **真实性**：✅ 真 bug（回归）。根因 `fushi/lib/src/pages/implementations/home_video_page.dart:3497`（`_buildRowMediaCard` 封面 Stack 无标签层）。
  标签 chip 只画在墙格散卡 `_buildCard`（同文件 `_buildTagLabels` 调用处）与合集墙卡 `_buildCollectionCoverCard`。
  `fde80d7189`（series-first 拆库）把页面拆成 `home / series / allVideos` 三个 section 后，墙格 sliver
  （`_buildLocalVideoSlivers` / `_buildAllVideoSlivers`）只挂在 `series` / `allVideos` 上，`home` 只剩
  `_buildOverviewSection`（hero + 继续观看 / 下一集 / 最近添加 三条横滚行）。横滚卡 `_buildRowMediaCard`
  自引入起就没有标签层，于是拆分当天起首页的视频卡一个标签都不显示——标签本身写穿了 DB，只是没人画。
  第二处缺口（用户复问「不是能看见远端的标签吗」查出）：互联远端条目的标签**一直在清单里**
  （`RemoteVideoInfo.tags`，host 侧 `app_model_library_host_service.dart:1349` 填充、client `fromJson` 解析），
  但 UI 一处都没画——墙格远端占位卡 `_buildRemoteVideoCard` 的封面左上角只有字幕角标，横滚远端卡同样空着。
  远端卡没标签不是「没数据」，是渲染缺口。
- **[x] ① 已修复** — `_buildRowMediaCard` 增加 `tags` 参数并在封面左上角（top:6/left:6，与墙卡同位同形）渲染
  `_buildTagLabels`；继续观看散卡 / 继续观看合集卡 / 最近添加卡 / 两张远端横滚卡五个调用点接上数据源。
  标签数据归一成 `_VideoTagChip = ({String label, Color? color})` 一种形状：本地条目带库里的颜色
  （`_videoBookTagChips` / `_collectionTagChips`），远端条目 host 只下发标签名（标签本身每设备本地），
  `_remoteTagChips` 按名借本机同名标签的颜色、没有就走 chip 默认色——本地卡与远端卡因此共用一条渲染路径，
  不再各画各的（首页当初漏画，正是因为标签只跟着墙卡那一处写法走）。墙格远端占位卡的左上角改成一列：
  标签 chip 在上、字幕角标在下，两者不再抢同一个角。
  提交：`e3a9846904`（首页横滚卡）+ 本分支远端标签补画提交。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_home_row_tags_test.dart`（6 条 widget 行为断言：
  继续观看散卡显示自己的标签且不铺到邻卡、最近添加卡、继续观看合集卡、继续观看远端卡显示 host 下发的标签、
  远端标签借本机同名颜色 / 本机没有则为 null、「全部视频」墙格远端卡显示标签且字幕角标不被挤掉）。
  变异实测两轮，都是行为变异配行为守卫：① 给标签层加 `&& !kMutationProbe1808` 关掉渲染 → 当时 3 条全红；
  ② 让 `_remoteTagChips` 恒返空 → 6 条里恰好 3 条远端断言红、3 条本地仍绿（证明两组断言不互相冒充）。
  两轮还原后文件 SHA-256 均与变异前逐字节一致（`6dee4a45…2eecf` / `a6b596e6…6f0f`）。
- **备注**：首页 hero 轮播（backdrop 大图）仍不画标签——那是整幅背景图版式，与卡片角标口径不同，本次未动。
  远端标签是 host 下发的**名字**，本机没有同名标签时只有名字没有颜色，这是标签「每设备本地」的既有模型决定的，
  不是本次可修的范围。
