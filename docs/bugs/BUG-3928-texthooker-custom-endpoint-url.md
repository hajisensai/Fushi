## BUG-3928 · texthooker-custom-endpoint-url
- **报告**：2026-11-01（用户：反馈 Pe5ld__ktM「文本端点不支持自定义URL，无法连接 lunatranslator」，3.0.0 Windows）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/models/preferences_repository.dart` `texthookerUrls`：端点列表只有偏好键 `texthooker_urls` 与写死的三个默认值 `ws://localhost:6677/9001/2333`，`setTexthookerUrls` 除单测外没有任何调用点，设置里没有入口；LunaTranslator 的 WS 输出挂在路径上 `ws://<ip>:<port>/api/ws/text/origin`，默认三条都连不上，诊断页只能一直「重连」）
- **[x] ① 已修复** — 「设置 › 查词 › 外部集成」加「文本端点地址」文本项（`settings_schema_lookup.dart` `lookup.texthooker_urls`）：逗号/空白分隔、无协议补 `ws://`、去重（`parseTexthookerEndpointInput`，`texthooker_ws_client.dart`）；接收开着时按新列表重连（分支 fix/feedback-galgame）
- **[x] ② 已加自动化测试** — `fushi/test/sync/texthooker_ws_client_test.dart`「自定义端点」组：解析契约 + 真 WS 服务端只在 `/api/ws/text/origin` 路径上升级、客户端按填写的带路径地址连上并收到原文
- **备注**：LunaTranslator 源码（`textio/textoutput/websocket.py`）两个端点都推裸文本；`/api/ws/text/trans` 推的是**译文**，查日语原文要用 `/api/ws/text/origin`，设置项提示里写明了。
