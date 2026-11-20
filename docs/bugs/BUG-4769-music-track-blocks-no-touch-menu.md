## BUG-4769 · 色块样式曲目格在触屏上打不开曲目菜单（多选 / 从歌单移除 / 加入队列等只有右键入口）
- **报告**：2026-11-17（修 BUG-4768 时沿同一路径发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_track_list.dart` `_blockBody`（:1056 起）色块格只包 `menu.contextMenu`（右键）；本地曲目格长按非多选态 = 曲目详情（:1090），远程曲目格长按非多选态 = null（:1135）；`MusicTrackBlock`（`music_track_row_surface.dart:244`）没有行尾 / 角标按钮位。触屏用户在「色块」样式的歌曲 / 歌单页同样进不了多选、点不到「从这个歌单移除」、加入队列等。
- **[x] ① 已修复** — 拍板台 left3648 定方案 B（色块不加视觉元素，长按改成开菜单，详情挪进菜单）。`MusicTrackBlock` 新增 `menu`（`music_track_row_surface.dart:292`）：调用方没给 `onLongPress` 时长按从色块自身矩形弹这份与右键同一份的菜单；多选态调用方给 `onLongPress` = 勾选，以它为准。所有色块调用点都接上：曲目列表本地 / 远程格（`music_track_list.dart:1091` / `:1135`，本地格原「长按 = 详情」去掉，详情本就在菜单里）、专辑页色块（`music_album_page.dart:828`，原「长按 = 进多选」改为开菜单，「多选」在菜单里）、插件歌单色块（`music_plugin_pages.dart:291`）、服务器曲目色块（`music_server_pages.dart:1485`，这两处原来长按什么都不做）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_track_selection_test.dart`「触屏：色块样式曲目格长按开菜单（有详情与多选），多选态长按 = 勾选」「触屏：专辑页色块长按开菜单，菜单「多选」进入；多选态长按 = 勾选」。
- **备注**：行样式已由 BUG-4768 补「⋯」。
