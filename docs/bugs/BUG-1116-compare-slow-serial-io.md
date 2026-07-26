## BUG-1116 · 本地vs远端加载慢：per-book 串行 DB 查询 + 重复远端目录探测
- **报告**：2026-07-26（用户：本地 vs 远端加载太慢）
- **真实性**：✅ 真 bug。旧对比加载逐本串行读取阅读位置/有声书位置/共同祖先，并对远端独有书额外再发一次 `listChildren` 探测 EPUB；书多时形成 DB N+1 与多波网络 RTT。根因见 `hibiki/lib/src/sync/sync_compare_dialog.dart:181-200`。
- **[x] ① 已修复** — 三类本地数据改批量读取；每本远端目录的 children 同一轮复用给 EPUB 与真实有声书包判定；书籍与四类资产并发加载；冲突专用弹窗不再请求不会渲染的资产维度。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_compare_bulk_reads_test.dart` 覆盖批量位置/基线与更新时间键过滤；`sync_compare_assets_test.dart` 覆盖四维并行容错。
- **备注**：仍保留远端 API 限流所需的有界批次，避免用无限并发换取表面速度。
