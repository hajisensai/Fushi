## BUG-1989 · 全部视频横竖混排导致缩略图比例不一致并在宽屏留下大块空白
- **报告**：2026-08-31（用户：截图反馈“视频的缩略图大小比例显示不一致，而且右边有大量空白的位置”）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/home_video_page.dart:_buildAllVideoSlivers/_buildVideoWallSliver`：全部视频与系列页共用按封面固有朝向改变卡宽的 `Wrap` 墙；统一封面高度下，16:9 横卡约为 2:3 竖卡宽度的 2.67 倍，左对齐换行时剩余宽度常放不下下一张横卡，形成截图中的大块行尾空白，同时同一条目列表出现两种卡片比例。
- **[x] ① 已修复** — `a86120bb77`：全部视频改走独立的 16:9 等宽 `SliverGrid`，按内容宽度响应式计算 2–5 列并等分整行；竖版海报继续复用 `PortraitCoverImage(landscapeSlot: true)` 的完整前景 + 模糊垫底，不裁切、不变形。系列页仍保留 2:3/16:9 混排墙。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_home_layout_test.dart` 钉住响应式目标宽；`fushi/test/pages/home_video_remote_mixed_grid_test.dart` 验证本地/远端卡同属一个 `SliverGrid`、尺寸相同且封面槽均为 16:9；架构守卫同步区分系列混排墙与全部视频等宽网格。
- **备注**：按用户要求直接提 PR，本轮未运行 Flutter 测试；定向 `dart analyze` 因 Analysis Server 无法删除全局 perf 文件而内部崩溃，未取得静态分析通过结果。Windows 原始截图路径仍待设备肉眼复测。
