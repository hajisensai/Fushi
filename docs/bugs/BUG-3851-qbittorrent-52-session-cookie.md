## BUG-3851 · qBittorrent 5.2+ 会话 cookie 改名后外接登录失败
- **报告**：2026-10-27（用户：反馈 MrC_WCyTun，Windows，qBittorrent 5.2.0 / 5.3.0 测试连接报「login ok but no SID cookie in response」，5.1.4 正常）
- **真实性**：✅ 真 bug。qBittorrent 5.2 起把 WebUI 端口拼进会话 cookie 名（`QBT_SID_<端口>`），`extractSidCookie` 只认字面 `SID=`，`_send` 也写死回传 `Cookie: SID=…`（`packages/fushi_engine/lib/media/torrent/qbittorrent_client.dart:21`、`:859`）。
- **[x] ① 已修复** — `extractSessionCookie` 按响应里的真实名字（`SID` / `QBT_SID_<n>`）提取并保存完整 `<名>=<值>`，请求原样带回；名字只从响应读，不按配置地址猜端口（反代 / 端口映射下对外端口与 qb 端口不同）。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/qbittorrent_client_test.dart`（`QBT_SID_8080` 提取、前缀不误匹配、5.2 登录后回传端口后缀 cookie）。
- **备注**：没有真 qBittorrent 5.2 实机联调，按上游 5.2.0 发布说明「WEBAPI: Append port to session cookie name」与反馈截图核对。
