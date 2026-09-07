## BUG-2252 · 飞牛影视 Jellyfin 兼容层要求 X-Emby-Authorization 认证头
- **报告**：2026-09-07（用户报「其他软件可登录，Fushi 登录失败 JellyfinApiException(400, /Users/AuthenticateByName)」；服务器 192.168.9.5:8005 实测为飞牛影视 fnOS 影视，非原版 Jellyfin/Emby）
- **真实性**：✅ 真 bug。curl 按 app 原始请求（仅 `Authorization` 头）复现 400 `{"error":"X-Emby-Authorization is missing"}`；同一请求换 `X-Emby-Authorization` 头 200 并返回 AccessToken；双头并发亦 200（官方 Jellyfin 与 Emby 对未知头宽容，双发安全）。根因：`fushi/lib/src/sync/jellyfin_video_client.dart` 的 `JellyfinApi._headers` 只发 `Authorization`，而飞牛的认证中间件强制要求头名为 `X-Emby-Authorization`。注意飞牛不认 `api_key` 查询参数传令牌（一律 400），只认头。
- **[x] ① 已修复** — `_headers` 改为 `Authorization` + `X-Emby-Authorization` 双头并发（抽 `authHeaderFor` 共用同一份 MediaBrowser 值）；提交：见本文件同批 commit（fix(jellyfin): 认证头双发 X-Emby-Authorization）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_video_client_test.dart` 认证用例断言双头同时存在且带 Token 时两头一致。
- **备注**：飞牛兼容层还有三处独立差异（同服务器实测），不在本 bug 范围、按需另开：① `/Items` 的 `IncludeItemTypes=Movie,Episode` 逗号多值返回 0 条（单值正常）；② `/Videos/{id}/stream` 缺 `MediaSourceId` 查询参数时 400，且该参数不等于条目 id（是 MediaSources[0].Id 的独立 GUID）；③ `/Items/{id}/Images/Primary` 带正确认证头仍 404（条目确有 Primary 图），封面端点路径不同。
