## BUG-144 · 有声书查词制卡词条音频复用旧词且句子音频/句子上下文错位
- **报告**：2026-06-08（用户：有声书制卡，感觉查词的音频和句子音频不对啊）
- **真实性**：✅ 真 bug。根因在 `hibiki/assets/popup/popup.js:21` 的查词音频缓存只按 entry index 保存，换词后同 index 复用旧词音频；同时 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2778` 把整书归一化 `sentenceRange.offset` 传给 `AnkiMiningContext.sentenceOffset`，但 Anki 渲染层把它当句内字符 offset 使用。
- **[x] ① 已修复** — 本提交：查词弹窗音频缓存按 expression/reading 匹配，reader 制卡使用句内 sentenceOffset，并为句子音频切片使用独立临时文件。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/popup_asset_behavior_test.js` + `hibiki/test/reader/reader_mining_audio_guard_test.dart`
- **备注**：本轮用 JS popup 行为测试覆盖“同 index 新词必须重新解析词条音频”，用 reader 源码守卫覆盖“Anki sentenceOffset 必须来自 `ReaderSelectionData.sentenceOffset`”和“句子音频切片不能复用固定临时文件”。有声书制卡跨 WebView/原生音频切片，仍建议后续用真实书籍+音频在设备/桌面复测一次查词制卡生成的 `ExpressionAudio` 与 `SentenceAudio`。

### 根因
- 查词弹窗 `audioUrls` 以 entry index 为唯一 key。热 WebView/同一 popup 复用时，新查词结果的第 0 个 entry 仍会命中旧的 `audioUrls[0]`，制卡 payload 的 `{audio}` 就可能是上一次查词的词条发音。
- reader 制卡时 `AnkiMiningContext.sentenceOffset` 使用 `_cachedSentenceRange?.offset`。这个值是用于收藏/高亮的整书归一化 offset，不是词在句子里的字符偏移；`AnkiHandlebarRenderer._sentenceValue()` 按句内 offset 加粗目标词，导致上下文标注错位或退回不可靠的 `replaceFirst`。
- 句子音频切片输出固定到系统临时目录的 `mine_sentence_audio.aac`。连续制卡/并发导出时缺少文件级隔离，后一次切片可能覆盖前一次还在落库的句子音频。

### 修复
- `popup.js` 增加 `audioCacheKey(expression, reading)` 和 `resolveCachedAudioUrl()`，缓存命中必须同时匹配 expression/reading；解析失败不缓存空结果，允许后续重试。
- reader 查词时单独缓存 `ReaderSelectionData.sentenceOffset`，制卡时传给 `AnkiMiningContext.sentenceOffset`，不再复用整书归一化 range。
- reader 句子音频切片每次创建独立临时目录和 `sentence.aac`，`mineEntry` 完成后清理目录。

### 验证
- `node hibiki\test\utils\misc\popup_asset_behavior_test.js`
- `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\reader\reader_mining_audio_guard_test.dart`
