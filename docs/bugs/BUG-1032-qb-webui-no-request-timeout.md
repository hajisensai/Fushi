## BUG-1032 · qB WebUI 请求缺少超时
- **报告**：2026-07-23（用户：）
- **真实性**：✅ 真 bug。`QBittorrentClient.login`、GET 与 POST 请求原先直接等待 `package:http` Future，没有应用级截止时间；WebUI 地址不可达或连接半开时，设置页“测试连接”和后台轮询可能一直等到操作系统 TCP 超时。根因：`hibiki/lib/src/media/torrent/qbittorrent_client.dart:111`、`:242`、`:244`。
- **[x] ① 已修复** — qB WebUI 所有登录、GET 与 POST 请求统一使用默认 10 秒超时，仍保持客户端“失败返回、不抛异常”的既有契约。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/qbittorrent_client_test.dart` 用延迟 MockClient 验证请求在配置截止时间内返回失败；`hibiki/test/torrent/qbittorrent_local_webui_test.dart` 通过真实本地 HTTP 栈验证登录、SID、分类、添加任务、任务/文件查询的 qB WebUI 契约。
- **备注**：本机 qB WebUI 已因既有失败登录触发 localhost IP 封禁，未重启或改写用户 qB 配置；真实实例端到端验证待解封后补测。
