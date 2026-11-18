## BUG-4821 · 字幕手改的存储键在输入框关闭后才取：编辑期间换了字幕源，改动存到新源名下
- **报告**：2026-11-17（优化计划代码复核 gap-disc-8 第 6 项；非用户反馈）
- **真实性**：✅ 真 bug（读代码确证，触发面窄，未在真机复现）。根因（修前，基准 `1f7e30e4168`）：`fushi/lib/src/pages/implementations/video_fushi/subtitle_text_edit.part.dart:50-75` `_editCueText` 先 `await showFushiTextInputDialog(...)`，`:85-86` 在 `_saveCueTextOverride` 里才读 `_subtitleTextOverrideVideoKey` / `_subtitleTextOverrideSourceKey`。输入框开着时视频是暂停的，但整轨转文字 / ASR 完成会换 `_currentSubtitleSource`；这时保存，覆盖行就写到新源的键上——原来那条字幕没改成，新源里多一条（起点 + 原文）对不上的覆盖。
- **[x] ① 已修复** — `d0e8119d3a2`。`_editCueText` 在暂停 / 弹输入框之前取 `(videoKey, sourceKey)`，作为参数交给 `_saveCueTextOverride`；保存只用传进来的键。写完时当前层已经不是这一层（期间换了源 / 换了集）就不重读覆盖层——当前层没有变化。`_restoreCueText` 是同步路径，传此刻的键。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_subtitle_text_edit_key_guard_test.dart`（源码扫描守卫）：键的读取先于 `_editCueText` 里第一个 `await` 与 `showFushiTextInputDialog`；`_saveCueTextOverride` 体内不再读「当前源」的键、只用 `keys`。编辑流程挂在整页 State 的 part 上，起整页做 widget 测试要带播放器与库，所以落在源码守卫这一层。
- **备注**：真机未验：开着编辑输入框的同时让整轨转文字 / ASR 完成并换源，保存后改动应落在原字幕源，切回原源能看到。
