# 云同步 OAuth 回调登记

`oauth-redirects.json` 是应用要求云端登记的契约清单，包含公开 client ID、当前手机回调、旧版仍需保留的回调和桌面端口。它不是 Azure / Dropbox 后台配置的导出，`cloudVerification: pending` 表示尚未回读后台确认。

任何 client ID、回调 scheme / host / path 或固定 loopback 端口变更，都必须在同一改动中更新此清单，并同步完成下面的云端操作。只改 Dart 或 Android / iOS 接收配置不能完成迁移。

1. 由有权限的管理员打开 Azure App registrations，按清单中的 OneDrive client ID 找到应用，在 Authentication → Mobile and desktop applications 添加 `fushi://auth/onedrive`。保留 `hibiki://auth/onedrive` 和现有 localhost 回调。
2. 打开 Dropbox App Console，核对 App key 为 `dv2sk1o33j6pfi8`，在 OAuth 2 → Redirect URIs 添加 `fushi://auth/dropbox`。保留 `hibiki://auth/dropbox` 和桌面使用的 `http://localhost:9004`（无尾斜杠）。
3. 保存后重新打开后台，回读 client ID / App key 和完整 Redirect URI 列表，记录日期与结果。不要把登录 token、client secret 或凭据放进仓库。只有回读确认后才将对应 `cloudVerification` 改为 `verified`，并在 BUG 记录里附验证证据。
4. 在手机上重新点登录，确认浏览器授权成功、回到应用且成功换取 token。后台补登记不需要重新发版。Azure / Dropbox 后台登记确认与手机登录验证是两项独立证据，分别记录。

`fushi/test/sync/oauth_redirect_registration_guard_test.dart` 对真实 backend 的授权 URL、登记契约与 Android / iOS 的回调接收声明进行离线核对。更改生产回调却遗漏更新契约或平台配置会失败。离线测试无法证明云端已经登记，也无法代替手机登录；修改契约并让测试通过仍必须执行上面的后台回读和手机验证。

2026-10-10 回读 Dropbox App key `dv2sk1o33j6pfi8`：已登记 `fushi://auth/dropbox` 和 `http://localhost:9004`，无需再补当前回调；未见旧 `hibiki://auth/dropbox`，本次没有删改后台配置。Allow public clients 为 Allow。Status 为 Development、Development users 为 Only you，是另一项访问限制，不能归因为 redirect URI 缺失。手机登录尚未验证。

2026-10-10 Azure 后台回读确认目标 client ID 应用原先仅有 `http://localhost`、`hibiki://auth/onedrive`；在 Mobile and desktop applications 平台添加 `fushi://auth/onedrive` 并 Configure 保存后，真实 Redirect URIs 列表显示全部三条。旧回调与桌面回调均保留。云端回调缺失已修复，手机登录尚未验证。

2026-08-07 的 `fa1d429f06` 把手机回调从 `hibiki://` 切到 `fushi://`。当时文件路径是 `hibiki/lib/src/sync/`，当前是 `fushi/lib/src/sync/`。桌面经 `desktop_oauth.dart` 生成 localhost 回环地址，与手机 custom scheme 分开。
