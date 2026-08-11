## BUG-1538 · 下载域默认走系统代理而非直连，发现聚合来源需钉死不随代理分叉
- **报告**：2026-08-11（用户：下载那块默认不走代理（发现除外，发现是代理和直连都使用聚合来源），TODO-2798）
- **真实性**：✅ 真 bug（前半）+ ✅ 后半为守卫性钉死（现状已正确，无分叉）。
  - 根因 1：`fushi/lib/src/models/preferences_repository.dart:2109`（修前 2106）——
    `download_network_proxy_mode` 未设置时 `defaultValue: 'auto'`，即下载域
    （AniList/Nyaa/Torznab/Jimaku/OpenSubtitles 的发现类 API + 字幕下载 HTTP 客户端，
    经 `AppModel.createDownloadHttpClient` → `buildDownloadHttpClient`）默认跟随
    环境变量/系统代理，而不是直连。
  - 根因 2：`fushi/lib/src/media/torrent/download_network_proxy.dart:66`（修前 52-58）——
    `DownloadNetworkProxyMode.parse` 对 null/未知值兜底 `auto`，`DownloadNetworkProxyConfig`
    构造默认也是 `auto`，三处默认互相印证「未设置=走代理」。
  - 发现页核查：`fushi/lib/src/media/video/discovery/video_discovery_service.dart`
    `VideoDiscoveryService.production` 签名无任何代理输入，聚合来源
    （AniList + TMDB + Bangumi）恒定，不存在「代理模式用 A 来源、直连用 B 来源」的分叉；
    本条为守卫钉死，防止将来接上。
- **[x] ① 已修复** — 默认值 `auto` → `direct` 三处对齐：pref defaultValue、
  `parse` 兜底（未知值落 direct 是 fail-safe：误直连 10s 内报错可重试，误套死代理
  会把请求黑洞）、`DownloadNetworkProxyConfig` 构造默认。显式存过 `'auto'`/`'custom'`
  的用户偏好原样保留（never break userspace）。torrent payload 流量本就不经此设置
  （qBittorrent/内置引擎自管），刮削元数据/发现页继续走 `app_proxy` 全局解析层，
  不受本改动影响。提交 3c396f347b。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/download_network_proxy_test.dart`
  （unset/未知/空串 → direct；显式 auto/custom 保留；默认 config 发 `DIRECT`；
  全新 PreferencesRepository → `'direct'`，写入 `'auto'` 后不被覆盖）+
  `fushi/test/media/video/discovery/video_discovery_aggregated_sources_guard_test.dart`
  （production 聚合来源集合 = {anilist, tmdb, bangumi}；源码扫描 discovery 目录
  禁引下载代理符号）。提交 3c396f347b。
- **备注**：i18n `download_network_proxy_auto_hint` 文案描述的是 auto 档行为本身，
  仍准确，未改 key。「发现除外」落地解释：发现页与刮削走 `app_proxy`
  （env > 系统代理 > 直连，用户手填优先）且来源聚合恒定；下载域默认直连。
