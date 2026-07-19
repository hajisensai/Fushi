## BUG-926 · 视频卡对标准 16:9 封面留空隙·封面比例随标题长短浮动
- **报告**：2026-07-19（用户：视频卡不对，对标准 16:9 都有空隙）
- **真实性**：✅ 真 bug。根因：视频 tab（`home_video_page.dart`）视频卡封面区比例不是固定 16:9，而是「cell 高 − 下方文字块高度」的剩余。
  - cell 高已按 16:9 预算：`_videoCardExtent(cardWidth) = cardWidth × 9/16 + _kVideoCardTextBlock(83)`（`home_video_page.dart:2760/2764`），意图 = 16:9 封面 + 83px 文字块。
  - 但封面用的是 `Expanded`（本地卡 `_buildCard` `home_video_page.dart:2875`、远端卡 `_buildRemoteVideoCard` `:2419`），吃掉的是「cell 高 − 下方文字块**实际**高度」的剩余。文字块高度随标题行数（1/2 行）、有无观看进度行浮动（≤83），文字不足 83 时多出的空间灌进封面区、使封面区高于 16:9。
  - 封面 `BoxFit.contain`（`_buildCover:3166` / `_buildRemoteVideoCover:2510`，TODO-616C 守卫要求不裁切）把 16:9 源等比放进偏高的封面区 → 上下留空带（letterbox）。标题满 2 行时文字块≈83、封面≈16:9 无空隙；标题短 / 无进度时空隙明显——故「时有时无、都有空隙」。
- **[x] ① 已修复** — 封面 Stack 从 `Expanded` 改为固定 `AspectRatio(aspectRatio: 16 / 9)`（本地 + 远端两张卡），封面比例与标题长短彻底解耦、永远精确 16:9，标准 16:9 封面 `contain` 后无空隙；文字块下移进 `Expanded`（占封面下方剩余固定高度 = cell 高 − 16:9 封面 = `_kVideoCardTextBlock`，标题/进度 `ellipsis` 内收，永不溢出）。未动 `BoxFit.contain`（保留 TODO-616C 不裁切决策）。提交哈希：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_card_cover_aspect_guard_test.dart`：源码扫描守卫，断言 `_buildCard` / `_buildRemoteVideoCard` 封面用 `aspectRatio: 16 / 9` 锁定、且不得回退到 `Expanded(child: Stack(...))` 的浮动比例写法；`video_cover_fit_guard_test.dart`（`contain` 不裁切）保持通过。提交哈希：<待填>
- **备注**：develop 上书架/历史页视频卡分区已删（`card_widgets.part.dart:188`「视频卡归视频 tab」），合集详情剧集缩略图已 96×54=16:9+cover 无空隙、合集网格详情页只装 EPUB/SRT 书卡——故视频卡封面面仅 `home_video_page` 两卡，改动已覆盖全部。真机验证：Windows 离屏 / 模拟器 复测「标题 1 行的视频卡封面无上下空隙」「标题 2 行 + 有进度行封面不溢出」。
