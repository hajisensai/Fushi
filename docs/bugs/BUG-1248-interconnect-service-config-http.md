## BUG-1248 · 互联 service-config 在 HTTP 上泄露 peer token 并接受伪 host 配置
- **报告**：2026-07-29（PR #582 独立安全审查）
- **真实性**：✅ 真 bug。`hibiki/lib/src/sync/interconnect_sync_backend.dart:685`
  在解析 peer 地址后直接进入 `hibiki/lib/src/sync/webdav_ops.dart:74` 构造带
  Basic Authorization 的 service-config 请求；修复前本地恶意 HTTP 200 能收到
  peer token，并让返回的允许项写入 child 数据库。
- **[x] ① 已修复** — 本提交（自含修复、测试与条目；哈希由本提交确定）在实际选中的
  service-config endpoint 已解析、但尚未调用 `buildRequest` 的边界强制 HTTPS。
  非 HTTPS 以不可重试的 `SyncBackendError` 失败，不改变旧互联协议的其他 HTTP 路径。
- **[x] ② 已加自动化测试** —
  `hibiki/test/sync/interconnect_service_config_security_test.dart` 覆盖普通/大小写变体
  HTTP 地址零请求、零 Authorization、零允许项注入，以及 HTTPS 当前 peer token、
  legacy/wrong/revoked token、五项允许表和 child 禁写矩阵。
- **备注**：旧 exact `df660a55e4112b3aaa6aebf48acf939db9e8131d` 禁止集成；
  仍需集成线程在最新 develop 重放并由新审查线程验收。真实双端 Windows 互联与 CI
  是集成后的外部证据缺口，不影响本地边界测试结论。
