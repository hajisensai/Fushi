## BUG-1559 · restoreAuth 把已解析地址打回候选[0] 而 _sessionResolved 仍为 true，不再重探
- **报告**：2026-08-12（互联配对与安全链路审计）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/interconnect_sync_backend.dart` `restoreAuth`：
  BUG-1183 只修了一半——「要不要重探」已改成看配置签名，但 `restoreAuth` 仍无条件跑
  `_buildProvisionalOps()`，把 `_ops` / `_activeFingerprint` / `_activeToken` 打回**第一个格式合法的
  候选**，而 `_sessionResolved` 仍是 true → `_ensureResolved()` 直接 return。净效果：切一次页面，
  会话就从「探明可达的那台」静默地滑回候选[0]（常常是一条当前不可达的旧地址），且因已标「已解析」
  而**永不重探**，往后每一次请求都打到错地址。
- **[x] ① 已修复** — 会话已解析且句柄还在时原封不动地保留它（`interconnect_sync_backend.dart:397`）；
  配置真变了时 `_loadConfig` 依旧把 `_sessionResolved` 置 false，重建路径一字未动。
  **兼容性**：纯进程内会话状态，无协议 / 存储变更。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_session_reuse_test.dart` 新增两条（只有候选[1]
  可达时，restoreAuth 后 activeBaseUrl 仍是候选[1]；配置真变了仍重建）。已变异实测（去掉保留分支 →
  第一条变红）。
- **备注**：本轮互联配对安全链路六修之五（BUG-1555~1559）。
