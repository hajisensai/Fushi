## BUG-1980 · 网络代理无法显式禁用且不支持认证
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。原设置只有 `settings_schema_system.dart` 中单个 `host:port` 文本项；空值固定进入“环境变量 → 系统代理 → 直连”，无法表达“强制直连”，`app_proxy.dart` 也未设置 `HttpClient.authenticateProxy`，407 认证代理必然失败。
- **[x] ① 已修复** — 增加“自动 / 直连 / 手动”一等模式，手动模式显示服务器、用户名和遮蔽密码；网络装配层按模式裁决并仅在代理 challenge 时注入凭据（提交哈希在本 PR 首个提交）。
- **[x] ② 已加自动化测试** — `test/utils/net/app_proxy_local_bypass_test.dart` 覆盖强制直连、手动配置非法时不偷用系统代理，以及 407 challenge 凭据注入。
- **备注**：本机、局域网与 mDNS 目标继续由共享闸门强制直连；P2P 仍需单独明确开启。
