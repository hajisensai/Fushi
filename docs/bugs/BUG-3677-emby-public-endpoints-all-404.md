## BUG-3677 · 部分 Emby 服务器公开端点全 404，添加服务器失败
- **报告**：2026-10-21（应用内反馈 WMxpfrPXJp，macOS 3.0.0-debug.20622：部分 Emby 服务器不提供 `/System/Info/Public`，添加服务器 404，其它 Emby 客户端能用）
- **真实性**：✅ 真 bug。BUG-3137（2536103289，已在反馈人版本内）只把探测扩成「根 / `/emby` 的 Info/Public → 两处 `/System/Ping`」，全部 404 时 `JellyfinApi.probeServer()`（`fushi/lib/src/sync/jellyfin_video_client.dart` 原 `throw first!`）仍判失败，`signInJellyfinServer` / `addJellyfinRoute`（`fushi/lib/src/sync/jellyfin_settings_widget.dart`）直接抛 `JellyfinConnectFailure`，根本不去发登录请求。网关只放行业务路由的部署会把两条公开端点整片砍掉，而登录 / 读媒体库正常——公开端点被当成了强依赖。
- **[x] ① 已修复** — `probeServer` 全 404 时返回 `JellyfinServerProbe.unconfirmed`（Ping 回网页仍是「不是媒体服务器」的正面证据，照旧抛）；`_runOnServerBase` 用真正的认证请求（登录 / 读媒体库）在候选根地址（填的地址、`/emby` 前缀变体）间定案：回 404 换下一个，其它答复（成功 / 401 / 403…）就此定案，全部 404 才报连不上。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_probe_unconfirmed_test.dart`（8 条：探测未确认、登录在根 / `/emby` 定案、401 原样报、全 404 报连不上、添加线路定案与校验失败）；`fushi/test/sync/jellyfin_emby_compat_test.dart` 既有 BUG-3137 用例照常通过。
- **备注**：没有那台服务器，未真机复测。服务器类型无需用户手选：同一套客户端双吃 Jellyfin / Emby。
