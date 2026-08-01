## BUG-1321 · 选区与字幕文本不一致时长选区导出退化为单句音频
- **报告**：2026-07-31（用户报「电脑上较长片段导出」异常，沿代码路径验真时挖出的同域第二缺陷）。
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/reader_hibiki/audiobook.part.dart:1264-1269`（修复前）：`_buildAudiobookClipPlan` 在 `audiobookClipCueTextMatchesSelection` 判不一致时 `return null`——把**整段音频窗**（`globalStartMs/globalEndMs`，对长选区是唯一正确的裁剪范围）连同高亮计划一起丢弃。调用方 `_exportAudiobookClip:1043` 于是回退 `_currentSentenceAudioRange()`（currentSentence 单句锚），产物变成「完整选区文本卡片 + 只有第一句/当前句的声音」。长选区因 ruby/措辞/空白差异几乎必然文本不一致，故「较长片段导出」高概率踩中。BUG-968 引入该一致性门时只考虑了「不渲染字幕文本」，把音频窗当了陪葬；BUG-1243 修了「先计划后分类」的顺序，但 mismatch 路径仍整体丢计划。
- **[x] ① 已修复** —（见本分支提交）
  - `_AudiobookClipDynamicPlan` 新增 `cueTextMatches` 字段；`_buildAudiobookClipPlan` 文本不一致时**保留计划**（`cueTextMatches: false`），不再 return null——整段音频窗照常通过 `sentenceRange` 进入分类与裁剪。
  - `_exportAudiobookClip` exportable 分支：`cueTextMatches == false` 时仅置 `dynamicPlan = null` 禁用逐句高亮（静态精确选区卡，BUG-968「不渲染字幕文本」契约不变），音频仍裁整段选区。
- **[x] ② 已加自动化测试** —（见本分支提交）
  - `hibiki/test/media/audiobook/audiobook_clip_mismatch_window_bug1321_test.dart`：结构守卫钉住①一致性判定之后计划构建器不得再出现 `return null;`（丢窗即红）且判定结果以 `cueTextMatches:` 进计划；②dispatcher 用 `!dynamicPlan.cueTextMatches` 门 + `dynamicPlan = null;` 只降级高亮，且 `sentenceRange` 仍取计划整段起止；③计划模型带 `final bool cueTextMatches;` 契约字段。
- **备注**：既有 `audiobook_clip_export_contract_test.dart`「falls back before rendering differing cue text」扫描继续钉 BUG-968 契约（不一致绝不渲字幕文本）。真机上「长选区 + 粗对齐字幕」的导出复测缺口记 next。
