## BUG-2632 · VN 查词弹窗从此句播放误用屏内及学习单位坐标导致跳错位置
- **报告**：2026-09-22（用户：VN 模式查词框的「从此句播放」跳到奇怪的位置）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_selection_scripts.dart:1825` 的音频偏移从 `document.body` 开头累加；VN 正文是当前屏的克隆，整章源 DOM 已游离，因此非首屏查词上报的是屏内偏移。`reader_fushi/lookup.part.dart:263` 按该值反查章节 cue，弹窗 `reader_fushi_page.dart:4601` 将错误 cue 交给 `playCueAndContinue`。此外 `reader_visual_novel_scripts.dart:764` 的高亮区间及 `screenIndexForSentenceAudioCue` 把学习单位与音频归一化 UTF-16 坐标混用，拉丁词、数字串、辅助平面汉字会导致播放跟随再次错屏。
- **[x] ① 已修复** — `b9e9bc5e5cb`：VN 源流记录章节音频偏移，通过现有克隆/屏的原文码点坐标映射选区、音频高亮及 cue 跟随；普通阅读模式保留原有音频坐标路径。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_lookup_audio_coordinates_test.dart` 驱动真实 Chrome DOM，覆盖 5 个查词/跟随目标：首屏、非首屏重复句、混排、ruby、辅助平面汉字、单节点截屏及高亮拆节点；与相邻定向测试合计 49 项通过。`fushi/integration_test/reader_vn_lookup_jump_itest.dart` 覆盖 Windows app 竖排/横排「查词 → 从此句播放」。
- **备注**：全量 `flutter analyze --no-pub` 无问题；Windows 真 app 集成测试 1 项通过（竖排、横排各跑一次键盘查词 → 弹窗按钮）：第 7 屏选中 cue 6，跳转后仍为屏 6 / cue 6，播放时间分别为 60445ms、60469ms。真实 WebView 截图已核对，证据在主 checkout 的 `.codex-test/vn-lookup-jump/vn-lookup-jump/command.log` 与 `screenshots/vn-lookup-{vertical-rl,horizontal-tb}.png`。本轮不发布安装包。
