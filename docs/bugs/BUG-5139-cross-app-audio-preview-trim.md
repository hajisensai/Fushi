## BUG-5139 · 跨应用语音缓存：制卡前试听 + 调起止（波形选区）两端都还没有
- **报告**：2026-11-22（拍板台 design-cross-app-audio-desktop 范围第 4 项「试听 + 调起止（复用 galgame_waveform_select_dialog.dart 的波形选区）——Android 也缺，可一并做」；本轮 PR 只做了第 1～3 项）
- **真实性**：✅ 功能缺口（已拍板「做」的剩余部分）。现状：应用外查词制卡的句子音频只走自动截句 `crossAppAudioDefaultRange`（`fushi/lib/src/mining/cross_app_audio/cross_app_audio_clip.dart`），`prepareCrossAppSentenceAudio` 已留好 `range` 参数，但没有任何入口让用户先听、再拖起止。Android 查词窗（`:popup` Flutter 引擎，`fushi/lib/src/pages/implementations/dictionary_page_mixin.dart` 的 `_prepareMiningSentenceAudio`）与电脑端全局查词浮窗（WebView2 覆盖窗 popup.js，制卡走 `fushi/lib/src/lookup/overlay_bridge_handlers.dart` 的 `prepareOverlaySentenceAudio`）都缺。
- **[ ] ① 未修复** — 待做：Android 在查词窗里接 `showGalWaveformSelectDialog`（快照 `materialize` 后读 PCM 成 `GalAudioSlice`，选区传给 `prepareCrossAppSentenceAudio(range:)`）；电脑端覆盖窗不是 Flutter，要么在 popup.js 里画波形选区、要么制卡前把主窗口唤起弹 Flutter 对话框——两条路的交互不同（是否抢前台焦点、是否打断游戏），动手前先在拍板台列取舍。
- **[ ] ② 未加自动化测试** —
- **备注**：
