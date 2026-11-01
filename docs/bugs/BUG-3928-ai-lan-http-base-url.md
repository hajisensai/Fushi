## BUG-3928 · 自定义 OpenAI 兼容地址只接受 http://localhost，不接受局域网 IP
- **报告**：2026-11-01（用户：反馈 9_vP-OLetJ（Android 截图））
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/ai/ai_provider_config.dart:359` 构造器用 `isSafeExternalProviderEndpoint`，明文 HTTP 只放行 loopback（`torznab_client.dart:182` `isLoopbackProviderHost`）；局域网 `http://192.168.x.x` 必须另勾「允许明文 HTTP」，而错误提示文案写的是「本地模型服务（http://localhost）需要打开」，用户读成只认 localhost。
- **[x] ① 已修复** — 新增 `isPrivateNetworkProviderHost`（RFC 1918 / 链路本地 / IPv6 ULA / `.local`，不含 CGNAT），AI 提供商地址对本机与局域网的明文 HTTP 同等放行；公网明文 HTTP 仍要显式勾选；开关说明 17 语言改为「局域网以外的 http:// 地址需要打开」。提交 a0f963f1cb。
- **[x] ② 已加自动化测试** — `fushi/test/settings/ai_provider_settings_test.dart`「明文 HTTP：局域网地址与 localhost 同等放行」。
- **备注**：Android 明文流量 `network_security_config.xml` 的 base-config 已允许 cleartext，无需改。
