## BUG-4131 · 音乐推荐页「我喜欢的音乐」贴着筛选条、底下多 8dp；歌单页签按钮 / 段头层级不齐
- **报告**：2026-11-06（用户：截图反馈，音乐模块推荐页 / 歌单页签）——推荐页第一块「我喜欢的音乐」紧贴来源筛选条，和下一段之间却比其余各段多出一截；歌单页签「新建歌单」按钮比同行的刷新、推荐页「私人电台」大一号，「<插件> · 我的歌单」段头比「本地歌单」大一级。
- **真实性**：✅ 真 bug（排版节奏不一致）：
  - `fushi/lib/src/pages/implementations/music/music_plugin_pages.dart:1937`（develop fd09429392）`_LikedMusic` 用 `EdgeInsets.only(bottom: gap)`：上方 0、下方多 8dp，而下一段段头自带 section 上边距，于是上贴下松；
  - `fushi/lib/src/pages/implementations/music/music_track_actions.dart:191` `musicCreatePlaylistButton` 用 `FushiButtonSize.m`，同行其余动作是 S 号；
  - `music_plugin_pages.dart:688` `_SectionHeader` 分组段头也用推荐页大段标题的 `titleLarge`，与「本地歌单」（titleMedium）不同级。
- **[x] ① 已修复** — PR #2963（6cf4b9aa6a）：`_LikedMusic` 改为上方一个 gap、下方不留白（与下一段之间正好一个 section）；「新建歌单」改 S 号；分组段头改 titleMedium。
- **[ ] ② 未加自动化测试** — 纯排版间距 / 字号层级，现有改动没有对应断言；可落地层是 widget 测试量「筛选条底 → 首块顶」与「首块底 → 下一段段头」的像素间距，待补。
- **备注**：未在真 app 里看像素（PR 作者注明需用户确认观感）。
