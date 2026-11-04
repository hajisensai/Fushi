## BUG-4006 · eggrolls 卡组复习时不播单词音频（卡面外壳不满足 Anki reviewer 的 DOM 契约）
- **报告**：2026-11-03（应用内反馈 `Feedback: uCPhpeCM35`，macOS 3.3.0-debug.23080：eggrolls 卡组复习时单词音频不自动播、点句子音频也不播；编辑笔记页能播）
- **真实性**：✅ 真（单词音频部分）。用户库里 eggrolls-JLPT10k-v3 背面模板按 Anki reviewer 的 DOM 写脚本：单词音频放在 `#qa` 直属的 `<div class="VocabAudio !hidden">`，由 `audioStylePatch()` 按 `#qa > .VocabAudio` 挪进标题行并去掉 `!hidden`；`forcePlayback()` 点 `.VocabAudio .replay-button`。Fushi 卡面外壳两处不满足：
  - 没有 `#qa`，正文直接写进 `#fushi-card-root`（`fushi/lib/src/pages/implementations/srs/srs_card_face.dart:939` `r.innerHTML = html`、:980 外壳 HTML），并且正文还被 `<div lang>` 包一层（同文件 :1216 `wrapAnkiCardHtmlWithLang`）→ 挪不动，单词音频一直 `display:none`，按 BUG-3983「只播看得见的」不进自动播放，卡面上也没有键可点；
  - `[sound:]` 渲染的按钮只有 `fushi-srs-sound` 类（`fushi/lib/src/srs/srs_card_media.dart:73`），没有 Anki 的 `replay-button soundLink` → `forcePlayback` 找不到。
  编辑笔记页不跑模板脚本，所以能播。「点句子音频不播」沿代码追到宿主播放（`kSrsCardMediaScript` 点击 → `onSrsPlaySound` → `SrsCardAudioSequencer` → `DesktopAudioPlayback.playFileToEnd`）链路完整，Chrome 契约测试里句子键点击也到达宿主；没有日志 / 录像，macOS 设备未复测，这一半 **未复现**。
- **[x] ① 已修复** — 外壳里加 `<div id="qa"></div>`，正文作为它的直接子节点写入，`lang` 挂在 `#qa` 上不再包裹（`__fushiSrsSetCard(refs, html, classes, lang)`、`SrsCardFaceDocument.lang`）；播放键类名改为 `kSrsSoundButtonClasses = 'fushi-srs-sound replay-button soundLink'`。提交 `b5267f3032c1a8b6c730697e0fbd333236e6e886`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_anki_dom_contract_test.dart` + `srs_card_anki_dom_contract_harness.mjs`（真 headless Chrome 跑生产外壳 + 用户库 eggrolls 背面的音频脚本原样：单词音频挪进标题行、上报可见、`forcePlayback` 点到宿主、句子键带 `replay-button` 且点得到；自动播放关时合成点击被拦）；`fushi/test/srs/srs_card_face_shell_test.dart`、`fushi/test/srs/srs_card_media_test.dart` 同步新契约。
- **备注**：macOS 真机复测原始失败路径（eggrolls 卡组复习单词自动播放 + 点句子音频）未做，待补。
