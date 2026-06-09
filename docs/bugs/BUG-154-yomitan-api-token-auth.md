## BUG-154 · Yomitan API token authentication rejects compatible clients
- **报告**：2026-06-09（用户：Yomipv 使用 Hibiki Yomitan API 时提示 token 错误）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/sync/yomitan_api_server.dart:81` 的鉴权中间件只接受 `X-API-Key`，但对外标称宽松兼容 yomitan-api；客户端把同一 token 放在 JSON body、query 或 `Authorization` 等常见位置时会被 Hibiki 直接 401。
- **[x] ① 已修复** — `hibiki/lib/src/sync/yomitan_api_server.dart` 扩展 API key 读取入口，继续要求同一个 key 匹配，不关闭鉴权。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/yomitan_api_server_test.dart` 覆盖 `apiKey`/`token` body、query token、Bearer token 和错误 token。
- **备注**：本地还确认过当前运行的 Hibiki 服务在 `X-API-Key` 正确时返回 200、无 key 或错 key 返回 401；用户给出的外部客户端日志显示请求未携带 `X-API-Key`。
