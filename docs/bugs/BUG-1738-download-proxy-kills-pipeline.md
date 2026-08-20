## BUG-1738 · 自定义下载代理未填时切换发现网络永久杀死下载管线
- **报告**：2026-08-19（用户：QQ 截图报「网络一切换直接下载不了东西」「直接变成离线」「自带的后端经常掉，提示配置后端，或下载任务直接罢工」）
- **真实性**：✅ 真 bug。三个症状同一根因，内置 libtorrent 引擎全程活着（运行期没有任何销毁路径，`app_model.dart` 只在 `dispose()` 释放 `_embeddedTorrentHost`），死的是 `VideoDownloadPipelineService` runtime：
  1. 设置页「发现网络」切到「自定义」时 `download_custom_proxy` 还是空串 → `fixedDownloadProxyDirective`（`fushi/lib/src/media/torrent/download_network_proxy.dart:116-119`）对 `normalizeUserProxyHostPort` 返回 null 的输入 `throw FormatException`；
  2. `setDownloadNetworkProxyMode` → `reloadVideoDownloadPipelineRuntime`（`fushi/lib/src/models/app_model.dart:3999-4004`）先 `_disposeVideoDownloadPipelineRuntime()` 把 `_videoDownloadPipelineService` 置 null，再 `_startVideoDownloadPipeline()` 第一行 `createDownloadHttpClient()` 抛出 → service **永久留 null**，异常被 `torrent_settings_section.dart:366` 的 void async 回调丢弃，用户无感知；
  3. 入口守卫 `if (_videoDownloadPipelineService == null) return;`（`app_model.dart:4000`）是单向门闩：管线死后任何后续设置变更（包括切回直连）都原地返回，**再也救不回来**；
  4. 放大器：自定义代理输入框每敲一个键就整套 reload（`torrent_settings_section.dart:389` 裸 `TextField.onChanged`），输入第一个字符就已把管线打死；
  5. 症状映射：管线死 → 5s 轮询推进器消失 = 任务罢工；任务详情走 BUG-1535 的持久快照兜底，`liveDataAbsence` 缺省态被 `torrent_detail_dialog.dart:384-389` 渲染成「原下载后端当前离线」；下载页 `downloads_page.dart:70-72` pipeline==null 直接显示「请先配置下载后端」。
  6. 冷启动同坑：偏好里存着 `mode=custom` + 空/非法地址时 `startAnimeDownloadService` 尾部的 `_startVideoDownloadPipeline()` 每次启动都抛（被 `.catchError` 记日志后吞），管线从未起来。
- **[x] ① 已修复** — 两层根因修复（提交见本分支）：
  1. `fixedDownloadProxyDirective` 改全函数：custom 模式地址非法/未填时 fail-open 返回 `'DIRECT'`，不再抛——与同文件 BUG-1538 注释里「误套不存在的代理是黑洞、direct 失败模式更温和」同一纪律；非法态的用户提示由设置页已有的 `errorText` 承担。
  2. `reloadVideoDownloadPipelineRuntime` 门闩改语义：从「service 是否存在」改为 `_videoDownloadPipelineRuntimeWanted`（`startAnimeDownloadService` 置 true，`quiesceBackgroundDatabaseWriters`/`dispose` 置 false），并 try/catch 包住重启：失败记错误日志 + notifyListeners，管线可被下一次设置变更救活，不再单向死亡。
  3. 消放大器：`setDownloadCustomProxy`/`setDownloadNetworkProxyMode` 只在**有效代理指令真的变化**时才 reload（每键 DIRECT→DIRECT 不再整套重建 runtime）。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/download_network_proxy_test.dart`：非法/空 custom 返回 `'DIRECT'` 且 `buildDownloadHttpClient` 全模式不抛（BUG-1738 组）。
- **备注**：相邻已知项不在本案范围——`VideoDownloadPipelineService.dispose()` 不释放 DB lease（reload 后新 worker 最长等 2 分钟 lease 过期，`video_download_pipeline_service.dart:1037-1040`，与 `app_model.dart:3997` 注释不符）；`_validateBackendBinding` 的 category 失配会把存量任务伪装成「后端离线」（BUG-1687 的另一面）。
