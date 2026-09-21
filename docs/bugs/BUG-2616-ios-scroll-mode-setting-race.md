## BUG-2616 · iOS 滚动模式设置未落地导致阅读器布局不更新
- **报告**：2026-09-21（用户：iOS 滚动模式选择后设置不生效，正文布局与界面显示异常）
- **真实性**：✅ 真 bug。`fushi/lib/src/settings/settings_schema_reading.dart` 中结构性阅读设置的 `onChanged` 未等待 `ReaderFushiSource.setReaderViewMode` 等异步持久化完成，就立即调用 `notifyReaderLayoutChanged`。阅读器重载读取到旧设置，之后到达的普通 live-settings 回调只更新旧 WebView 的 CSS，导致 iOS 仍显示旧的分页/滚动布局。
- **[x] ① 已修复** — 结构性阅读设置在触发 WebView 重载前等待异步 setter 完成（本提交）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/reader_structural_setting_order_test.dart` 锁住四个结构性阅读设置的 await → layout reload 顺序。
- **报告**：2026-09-21（用户：）
- **真实性**：（沿真实代码路径验真伪后填：✅ 真 bug / ❌ 未复现，附根因 `file:line`）
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
