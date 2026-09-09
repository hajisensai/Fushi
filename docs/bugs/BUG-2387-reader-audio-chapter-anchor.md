## BUG-2387 · 有声书恢复只定位章节却当作句子恢复成功
- **报告**：2026-09-09（用户：可能已经到章节，但章内跳转失败）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart:560` 无 fragment 的 href/正文兜底只找章节，随后以 progress=0、无字符锚返回 true，实际上没有尝试章内定位。此结论来自代码，尚未确认用户视频命中此分支。
- **[x] ① 已修复** — `1fe98e7901`：在已定位章节中用 `ReaderAudioPositionIndex.studyRangeForUniqueText` 唯一匹配归一化字幕文本并转换成阅读学习单位字符锚，首文档直接恢复到句子。未命中/重复/无学习字符则返回 false，由调用方回退阅读存档；已有 fragment 仍信任持久化坐标，不因 ASR 文本差异重匹配。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audio_position_test.dart` 覆盖章内非零位置、拉丁单词/扩展汉字/ruby 坐标、空/未命中/重复/重叠重复与生产接线。结合音频来源与账本边界及跨章坐标回归共 76 项通过。
- **备注**：无原始书籍/设备日志，不能将此分支缺口等同于已确认的视频根因；iPhone 两次开书、章内恢复和统计 DB E2E 未运行。SRT 切章分数路径本轮不改。
