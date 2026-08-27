## BUG-1884 · Mihon 来源偏好没有保存按钮，未提交文本会丢失
- **报告**：2026-08-26（用户：Komga 来源偏好弹窗只有关闭按钮）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/manga_sources_page.dart:1527` 的文本偏好旧链路只在 `onFieldSubmitted`（回车）时保存，弹窗 actions 又只有“关闭”，焦点仍在文本框时没有可见的落盘入口。
- **[x] ① 已修复** — 本提交（自含修复、测试与本条目）：弹窗增加明确的“保存”按钮；文本输入先进入按 preference key 保存的草稿，点击“保存”后逐项写入真实 `MihonManager.setPreference` 链路并在成功后关闭。开关、下拉和多选继续即时保存，保存期间禁用重复动作。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_source_preferences_dialog_test.dart` 用真实 `MihonManager`、内存 Drift 数据库和 fake runtime 驱动 widget：文本框保持焦点且未按回车时点击“保存”，断言 runtime 收到新值、数据库快照已写入、弹窗关闭。
- **备注**：定向 widget 测试已通过；尚未在真实 Windows/Android 界面肉眼复测原截图路径。
