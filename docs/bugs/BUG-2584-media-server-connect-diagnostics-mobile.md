## BUG-2584 · Android 连不上媒体服务器：失败原因被原生 toast 截断、无连通性探测、scheme 大小写
- **报告**：2026-09-18（用户：「安卓直接连不上」，Windows 同一服务器可连）
- **真实性**：✅ 真 bug（诊断链缺陷已验真；用户侧的具体网络原因**未复现**——无其服务器地址与手机日志）
  - 排除：Android 明文 http 已放行（`fushi/android/app/src/main/res/xml/network_security_config.xml` `cleartextTrafficPermitted="true"`，BUG-377 修过、守卫 `test/android/network_security_config_guard_test.dart` 钉着）；媒体服务器客户端 `fushi/lib/src/sync/jellyfin_video_client.dart` 纯 `package:http` 经 `createAppHttpIoClient`，零 Android 分支；局域网字面量 IP 恒 DIRECT（`app_proxy.dart` `isDirectProxyTarget`）。
  - 已验真的缺陷：
    1. 登录失败在手机上走 `Fluttertoast`（`fushi/lib/src/utils/misc/fushi_toast.dart` 移动分支，`LENGTH_SHORT` 2 秒、两行截断），`SocketException: … address = …, port = …` 这种真正有用的原因看不全，用户只能报「直接连不上」；桌面自绘 overlay 能换行所以看得到。
    2. 唯一的「探测」就是登录 POST 本身（`jellyfin_settings_widget.dart` `_signIn`），连不上与账号错不分。
    3. `JellyfinApi.normalizeServerUrl` 的 scheme 判断大小写敏感：`HTTP://nas:8096`（手机输入法 / 粘贴常见）变成 `http://HTTP://nas:8096`。
    4. 平台差异未提示：Android / iOS 不解析 `.local`（mDNS）与 Windows 计算机名（NetBIOS / LLMNR），桌面能——用户在桌面填的主机名到手机上就是 host lookup 失败，最像「直接连不上」的形状。
- **[x] ① 已修复** — `28b6b7d7151`：登录前先 `JellyfinApi.publicSystemInfo()`（GET `/System/Info/Public`，无需认证）探连通性，失败走 `_showSignInError`（`AlertDialog` + `SelectableText`，完整可复制）并用 `jellyfin_server_unreachable` 文案；`JellyfinApi.isHostLookupFailure` 判定主机名解析失败时追加 `jellyfin_host_lookup_hint`（「改用 IP」）；认证失败同样进对话框；`normalizeServerUrl` scheme 不分大小写并归一为小写。登录同时改用 per-install `DeviceId`（见 BUG-2583）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_playback_negotiation_test.dart` 「连接诊断」组：`normalizeServerUrl` 大小写、`isHostLookupFailure` 正反例、`publicSystemInfo` 端点。
- **备注**：
  - 用户实际原因未定：最可能是主机名解析（`.local` / 计算机名）或 https 证书链（Android 不像 Windows 会自动补中间证书）——修后对话框会把真实异常原样给出，下一份报告可据此定性。
  - 若真是 Android 16+ 的本地网络保护（`NEARBY_WIFI_DEVICES` 门控局域网访问）则需要 manifest + 运行时权限，本轮未加（该保护目前仍是 opt-in，不能凭症状推定）。
