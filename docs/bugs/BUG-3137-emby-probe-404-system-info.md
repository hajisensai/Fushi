## BUG-3137 · 部分 Emby 服务器添加失败 404 System/Info/Public
- **报告**：2026-10-09（群反馈：报 `JellyfinApiException(404, /System/Info/Public)`，同样方式另一台 Emby 能加，SenPlayer 正常）
- **真实性**：✅ 真 bug（客户端探测顺序过窄）。根因 `fushi/lib/src/sync/jellyfin_settings_widget.dart` 的 `_signIn` / `_addRoute` 先 `JellyfinApi.publicSystemInfo()`，只打 `<地址>/System/Info/Public` 一处，404 即判「无法连接」。Emby 的 API 同时挂在根路径与 `/emby` 下，部分非标准部署（反代只转发 `/emby`、兼容层只实现带前缀的路由或砍掉公开信息端点）根路径 404；Emby 官方客户端 / SenPlayer 会回退 `/emby` 前缀与 `/System/Ping`。
- **[x] ① 已修复** — 本 PR：`JellyfinApi.probeServer()` 按「根 Info/Public → `/emby` 前缀 Info/Public（地址已带 `/emby` 则去掉前缀）→ 两处 `/System/Ping`」探测；只有 404 才往下试，401/403/5xx/非 JSON 原样报；Ping 回网页不算；登录与添加线路都改用探出的根地址。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_emby_compat_test.dart`「BUG-3137 连接探测顺序」6 条。
- **备注**：没有那台服务器，未真机复测。
