## BUG-3521 · OPDS：Komga 只认 X-API-Key 头，配置只有用户名/密码；Basic 用户名须为登录邮箱
- **报告**：2026-10-19（用户：OPDS 发现源接 Komga；真 Komga 1.29.1 实测证实）
- **真实性**：✅ 真 bug。真机：API key 只认 `X-API-Key` 头（`?apikey=`、Basic 里放 key、路径带 key 均 401）；Basic 用户名必须是登录邮箱（`admin:secret123` → 401，`admin@example.org:secret123` → 200）。`fushi/lib/src/media/discovery/opds_server_config.dart` 只有用户名/密码（基线 `ae55190552` 第 75 行 `authorizationHeader` 只产 Basic），UI 也没有任何提示。
- **[x] ① 已修复** — 见本 PR 提交（`pr/opds-komga`）。
  - `OpdsServerConfig.apiKey`：JSON 里以 `apiKeyB64` 遮蔽存放（与 `passwordB64` 同一套），旧配置无该字段 → 空串；整份配置仍在 `discovery_opds_servers` 一个偏好键里，该键已登记 `kCredentialPreferenceKeys`（`preference_keys.dart:689`）、`pref_redaction_policy.dart:99`、`sync_repository.dart:1803`，不随备份/同步出设备、不进日志——新字段自动继承。控制通道列表只回 `hasApiKey`，`api_key` 参数标 `secret`。
  - `credentialHeadersFor(target)`：只对目录自己的 origin 发 `Authorization`（有账号时）与 `X-API-Key`（有 key 时）；feed 请求、下载 payload、封面共用。重定向跨 origin 时剥掉（见 BUG-3520 备注里的手动跟随）。
  - 设置页加「API key（可选）」遮蔽输入框；用户名提示补「Komga：填登录邮箱」（新 key，不改既有译文）。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/sources/opds_komga_compat_test.dart`（同 origin 才发、只配 key 即可打通、JSON 往返与旧配置兼容、feed 跨 origin 重定向不带 key）；`fushi/test/media/discovery/discovery_download_redirect_credentials_test.dart`（真下载：跨 origin 剥 X-API-Key、同 origin 保留）；`fushi/test/pages/opds_server_settings_section_test.dart`（API key 字段写穿偏好并进运行期源）。
- **备注**：真 Komga 端到端复测见 PR 描述。
