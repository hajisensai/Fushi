## BUG-971 · AnkiConnect 主机字段吞掉 http:// 变成 http:

- **报告**：2026-07-21（用户：填写 `http://` 会自动变成 `http:`）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/anki/anki_view_model.dart:155` `updateAnkiConnectHost`——旧逻辑对含 `/` `?` `#` 的输入静默 `return` 拒绝保存。用户在主机字段逐字符敲 `http://`：敲到 `http:` 被接受写入偏好，敲下一个 `/`（`http:/`）起每一击都命中 `contains('/')` 被拒；`_AnkiConnectionField` 是非受控字段（`anki_settings_page.dart:447` 持有自己的 controller），失焦时 `didUpdateWidget`（同文件 452 行）用最后被接受的持久值 `http:` 覆盖输入框，于是看起来「自动变成 http:」。
- **[x] ① 已修复** — 不再静默拒斥，改为把 URL 形态输入规范化成裸主机：剥 scheme/path/query/fragment/userinfo，尾部数字 `:port` 拆到独立端口字段（保留冒号会让 `Uri.parse('http://$host:$port')` 变成 `host:port:port` 破坏请求）。主机原样保留（不小写化、不 punycode）。见 `hibiki/lib/src/anki/anki_view_model.dart` `normalizeAnkiConnectHostInput` + `updateAnkiConnectHost`。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/anki/anki_connect_host_normalize_test.dart`：纯函数单测覆盖 `http://localhost`→`localhost`、`http://192.168.1.5:48765/foo`→`(192.168.1.5, 48765)`、`localhost:8765` 端口拆分、裸 `localhost` 原样、打字途中 `http://` / `http:/` / `localhost:` 不再塌成 `http:`、userinfo 剥离、IDN 主机 verbatim 不转 punycode。
- **备注**：端口自动回填仅在输入携带合法端口时覆盖，否则保留端口字段既有值。IPv6 字面量本就因 `Uri.parse('http://$host:$port')` 不加方括号而不被支持，本次不扩展。
