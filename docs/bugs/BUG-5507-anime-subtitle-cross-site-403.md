## BUG-5507 · anime-subtitle-cross-site-403
- **报告**：2026-11-25（用户：应用内反馈 kslC0cG1TS，Android）
- **真实性**：✅ 真 bug。日志 6 次 `subtitle download failed: HTTP 403`，字幕在 `*.mysubsplay.com`（第三方字幕站），视频流在别的站。根因 `fushi/lib/src/media/video/online/anime_source_video_client.dart` `getRemoteVideoSubtitle`：只有字幕与流同站才带扩展给的流请求头，跨站一律不带；字幕站按 Referer / UA 防盗链回 403。上游 Aniyomi 把 `Video.headers` 设成 mpv 全局 `http-header-fields`，字幕 `sub-add` 跨站也带，扩展按这个契约写。旧的「跨站不带」照搬自 `UrlStreamVideoClient`，那条规则防的是用户凭据（WebDAV 账号密码）发往外部内容指定的主机，这里的头与字幕地址出自同一个扩展。用户写的 406 日志里对不上。
- **[x] ① 已修复** — 新增 `AnimeSourceVideoClient.subtitleRequestHeaders`：同站全带流头；跨站去掉 Cookie / Authorization / Proxy-Authorization，Referer / Origin / User-Agent 等照带。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/online/anime_source_video_client_test.dart`「subtitle download: same site gets every stream header, a third-party subtitle host gets them minus credentials」。
- **备注**：没有该扩展与字幕站的真实请求复现，修完请用户复测；若仍 403，需要抓扩展给的头看字幕站另要什么。
