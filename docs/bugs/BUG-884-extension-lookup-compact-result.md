## BUG-884 · 浏览器扩展查词响应重复携带原始词条导致冷链路慢
- **报告**：2026-07-17（用户：浏览器扩展查词“感觉速度好慢”）
- **真实性**：✅ 真 bug。`hibiki/lib/src/sync/hibiki_remote_api_handlers.dart` 的 `buildRemoteDictionaryLookupResponse` 同时返回 `result.toJson()` 与 `popupJson`，而 `tools/browser-extension/background.js` 把整包交给 content script；扩展只从 `result` 读取 `bestLength`，词条正文已在 `popupJson` 中，因而重复序列化、传输、JSON 解析和跨扩展消息复制完整词条。真实运行接口实测：“ていた”响应 253,100 bytes，其中完整 `result` 142,619 bytes；“見る”响应 1,121,702 bytes，其中完整 `result` 633,635 bytes。
- **[x] ① 已修复** — 扩展查词显式发送 `popupOnly:true`，共享 handler 只在该标志下返回 `{bestLength}`；默认请求仍返回完整 result，保持同步端及第三方客户端兼容。提交：`71b8029db`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/yomitan_api_server_extension_endpoints_test.dart` 通过真实 HTTP 同时锁定紧凑响应与默认旧契约；`hibiki/test/lookup/browser_extension_compact_lookup_guard_test.dart` 锁定两份扩展 background 均启用紧凑请求且镜像一致。
- **备注**：优化不改变词典查询和 popup 渲染逻辑；按实测包体构成可移除约 56% 的重复响应数据。冷启动约 0.44–0.48s 还包含词典/运行时预热，本修复只针对已证实的重复传输部分。
