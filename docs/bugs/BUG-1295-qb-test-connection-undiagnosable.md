## BUG-1295 · qB测试连接失败无法自查且本机免密被登录门卡死
- **报告**：2026-07-31（用户截图：`http://127.0.0.1:8080/` 测试连接报
  「连接失败，请检查地址与账号密码」）
- **真实性**：✅ 真 bug（两层）。
  1. **单 bool 折叠**：设置页只判 `version == null`
     （`hibiki/lib/src/pages/implementations/torrent_settings_section.dart`
     旧 `:90-92`），而网络不通/账密错（qb 返 200 `Fails.`）/qb 登录失败 5 次
     封 IP（403 banned）/无 SID cookie 全部被
     `qbittorrent_client.dart` 的 `catch (_)`（旧 `:125-127`、`:276-278`）吞成
     同一个 null → 同一句泛化文案，用户无从自查。
  2. **免密被登录门卡死**：qb 开「对本地主机的客户端跳过身份验证」时业务
     接口匿名可用，但 `POST /auth/login` 仍校验账密；客户端 `_request` 强制
     先登录（旧 `:267`），账密不对/留空 → 直接判失败——明明 API 可用。
     与已修的 BUG-1016（WebDAV 空账密匿名）同类缺陷。反复点测试连接还会
     触发 qb 失败计数封 IP（默认 5 次封 1 小时），之后填对账密也一直失败。
- **[x] ① 已修复** —
  - `QBittorrentClient.lastFailure` 结构化记录失败原因（网络异常原文/
    `login rejected`/`IP banned…` 单独识别 403 banned/无 SID/HTTP 状态）；
  - 登录失败后匿名探测 `/app/version`，通了缓存匿名态免登录直连
    （`_authenticate`；不再反复撞登录门放大封禁计数）；
  - `QbTorrentBackend.lastProbeFailure` 透传；设置页新 i18n key
    `download_test_connection_failed_reason`（`连接失败：$message`）显示
    具体原因，拿不到原因时回退旧文案。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/qbittorrent_client_test.dart`：
  匿名回退（login `Fails.` + 版本接口 200 → 成功且不带 Cookie、匿名态缓存
  只撞一次登录门）；banned 403 原因识别；网络异常原因透出；两路都不通时
  保留登录失败原因。
- **备注**：已排除方向——URL 尾斜杠已归一化（有单测）、Referer/CSRF 已正确、
  qb 请求走裸 `http.Client()` 不吃系统代理（127.0.0.1:34151 不劫持）。地址框
  缺 scheme 校验（填 `127.0.0.1:8080` 会因无 scheme 异常）现在会以异常原文
  透出，可自查；未做自动补 `http://`。
