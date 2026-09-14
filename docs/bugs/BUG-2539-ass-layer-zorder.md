## BUG-2539 · ASS Layer 不参与绘制 z 序（招牌盖住对白）
- **报告**：2026-09-14（Discord 用户 moonbeam：「the handwritten text being drawn on top of the subtitle when it should be on the layer underneath」，MPC 同帧对照里对白压在招牌之上）
- **真实性**：✅ 真 bug。`Layer` 列被解析（`ass_parser.dart`）后只用作分组键后缀（`video_subtitle_overlay.dart` `_positionKey` 的 `:L<n>`），各组按活跃集**发现顺序**进 `Stack`——谁靠后谁在上；发现顺序 = 活动集下标升序 = `setCues` 按 `startMs` 排序后的顺序，而 Dart `List.sort` 不稳定，同一起始时间的招牌 / 对白连文件先后都会被打乱。libass 是先按 `Layer` 升序、同层再按事件序绘制。
- **[x] ① 已修复** — 新增纯函数 `sortCueGroupsForPaint`：分组按 `(markup.layer, 组内最小 sentenceIndex)` 稳定排序后再进 Stack（分组键不变，element 复用不受影响）；`ass_parser.dart` 与 `VideoPlayerController.setCues`/`setSecondaryCues` 的 `startMs` 排序改为带原序 tie-break 的稳定排序（`_sortedByStart`），同起始时间保持文件序。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_layer_zorder_test.dart`（`sortCueGroupsForPaint` Layer 升序 / 同层事件序 / 稳定 / 单组原样；widget：Layer 0 招牌在文件里排在 Layer 1 对白之后仍先画）；`ass_drawing_parse_test.dart` 里 40 条同起始时间事件的稳定排序。
- **备注**：同层 z 序的 tie-break 是「按起始时间排序后的顺序」——跨起始时间的事件文件序在 `AudioCue` 里没有单独保存，与 libass 严格文件序的差异只在「同层、起始时间不同、文件序倒置」的极端排法上出现。
