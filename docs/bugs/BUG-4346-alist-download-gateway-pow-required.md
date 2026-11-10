## BUG-4346 · 发现页 AList 下载网关返回 403 pow_required，下载器没有人机验证握手
- **报告**：2026-11-09（开发者自提，应用内反馈 fDlzXDp6h9：游戏发现页内置 AList（alist.erogame.space）下载报 HttpException 403）
- **真实性**：✅ 真 bug（2026-11-10 实探）。`AListDiscoverySource.resolvePayload`
  （`fushi/lib/src/media/discovery/sources/alist_discovery_source.dart:163`）把 `/api/fs/get` 的 `raw_url`
  直接当 `DiscoveryHttpPayload`；`raw_url` 302 到下载网关 `frontgate-p01.nicewiki.eu.org/worker/P/...?sign=...`，
  网关对不带放行凭据的请求一律回 `403 {"code":"pow_required"}`（浏览器 `Accept: text/html` 则回一页解题脚本）。
  下载队列（`packages/fushi_engine/lib/media/discovery/discovery_download_queue.dart` `_openViaHttpClient` →
  `ResumableDownloader._run` 的 `download failed (403)`）没有任何挑战识别与握手，只能报 403。
  网关协议（`ImoutoHeaven/snippet-pow-equihash` glue.js）：Equihash n=144 k=7，题目绑出口 IP / ASN / 资源路径、
  10 分钟有效；解完 POST `/__pow/verify` 换一次性 `consume`，写 `__Secure-pow_a=1|c|<captcha>|<consume>`
  （`Path=<资源路径>; Max-Age=5`，写不进则拼 `__ct` 查询参数）后 `location.replace(<原资源 URL>)`。
- **[x] ① 已修复** — 引擎层新增 `download_gateway_challenge.dart`：按响应体 `code ∈ {pow_required}` 识别挑战
  （不认域名），挑战 URL 取重定向终点那一跳；队列注入 `DownloadGatewayChallengeSolver`，遇挑战解一次、带
  放行 URL + Cookie/UA 重开同一资源，放行后仍被挡或解不了就以 `DownloadGatewayChallengeRequired` 失败（不自动重试）。
  app 层 `DownloadGatewayChallengePage` 用与 app 代理一致的共享 WebView 环境让站点 JS 自己解题，截下「回跳同一资源
  且多出 cookie / 查询参数」那次主框架导航（取消它，一次性凭据留给下载器），返回 URL + cookie + UA；任务失败行
  显示「站点要求人机验证」并提供「在浏览器中打开」。不在 Dart 侧实现 Equihash 求解器（协议站点私有、参数可变）。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/discovery_download_gateway_challenge_test.dart`
  （mock open + 真实 HttpServer 302→网关端到端）、`fushi/test/media/discovery/download_gateway_challenge_navigation_test.dart`
  （解完判据）、`fushi/test/media/discovery/discovery_download_tasks_section_test.dart`（失败文案）。
- **备注**：测试未在本分支运行，统一在合并后验证。未做真机验证：WebView 里 Equihash 实际解题耗时、Windows
  WebView2 Fetch 拦截下 `shouldOverrideUrlLoading` 对 `location.replace` 的取消、5 秒 cookie 窗口内下载器能否发出请求、
  WebView 与 HttpClient 出口 IP 一致（两者都走 app 代理设置）均待设备复测。
