## BUG-2907 · 有声书当前句高亮不含句末标点与句首括号
- **报告**：2026-10-03（用户：iOS 竖排 VN 截图里「…声援が飛ぶ。」的「。」落在当前句高亮框外；要求按 Hoshi Reader Android 的做法处理）
- **真实性**：✅ 真 bug。cue 的 `{start, length}` 按可匹配字（假名 / 汉字 / 字母数字）计数，两条高亮路径都只把**首个到末个可匹配字**映射回 DOM：
  - 翻页 / 滚动：`fushi/lib/src/reader/reader_pagination_scripts.dart:1694` `rangesForNormSpan` 按归一化索引（只含可匹配字）分组，只补「同一文本节点内」被跨过的标点 → 句末「。」「！」、句首「「」不进高亮；**夹在两个文本节点之间的句内标点**（如注音「鬱」两侧的「」）也不进。
  - VN：`fushi/lib/src/reader/reader_visual_novel_scripts.dart:768` `collectMatchableSegments` 在 `cursor === end` 处就收尾 → 同样漏掉句末标点与句首括号。
  - 参照：Hoshi Reader iOS（Manhhao develop，`ReaderWebView/reader.js` `collectSasayakiCueRanges`）与 Fushi 旧行为相同；Hoshi Reader Android（HuangAntimony，`reader-text-semantics.js` `createSasayakiTextIndex` + `reader-dom-text.js` 块边界）按标点方向归属：收尾类并进前一字、开头类并进后一字、中性类跟随前文（前文是开头类 / 空白 / 段首时跟后文）、块级元素与 br / 图片等屏障两侧互不归属。
- **[x] ① 已修复** — 新增共享脚本 `fushi/lib/src/reader/reader_sentence_audio_ownership_script.dart`（`window.fushiSentenceAudioOwnership.extendSegments`，归属表与 Android 一致），由 `engineShell` 在任何 shell 安装前注入；翻页 / 滚动的 `collectSentenceAudioCueRanges` 与 VN 的 `collectMatchableCueRanges` 都把片段交给它放宽：同一块内两段之间的缝整段补上（一句是一段连续原文），首尾与块边界两侧按标点归属放宽，跨块不补缝。cue 坐标、重定位匹配器、学习字数一律不动；每个标点只归一侧，相邻两句不重叠。
- **[x] ② 已加自动化测试** — `fushi/test/reader/sentence_audio_ownership_behavior_test.dart`（node 真跑生产常量：句末句号、对白括号、跨节点 / 注音后的收尾标点、块边界、中性类四种归属、空白 / br / 图片屏障、相邻句不重叠、星平面字、句内跨节点补缝、跨段 cue、输入不被改写；另以源码断言钉住三种 shell 都注入、两条路径都调用）。两处变异（去掉起点放宽、去掉 VN 接线）均被抓到。
- **备注**：
  - 三种 view mode 实测（Playwright WebKit + Chromium，真书 part0035，393×852、40px 竖排，真引擎 + 生产 CSS）：翻页 / 滚动 / VN 下「…声援が飛ぶ。」整句含「。」，「「撃つ」と「鬱」のダブルミーニング！」首尾括号、注音两侧的「」与「！」全部进高亮。VN WebKit 下前一句在本分支基线上会被 BUG-2905 切成两屏（只亮得到前一屏），叠上 BUG-2905 的修复后同样通过。
