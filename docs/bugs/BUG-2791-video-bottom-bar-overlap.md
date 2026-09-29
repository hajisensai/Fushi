## BUG-2791 · 开字幕列表后视频底栏按钮叠在一起
- **报告**：2026-09-29（用户：截图——开右侧字幕列表后底栏「+10s」挤进音量图标，布局叠成一块，要求按宽度自适应）
- **真实性**：✅ 真 bug。两处根因叠加：
  1. `fushi/lib/src/pages/implementations/video_fushi_page.dart` `_hasRoomyVideoBottomBar` 读的是**整屏宽** `MediaQuery.size.width >= 600`。右侧字幕列表打开后屏幕仍宽、播放区（底栏）只剩一部分，带文字标注的 ±10s 照样摆出来，把传输簇撑宽。
  2. 同文件 `_centeredBottomControlBar` 用三区 `Stack` 绝对定位（`Center(传输簇)` + `Align(centerLeft)` + `Align(centerRight)`），三区互不知道对方宽度，底栏一窄居中簇与右簇就在同一段 x 上叠画。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_bottom_bar_slots.dart`（`VideoBottomBarSlots` + 纯函数 `videoBottomBarCenterStart`）：左右两簇按固有宽先拿、中簇只拿两簇之间的空隙；放得下时 play 仍钉几何正中（BUG-257 不变），放不下时在空隙里平移，再不够就 `FittedBox` 等比缩小，任何宽度都不重叠。±10s 标注判据改为 `LayoutBuilder` 给出的**底栏自身宽度**。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_bottom_bar_slots_test.dart`（纯函数四档 + 真布局：宽时居中、640 宽平移不压右簇、500 宽缩小不重叠）；源码守卫 `video_play_center_seek_labels_guard_test.dart` / `video_mobile_controls_guard_test.dart` 改钉新布局与按底栏宽判据（禁止回退到 `Stack`）。
- **备注**：未真机复测（media_kit 控制条跑不了 headless，几何由真布局 widget 测试覆盖）。
