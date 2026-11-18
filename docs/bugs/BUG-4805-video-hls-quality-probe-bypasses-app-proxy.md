## BUG-4805 · HLS 画质探测用顶层 http.get，不走应用代理，需代理的网络下画质菜单静默消失
- **报告**：2026-11-17（用户：小说 / 漫画 / 视频优化清单 video-13，复核后立项）
- **真实性**：✅ 真 bug（代码路径确认，未在真机复现）。根因：
  - `fushi/lib/src/pages/implementations/video_fushi/quality.part.dart:36`（修前行号）`_detectHlsVariantsForLoad` 用 `package:http` 的顶层 `http.get(uri, …)` 取 master 正文。顶层便捷函数每次内部现建一个默认 `IOClient`，只认环境变量代理，不认 GUI 系统代理与用户手填的代理（应用代理由 `packages/fushi_engine/lib/utils/net/app_http.dart` 的 `createAppHttpClient` / `createAppHttpIoClient` 装 `findProxy`）。播放内核经应用代理放得出来的流，探测请求却连不上。
  - 同文件 `:52`（修前行号）`catch (_)` 不记任何日志，「画质菜单没出来」无从排查。
  - 出站守卫 `fushi/test/tools/outbound_http_discipline_guard_test.dart` 只拦 `http.Client(` 等构造表达式，不拦顶层 `http.get(`，所以这处一直漏网。
- **[x] ① 已修复** — 探测搬进 `packages/fushi_engine/lib/media/video/hls_master_probe.dart` 的 `fetchHlsMasterVariants`：用 `createAppHttpIoClient()` 出站，8 秒整体上限不变，`finally` 关 client（超时后真正取消请求），失败一律抛出。`quality.part.dart` 改调它；失败仍降级为「无画质菜单」、不提示用户（文件头写明的既有设计），但落 `ErrorLogService`（来源 `VideoFushi.hlsQualityProbe`，只记 host 与异常类型 / HTTP 状态码，不记带 token 的完整 URL）。`video_fushi_page.dart` 不再 import `package:http`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/hls_master_probe_test.dart`（注入 client 驱动 `fetchHlsMasterVariants`：master / 媒体播放列表 / 非 200 / 超时 / 头透传）；`fushi/test/tools/outbound_http_discipline_guard_test.dart` 新增判据 `http.<verb>(`（顶层 `http.get/post/put/patch/delete/head/read/readBytes`，含 `dart format` 折行写法）与合成语料自校验，全仓扫描从此拦住同类写法；`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart` 的互联配对请求（目标恒为局域网 / 组网 host）登记豁免。
- **备注**：真机未复测。待验：桌面手填代理（且不设环境变量代理）播一条多档 HLS，画质菜单应出现；把代理填错时 error_log 应有一条 `VideoFushi.hlsQualityProbe`。
