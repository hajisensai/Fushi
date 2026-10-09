## BUG-3080 · 字幕样式预览字号调大后主副字幕串行
- **报告**：2026-10-07（用户：视频设置字幕预览，字号 36 时日文换行与中文重叠、顺序反转）
- **真实性**：✅ 真 bug。旧版 `fushi/lib/src/media/video/subtitle_style_preview.dart:279` 在固定 16:9 画布里独立定位主副字幕，392px 竖屏的画布只有 220.5px 高；换行后的文本盒加上默认两侧 75px 距离超过画布高度，两层相交。对应当前实现 `subtitle_style_preview.dart:267`。
- **[x] ① 已修复** — 顶组与底组按实际布局高度顺序排列，画布至少保持原视频区域高度，容纳不下时自然增高，再由 FittedBox 等比缩放；保留可容纳时的离边位置。使用实际布局而非 IntrinsicHeight 的估算值（交接版会低估换行高度并触发 RenderFlex overflow）。修复提交 `dccc7c1c88`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_style_preview_layout_test.dart`：字号 23/36/60/96、四种主副锚点组合、两种单层极限情况、桌面原始高度与实际离边距离，共 11 例，Mac Flutter 3.47.6 实跑 11/11、退出码 0；测试断言缩放后的实际几何位置。
- **备注**：
  - 播放器路径已核：`fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:592` 通过 Positioned.fill 覆盖完整播放容器；`fushi/lib/src/media/video/video_subtitle_overlay.dart:1255` 分层定位。本次 392×850 竖屏、字号36与默认边距条件下，播放器没有预览强制缩成 220.5px 高的限制，因此修复留在预览。极短播放器容器、大边距或同侧显式锚点的碰撞不在此次验证范围，不能泛称播放器永不相撞。
  - 截图保存在本机 `.codex-test/subtitle-preview-overlap/`；widget 像素截图不等同完整应用真机验证。ADB 检测到真机，本轮尚未覆盖其原始设置页面交互，设备肉眼复测待补。
