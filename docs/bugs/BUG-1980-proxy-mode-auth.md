## BUG-1980 · 网络代理无法显式禁用且不支持认证
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。原设置只有 `settings_schema_system.dart` 中单个 `host:port` 文本项；空值固定进入“环境变量 → 系统代理 → 直连”，无法表达“强制直连”，`app_proxy.dart` 也未设置 `HttpClient.authenticateProxy`，407 认证代理必然失败。
- **[x] ① 已修复** — 增加“自动 / 直连 / 手动”一等模式，手动模式显示服务器、用户名和遮蔽密码；网络装配层按模式裁决并仅在代理 challenge 时注入凭据（`116dc112f2`）。
- **[x] ② 已加自动化测试** — `test/utils/net/app_proxy_local_bypass_test.dart` 覆盖强制直连、手动配置非法时不偷用系统代理，以及 407 challenge 凭据注入。
- **备注**：本机、局域网与 mDNS 目标继续由共享闸门强制直连；P2P 仍需单独明确开启。
- **审查补修**（在 ① 的基础上，同一 PR 内）：
  - 407 凭据改成**同一 (host,port,scheme,realm) 只交付一次**。原实现每次 challenge 都
    无条件 `addProxyCredentials` 并返 true，而 `dart:io` 的 `retry()` 没有深度计数器，
    密码填错就会「407 → 移除已用凭据 → 再问回调 → 又加同一份 → retry」无限打转，
    请求永不返回、用户只看到转圈。
  - Digest challenge 直接放弃。原实现对任何 scheme 都塞 `HttpClientBasicCredentials`，
    `findCredentials(Digest)` 永远匹配不到，同样是无限环。文档注释也从
    「Basic/Digest」改成只声明 Basic。
  - 迁移判据从「地址非空」改成「地址**归一得出来**」。设置页历来对非法地址只弹
    SnackBar 却仍存原串，存量里有 `[::1]:7890`（IPv6 不支持）、带路径、带空格等值；
    按非空推成 manual、manual 归一失败又硬走 DIRECT = 这批用户升级即全应用断网。
    只有「用户显式选了 manual」才 fail-closed。
  - `network_proxy_mode` / `update_download_source` 补进 `ProfileKeys._excludedPrefKeys`。
    它们描述这台设备的网络与更新策略（与 `update_custom_proxy` /
    `update_beta_channel` 同族），漏登记会让切一次 Profile 就把全局网络出口翻掉。
- **已知欠账**（本 PR 不修，需要单独跟进）：
  - **「首选下载源」在真实下载路径上基本不生效**：`update_checker_download.dart` 会调
    `orderedCandidatesAfterRace` 对全部候选并发探针竞速并把最快的提首位，默认参数下
    该门控必然成立。用户选的源只剩 500ms 的 tie-break 宽限。设置提示写的「优先尝试
    所选来源」目前不成立。修法是把 preference 透传进去，`!= auto` 时不竞速。
  - **选 Cloudflare 在非官方资产上静默空转**：`officialR2UrlForUpdateAsset` 对旧仓库名
    / 第三方 host / 畸形路径返 null，直接回退自动顺序且 UI 零提示。
  - **代理认证到不了内置 torrent 引擎**：下发给 libtorrent 的只有 `host:port`，凭据无处
    安放。开了「P2P 走代理」+ 代理需认证时 libtorrent 侧静默失败，设置页看起来正常。
    至少该在 UI hint 里写明「认证仅对 HTTP 出站生效」。
  - **`update_download_source` 结构性逃出设置覆盖守卫**：它渲染成
    `AdaptiveSettingsPickerRow`，而 `settings_schema_coverage_test` 的
    `_focusedSettingsRow()` 只识别 Switch/Slider/Stepper/Segmented 四种，PickerRow 从未
    被识别过。这是守卫自身的盲区，不是本 PR 引入。
  - **15 种语言的新 key 仍是英文占位**（`i18n_sync --add` 的已知行为），待补译。
