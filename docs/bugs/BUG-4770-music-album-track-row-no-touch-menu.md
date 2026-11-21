## BUG-4770 · 专辑页本地曲目行在触屏上打不开曲目菜单（加入队列 / 加入歌单 / 从音乐库移除只有右键入口）
- **报告**：2026-11-17（审查 PR #3648 / BUG-4768 时沿同一根因发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_album_page.dart` 专辑曲目行（重设计行 `MusicTrackRowSurface` 的 `trailing` 只有多选勾、eink 旧行 `FushiListItem` 同样无「⋯」）的菜单只经 `withMenu(...).contextMenu`（:750，右键 / 上下文菜单键）挂上；长按非多选态 = 进多选（`sel.longPress`），所以多选触屏可达，但同一份 `musicLocalTrackMenu` 里的接着播 / 加入队列 / 曲目详情 / 加入歌单 / 从音乐库移除在触屏上没有入口。BUG-4768 只补了 `music_track_list.dart` 与统一搜索的本地行，专辑页未覆盖。
- **[x] ① 已修复** — 拍板台 left3648「直接做」：与列表样式一致，专辑曲目行尾补 `menu.button()`（「⋯」，命中区 ≥48dp）：重设计行 `music_album_page.dart:865`、eink 旧行 `:909`；多选态行尾换成勾选圈。行长按仍 = 进多选（未动）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_track_selection_test.dart`「触屏：专辑页曲目行尾「⋯」开菜单，从音乐库移除真落库」（eink=false / true 各一条：菜单有加入队列与多选，点从音乐库移除真落库；多选态不再出「⋯」）。
- **备注**：同根因：以为「本地菜单只有播放 / 详情」的前提已过时。
