## BUG-2971 · 视频字幕遮蔽模糊在关闭尊重ASS样式时不生效
- **报告**：2026-10-05（用户/协作者 shishamo，Windows：选中外挂 `ja.ass`，字幕遮蔽=模糊、副字幕遮蔽=关闭、「暂停或悬停时显形」=开、「尊重字幕自带样式」=关 → 字幕清晰；把「尊重字幕自带样式」打开后模糊生效。截图里设置侧栏开着、指针在侧栏内。）
- **真实性**：❌ **overlay 层未复现**（根因未定，不是已修）。
  - 沿真实路径查过：两种开关状态的 `.ass` 都只走 Flutter 自绘层 `VideoSubtitleOverlay`（libmpv `sub-visibility=no`、media_kit `SubtitleView(visible:false)`，开关只在 `video_fushi/layout.part.dart` 一处传给 overlay，`subtitle.part.dart` 里只门控内嵌字体抽取）。遮蔽判据只有一处：`fushi/lib/src/media/video/video_subtitle_overlay.dart` `_buildSubtitleLayer`（`blurred = obscureBlurEnabled && !revealed && !userIsReading`，`userIsReading = 交互显形总闸 && (暂停 || 查词浮层开)`），与 respectAssStyle 无关；模糊视觉在 `_wrapInteractive` 里整组包一层 `ImageFiltered`，两条路径（纯字幕模式单 `plain` 组 / 尊重模式按位置分组）都经过它。
  - 用典型字幕组 ASS（OP 卡拉 OK 光晕层 `\blur4\1a&HFF&` + 主文字层 + `\N` 对白 + Comment 行）在 widget 测试里逐字形检查祖先 + 离屏像素采样：respect 开/关两种状态下，播放中所有字形都在遮蔽模糊（或隐藏的 Opacity(0)）之下、像素里零清晰亮字形；暂停同样显形；指针离开不显形、悬停显形；副字幕模糊对称。
  - 设置侧栏有全屏 `HitTestBehavior.opaque` barrier（`video_fushi/side_panel.part.dart`），侧栏开着时字幕层收不到悬停 → 截图那一刻的清晰不是悬停显形。剩下能让它清晰的只有「暂停」（设计如此：显形开关=开时暂停即显形，BUG-2198）或 overlay 之外的因素。
  - 待用户确认的两点：① 截图那一刻是否在**播放中**（暂停时两种状态都应清晰；开着「尊重」时 OP 光晕层自带 `\blur` 看起来像被模糊，容易误判为「模糊生效」）；② 提供该 `ja.ass` 原文件，以便在 overlay 层用真实事件复现。
- **[ ] ① 未修复** — overlay 层两种状态行为一致，没有可修的分叉；拿到原文件 / 播放态确认后再定。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_obscure_respect_parity_test.dart`（respect 开/关 × 模糊/隐藏/暂停/悬停/副字幕的行为契约 + 像素判据），守住两条路径不分叉。
- **备注**：副字幕遮蔽在同条件下同样检查过（测试最后一组），开/关一致。
