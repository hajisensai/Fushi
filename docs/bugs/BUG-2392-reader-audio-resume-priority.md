## BUG-2392 · 阅读进度异步快照在导航后仍写入位置与统计
- **报告**：2026-09-09（用户：小说位置恢复异常，跳回有声书位置可能导致字数统计异常）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1074` 的 `_refreshProgress` 与 `:1250` 的 `_syncPositionFromWebViewProgress` 在等待 JS 快照后仅检查 mounted。等待期间导航或 WebView 重建后，旧快照仍可套用新章节、覆盖恢复锚；实时采样还会调用 `ReadUnitLedger.arrive`。账本本身不按远跳距离入账，不能把风险描述成已证实整段重复计数。
- **[x] ① 已修复** — `03180bae1f`：请求时捕获控制器、导航代际、章节；返回后复核并检查恢复/歌词状态，在解析、位置更新、账本与落库之前丢弃过期结果。章节单独复核覆盖设置重载先变章节再递增代际的窗口。音频优先由复用的 `773d4372a0`（原 `b83831166a`，BUG-2390）处理。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_progress_snapshot_generation_guard_test.dart` 覆盖实时与退出采样的前后置接线；音频来源与账本回归通过 `audiobook_resume_point_test.dart`、`reader_read_ledger_boundaries_test.dart` 验证。
- **备注**：已查看用户视频，画面显示翻页后重开回到较前位置；未在原始 iPhone/书籍上执行两次开书和统计 DB E2E，不能声称视频中的完整故障已实机修复。初次测试被 SQLite 下载网络阻塞，配置当前代理后统计六组 119 项通过；不运行全量测试或发布构建。
