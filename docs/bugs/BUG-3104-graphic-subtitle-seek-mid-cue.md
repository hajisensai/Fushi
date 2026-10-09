## BUG-3104 · 往回跳到图形字幕一句中间时不显示，要等下一句
- **报告**：2026-10-09（用户 + 开发者哈吉千歳：往回跳到某句字幕中间时字幕不显示，要等下一句开头才出来）
- **真实性**：✅ 真 bug，只影响 libmpv 渲染的**图形字幕**（PGS / VobSub）。文本字幕不受影响：Dart overlay 每拍
  （`VideoPlayerController._syncCueForPosition`）按当前时间从全部 cue 里重新求当前句，seek 后立刻是对的。
  根因 `fushi/lib/src/media/video/video_player_controller.dart` `selectEmbeddedGraphicTrack`：图形字幕一句只有一个
  「开始显示」的包，往回跳到一句**中间**时 demuxer 从目标附近的关键帧开始读，那句的开始包在更早的位置，mpv 没读到
  就不画；本仓从没设过 mpv 的字幕预读选项。
  - 复现（本仓随包 `libmpv-2.dll` + ctypes 驱动，`vo=image` 截帧比对哈希，2 分钟 1 s GOP 片源 + 合成 PGS 轨，一句显示
    60.02–62.02 s，从 95 s 往回 `seek 61.8 absolute`）：**m2ts 容器**默认设置下截帧与「不开字幕」逐像素相同（字幕没出）；
    设 `hr-seek-demuxer-offset=10` 后与该句正常显示的画面逐像素相同。Matroska 容器在文件带字幕 cue 索引
    （ffmpeg / 新版 mkvmerge 写的 CueDuration / CueRelativePosition）时 mpv 默认 `index` 模式已能预读，同一测试正常；
    无索引的 mkv 走默认只预读 1 s。
- **[x] ① 已修复** — 渲染图形轨时下发 seek 预读（`buildGraphicSubtitleSeekPrerollProperties`，`video_mpv_config.dart`）：
  `demuxer-mkv-subtitle-preroll=yes` + 10 s 窗口（Matroska，只多读数据不解码）；非 Matroska（读 mpv `file-format`
  判断）再加 `hr-seek-demuxer-offset=6`（mpv 对 ts 没有字幕预读，只能让精确 seek 提前解复用，代价是 seek 多解码这段）。
  关字幕 / 换片时还原成 mpv 默认值（`buildDefaultSubtitleSeekPrerollProperties`），文本字幕不为它多付 seek 代价。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_mpv_config_test.dart`「图形字幕 seek 预读（BUG-3104）」：
  两种容器的属性、还原值与开启时同一键集合、`file-format` 判据、控制器接线（选图形轨开预读、关字幕与换片还原）。
- **备注**：libmpv 行为本身无法在 flutter test 里跑（无 libmpv），上面的 ctypes 截帧复现是对真随包 libmpv 的验证。
  一句字幕显示超过 6 s 且往回跳到它 6 s 之后的位置（ts 容器）仍会缺这一句，属于提前量的取舍。
