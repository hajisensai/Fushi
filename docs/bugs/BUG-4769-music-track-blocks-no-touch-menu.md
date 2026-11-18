## BUG-4769 · 色块样式曲目格在触屏上打不开曲目菜单（多选 / 从歌单移除 / 加入队列等只有右键入口）
- **报告**：2026-11-17（修 BUG-4768 时沿同一路径发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_track_list.dart` `_blockBody`（:1056 起）色块格只包 `menu.contextMenu`（右键）；本地曲目格长按非多选态 = 曲目详情（:1090），远程曲目格长按非多选态 = null（:1135）；`MusicTrackBlock`（`music_track_row_surface.dart:244`）没有行尾 / 角标按钮位。触屏用户在「色块」样式的歌曲 / 歌单页同样进不了多选、点不到「从这个歌单移除」、加入队列等。
- **[ ] ① 未修复** — 这轮修不了：色块格没有放「⋯」的位置，要在 `FushiCoverBlock` / `MusicTrackBlock` 上加角标按钮或改长按语义（本地 = 详情 vs 进多选），属交互设计取舍，需另定方案（可上拍板台）。
- **[ ] ② 未加自动化测试** — 方案定后在 `music_track_selection_test.dart` 补「色块样式触屏开菜单 → 多选 / 从歌单移除」。
- **备注**：行样式已由 BUG-4768 补「⋯」。
