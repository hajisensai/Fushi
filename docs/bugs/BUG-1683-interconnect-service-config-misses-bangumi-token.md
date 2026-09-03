## BUG-1683 · 互联不同步 Bangumi 追番令牌与刮削/字幕/索引器凭据
- **报告**：2026-08-16（用户：「bangumi同步等api和token应该要互联」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/interconnect_service_config.dart:26`
  —— `InterconnectServiceConfigSnapshot.sharedPreferenceKeys` 只放
  `jimaku_api_key` / `qb_connection_config` / 漫画在线目录两项，文档注释明确写着
  「Bangumi/Anki credentials … remain local」。于是追番令牌
  （`media_tracking_bangumi_access_token`，见 `media_tracking_service.dart:16`）、
  视频刮削 key、OpenSubtitles / Torznab 配置全部不出境，「互联」只搬内容不搬能力：
  用户得在每台设备上重填同一个 token。
  第二个缺口在消费端 —— `app_model.dart` 的 `refreshAfterSyncRun` 导入服务配置后只
  `refreshPrefCache()`，不重建 provider runtime；而 Jimaku / OpenSubtitles / Torznab /
  TMDB 的 client 是在 `_startVideoDownloadPipeline` 里按当时的 key 一次性建好的
  （key 为空的 provider 干脆不进 registry），所以即使同步过来了也要等冷启动才生效。
- **[x] ① 已修复** — `b1570a5929`。判据改成「这条配置描述的是外部服务还是本机」：
  白名单加追番令牌 + 账号名、`video_metadata_bangumi_token`、TMDB / Fanart /
  豆瓣授权端点与 token、OpenSubtitles 与 Torznab 配置；`yomitan_api_key`（保护本机
  入站 API）、`media_source_secret_*`、`sync_*`、设备身份与本地路径仍绝不出境。
  备份 zip 落第三方云盘与 Profile 分享 JSON 两条出境仍由 `PrefRedactionPolicy` 全量
  剔除，不受本清单影响。换令牌的对账水位归零抽成共享常量
  `kBangumiTokenScopedWatermarkPrefs`，设置页与互联导入两条写入路径共用。导入后
  额外 `reloadVideoDownloadPipelineRuntime()` + bump 追番 `statusRevision`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_service_config_test.dart`
  （host 快照含哪些键 / 不含哪些键；换令牌必须归零三个对账水位；令牌没变时不得
  倒退水位）。
- **备注**：本通道是已配对 + 已认证的点对点链路，对端是用户自己的设备，与备份落
  第三方云盘、Profile 分享给别人是不同的出境等级。
