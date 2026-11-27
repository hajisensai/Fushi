## BUG-5593 · tts-studio-voice-picker-no-add
- **报告**：2026-11-27（用户：应用内反馈 cAteTpUDap 第 ② 项）
- **真实性**：✅ 真 bug。有声书制作台「声音」行 `fushi/lib/src/media/audiobook/tts/studio/tts_studio_page.dart:1630`（修前）`onTap: _presets.length > 1 ? … : null`，只有一个声音时点了没反应；`_pickPreset`（修前 `:365`）与角色配音 `_pickCastVoice`（修前 `:668`）、未配音页「指定声音」`tts_unvoiced_page.dart:139`、漫画有声 `manga_audio_studio_page.dart:261` `_pickVoice` 的 `showFushiChoiceDialog` 只列已有声音；「添加声音」流程只活在朗读声音页的私有 `_TtsVoiceSettingsPageState._add`（`tts_voice_settings_page.dart:357`），制作侧够不着。分诊说的「`tts_cast_lines_page.dart` 角色配音选择弹窗」实际是选说话人（不是选声音），角色配音弹窗在 `tts_studio_page.dart` 的 `_pickCastVoice`。
- **[x] ① 已修复** — 「添加声音」抽成唯一实现（`fushi/lib/src/media/audiobook/tts/tts_voice_settings_page.dart` 末尾「添加声音」一节；合并时从单独文件折回此处，免得多一个 import 环内节点）（`runTtsVoiceAddFlow` / `addTtsPresetFor` / `openTtsLocalDeployPage`），朗读声音页改调它；制作侧声音单选弹窗统一走 `showTtsVoicePickDialog`（末尾固定「添加声音」，加完回填并选中；新声音还用不了时直接打开它的编辑页），覆盖制作台默认声音、角色配音、未配音页指定声音、漫画有声各声音弹窗；默认声音行不再按数量禁用。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/tts/tts_voice_settings_add_flow_test.dart`（单声音时弹窗有「添加声音」且回填新 id、选已有不跑添加、添加取消返回 null、`addTtsPresetFor` 落盘与使用中语义）。
- **备注**：重试候选声音（多选）弹窗未加入口，仍可经「朗读声音」行添加。
