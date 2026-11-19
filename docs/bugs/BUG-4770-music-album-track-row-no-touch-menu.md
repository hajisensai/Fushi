## BUG-4770 · 专辑页本地曲目行在触屏上打不开曲目菜单（加入队列 / 加入歌单 / 从音乐库移除只有右键入口）
- **报告**：2026-11-17（审查 PR #3648 / BUG-4768 时沿同一根因发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_album_page.dart` 专辑曲目行（重设计行 `MusicTrackRowSurface` 的 `trailing` 只有多选勾、eink 旧行 `FushiListItem` 同样无「⋯」）的菜单只经 `withMenu(...).contextMenu`（:750，右键 / 上下文菜单键）挂上；长按非多选态 = 进多选（`sel.longPress`），所以多选触屏可达，但同一份 `musicLocalTrackMenu` 里的接着播 / 加入队列 / 曲目详情 / 加入歌单 / 从音乐库移除在触屏上没有入口。BUG-4768 只补了 `music_track_list.dart` 与统一搜索的本地行，专辑页未覆盖。
- **[ ] ① 未修复** — 专辑页行的交互与曲目列表不同（长按 = 多选、无「曲目详情」按钮），补不补「⋯」及与长按语义怎么配，留给与 BUG-4769（色块样式）一起定方案，本 PR 不扩范围。
- **[ ] ② 未加自动化测试** — 方案定后在 `music_track_selection_test.dart`（已有专辑页用例）补「触屏开专辑曲目菜单 → 加入队列 / 加入歌单」。
- **备注**：同根因：以为「本地菜单只有播放 / 详情」的前提已过时。
