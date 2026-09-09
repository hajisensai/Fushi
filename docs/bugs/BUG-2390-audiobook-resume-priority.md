## BUG-2390 · 带有声书的小说仍让阅读位置覆盖音频位置
- **报告**：2026-09-09（用户：有声书存在时以有声书位置为主，避免重开乱跳和统计异常）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi_page.dart:2412` 原先按文字与音频更新时间仲裁。往前翻文字后的较新存档会压过暂停音频的落点。
- **[x] ① 已修复** — `773d4372a0`，复用本机既有 `b83831166a`：首个 WebView 创建前等待音频槽并恢复音频 cue；无可用音频落点才回退文字存档。显式书签/收藏仍优先。删除跨媒体 LWW helper 与不再使用的时间戳查询，保留同步层时间戳语义。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_resume_point_test.dart` 与 `fushi/test/reader/reader_read_ledger_boundaries_test.dart`：来源选择、首屏恢复顺序、失败回退、多文件位置与跳过文本不入账。
- **备注**：本分支复用既有工作，不另立同问题编号。原始 iPhone 两次开书与统计数据库端到端复测待补；另见 BUG-2392 过期快照保护。
