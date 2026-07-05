## BUG-546 · Hibiki互联手动地址提示HTTPS导致默认HTTP主机无法连接
- **报告**：2026-07-05（用户：wight）
- **真实性**：✅ 真 bug。实测 `https://192.168.1.88:38765/` TCP 可达但 TLS 握手失败（`SSL_ERROR_SYSCALL`），同一端口 `http://192.168.1.88:38765/api/ping` 返回 `{"app":"hibiki","tls":{"enabled":false}}`。根因是默认 Hibiki LAN server 仍为明文 HTTP，但手动互联输入框误提示 `https://192.168.1.100:38765`，且保存前不归一化裸地址：`hibiki/lib/src/sync/sync_settings_schema/interconnect.part.dart:151`、`hibiki/lib/src/sync/sync_settings_schema/interconnect.part.dart:179`。
- **[x] ① 已修复** — 手动互联提示改为默认 `http://`；新增 `normalizeHibikiInterconnectManualUrl`，裸 `host:port` / `IP:port` 保存前补 `http://`，明确 `https://` 仍保留给 TLS+指纹钉扎主机。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/interconnect_manual_url_scheme_guard_test.dart`、`hibiki/test/sync/interconnect_url_test.dart`。
- **备注**：原始设备路径已用本机 curl 验证到对端 Hibiki server；iOS 真机互联 UI 的确认/输入 PIN 仍需用户在两台设备上手动完成。
