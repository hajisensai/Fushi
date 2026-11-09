## BUG-4243 · 互联「测试连接」连已停用的地址也测
- **报告**：2026-11-08（用户：设置 → 互联「已添加的对端」）
- **真实性**：✅ 真 bug。`_testAll`（`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart`）直接 `for (u in _urls)`，不看 `u.enabled`，停用行照样发请求并亮 ✓/✗；而全部真实消费点（同步、下载、任务、OCR、订阅、助手、视频目标等）都 `where((u) => u.enabled)`。停用行亮 ✓ 让人以为它在用。另外停用后上一轮结果原样留在行上。
- **[x] ① 已修复** — 新增 `interconnectUrlsToTest`（只留启用行），`_testAll` 只测它；全部停用时提示 `interconnect_peer_test_none_enabled`。停用行渲染时不显示测试结果（`u.enabled ? _reachable[u.url] : null`），`_toggleUrl` 启停时清掉该行旧结果。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_peer_row_test.dart`（helper 单测 + 面板接线源码守卫）。
- **备注**：
