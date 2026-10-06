## BUG-3061 · 制卡上下文无法删除中间的旁白句
- **报告**：2026-10-06（用户：视频制卡「选择句子上下文」里，中间夹了一句旁白/语气词（截图里的「あい」）也被做进字幕；问能不能主动删，并说「删除了确定也还变回原样」）
- **真实性**：✅ 真 bug（设计缺口）。中间那句没有任何办法拿掉：
  - 「−」按钮只按句数从两端减（`setContext(prev, next)` 整体重解析，`fushi/lib/src/pages/implementations/sentence_context_dialog.dart` `_adjust`），中间句减不到；
  - 用户的直觉操作「编辑 → 清空 → 确认修改」在草稿层被**有意**当成还原：`fushi/lib/src/media/audiobook/mining_sentence_draft.dart:151`（修复前）`final bool restore = trimmed.isEmpty || trimmed == key;`，注释写着「用编辑框当删除键，那是「−」按钮的事」（:133）——可「−」恰恰做不到，于是句子原样弹回。
- **[x] ① 已修复** — 草稿层新增「移除」状态：`MiningDraftSentence.removed` + `MiningSentenceDraft.setSentenceRemoved`，与手改文本同样**按原句做键**（加减句数后宿主整体重解析，按下标会贴错句）。被移除的句子仍占上下文的位置（`length` 不变，宿主照常按句数重解析），但不进 `composeText`、也不参与 `composeAudioRange`（夹在中间时合并区间首尾不变；在两端时随之收窄）。预览新增 `prevRemoved`/`nextRemoved`，`total` 只数保留的句子（只认旧字段的消费方不受影响）。对话框前文/后文每张卡加「移除此句 / 恢复此句」按钮，移除后删除线显示；前文/后文清空后点「确认修改」= 移除这句（当前句清空仍是还原，当前句不可移除）。阅读器车道（`base_source_page` / `reader_fushi_page`）与视频车道（`dictionary_page_mixin` / `video_fushi_page`）都接上。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/mining_sentence_draft_test.dart`（group `setSentenceRemoved`：中间句移除不进文本、恢复、跨 setContext 跟着原句走、不进音频区间、当前句不可移除、与手改独立、clear 清掉、预览字段）+ `fushi/test/pages/sentence_context_dialog_widget_test.dart`（移除按钮 / 删除线 / 计数 / 恢复、前文清空确认 = 移除、当前句清空仍走还原、宿主不支持时不渲染）。
- **备注**：只验了单元 / widget 层，没在真机视频制卡链路上复测到 Anki 落卡。
