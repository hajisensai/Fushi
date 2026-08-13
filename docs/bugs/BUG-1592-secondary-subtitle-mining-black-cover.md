## BUG-1592 · 只开副字幕时制卡：无区间→封面抽片头黑帧
- **报告**：2026-08-13（用户：「制卡黑屏」+ 卡片照片；随后澄清「副字幕的问题，我主字幕关掉的只开副字幕，副字幕是不是不能制卡。让副字幕也能制卡」）。用户包 `1.4.0-debug.10405`。
- **真实性**：✅ **真 bug**（沿真实代码路径坐实）。用户照片里卡片图片是**一整块纯黑**：把该区域裁出来提亮（brightness +0.35 / contrast 2.2）后仍是纯黑、且带 Lapis 图片 CSS 的圆角，**没有破图图标、没有 alt 文本**——说明图片解码成功、像素本身就是黑的，不是 Anki 打不开 AVIF。另用随包 `third_party/ffmpeg-min/windows/ffmpeg.exe` 按 `buildFfmpegClipAnimatedArgs` 的真实参数（`libsvtav1 -preset 8 -crf 32 -pix_fmt yuv420p`）对 8bit H.264 与 10bit HEVC 源各跑一遍，产出 AVIF 均正常（YAVG≈126），**排除编码链黑图**。
  根因链：
  1. `fushi/lib/src/media/video/video_subtitle_overlay.dart` 的字幕命中项（`SubtitleCharHit` / `_SubtitleCharEntry`）只回传 `sentence` / `graphemeIndex` / `charRect`，**不带所属 cue**——尽管 entry 自己知道 `isSecondary`、且它就诞生在按 cue 渲染的循环里。
  2. 于是页面侧 `video_fushi_page.dart:_handleSubtitleLookupTap` 不传 `overrideCue`，`lookup_favorite.part.dart:_lookupAt` 只好用 `resolveVideoLookupAnchorCue(currentCue: controller.currentCue, cues: controller.cues)` 去**主字幕流**按播放位置猜锚点。
  3. 用户把主字幕关掉、只开副字幕 → `controller.cues` 恒空、`currentCue` 恒 null → `_lastLookupCue` 恒 null。
  4. `video_fushi/lookup_mining.part.dart:_resolveVideoMiningRange` 三级兜底全落空 → 返回 `clipStartMs: 0, clipEndMs: 0`。
  5. `mining/immersion_mining_engine.dart:_mineNow` 的封面阶梯：`tryGif()` 因 `req.hasRange` 为假直接 null（**静默、不记日志**），落到 `tryStartFrame()` → `extractVideoFrameViaFfmpeg(atSeconds: 0/1000 = 0.0)` → ffmpeg 抽视频**第 0 秒**的帧 = 片头黑帧。尺寸正确、像素全黑，即用户看到的「制卡黑屏」。句子音频同样因区间为 0 而空。
  连带（同一根因的第二个症状）：`_setSentenceContextToDraft` 在 `controller.cues` 里 `indexOf(anchor)`，副字幕锚点恒 -1 → **上下 N 句上下文静默失效**；主副同开时点副字幕会**错锚到主字幕那句**（卡片句子是副字幕、音频/画面却截自主字幕那句的时间窗）。
- **[x] ① 已修复** — 本提交。消除「猜锚点」这一整类特殊情况，而不是加「若副字幕则……」分支：
  - `video_subtitle_overlay.dart`：`_SubtitleCharEntry` 携带所属 `AudioCue`；`SubtitleCharHit` 加第四元 `cue`；两个命中构造点（`_charHitTest` 点击/barrier 反查、`_charHitByEntryIndex` 手柄选词光标）与 `onCharTap` / `onCharHover` 回调一并带出 → **点哪条锚哪条**，主 / 副 / 重叠同一口径。
  - `video_fushi_page.dart`：`_handleSubtitleLookupTap` / `_handleSubtitleHoverLookup` 收下 cue 并作 `overrideCue` 透传给 `_lookupAt`；三处命中消费点 + `subtitle_caret.part.dart` 的手柄确认路径同步透传。
  - `video_player_controller.dart`：新增 `miningCues`（主流非空取主流，主流为空落副流）与 `cueStreamOwning(cue)`（按身份定位锚点所属流，都不含则回落 `miningCues`）。
  - `lookup_favorite.part.dart` 的锚点兜底、`lookup_mining.part.dart` 的 `_resolveVideoMiningRange` 按位置兜底改走 `miningCues`（服务「没有命中项」的入口，如无查词直接制卡）；`_setSentenceContextToDraft` 改在 `cueStreamOwning(anchor)` 里取邻句。
- **[x] ② 已加自动化测试** — 两支，均**变异实测**过（反向替换还原，未用 `git checkout --`）：
  - `fushi/test/media/video/video_secondary_subtitle_mining_anchor_test.dart`（8 例）：只开副字幕时点副字幕 → 锚点 cue 时间窗是真实的 `12000..15000`（黑图根因的正反面）；主副同开时点副/点主各自不串层；`hitTester` 反查与手柄光标命中同样带 cue；`miningCues` / `cueStreamOwning` / 只开副字幕时 `resolveMiningCueForPosition` 非空。
  - `fushi/test/pages/video_secondary_subtitle_anchor_wiring_guard_test.dart`（4 例）：源码断言页面把命中 cue 当 `overrideCue` 透传、兜底解析走 `miningCues`、上下文走 `cueStreamOwning`——widget 测试证明不了「页面转手用没用」，多收一个参数随手丢掉照样编译。
  - 变异记录：① `miningCues => _cues` → 2 例红；② `cueStreamOwning` 恒返回主流 → 1 例红；③ `_charHitTest` 回退 `currentCue ?? e.cue` → **首轮全绿（守卫有洞）**，遂把 `hitTester` 用例改成主字幕同时在放（`currentCue` 非空）才能证伪，再测 → 红；④ 同款变异打在点击路径 `_charHitByEntryIndex` → 红；⑤ 摘掉 `overrideCue: cue` 透传 → 接线守卫红。全部还原后 12 例绿。
- **备注**：
  - 用户随卡片一起贴的另一条日志 `DictionaryMedia.cache 词典「大辞林　第四版」取不到媒体字节: daijirin2/可能-default.svg` **与本 bug 无关**，是词典媒体（外字/结构化内容图）没取到字节导致该条媒体退成 alt 文本，不影响封面。已单独排查到 `native/fushidicts/fushidicts_src/query.cpp:get_media_file_view`（对 `media.idx` 做二分），写入端 `importer.cpp:write_media_idx` 的 `std::ranges::sort` 与读取端比较器口径一致（都是 `char_traits<char>` 无符号字节序），未坐实为排序错；剩余候选是「该词典的 media 根本没导进去 / zip 条目名编码非 UTF-8」，需要用户那本词典才能定性——**未修，另立条目跟踪**。
  - 未做真机复测（用户机器，本机没有该视频与该字幕组合）；本轮验证是 `flutter analyze` 全绿（含 test 目录）+ 上述 12 例守卫 + 相邻字幕/查词定向测试。
