## BUG-1706 · 下载页资源标签把「无受管视频来源」误报成「请先配置下载后端」
- **报告**：2026-08-18（用户：下载页「资源」标签截图）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/downloads_page.dart:65-86`（改前）：`_loadResourceDependencies()` 在**三种截然不同**的情况下都 `return null` —— ① 资源注册表/下载流水线没就绪（后端真没配）、② `getManagedVideoDownloadSources()` 返回空（后端没问题，缺的是本地视频文件夹）、③ 后端身份解析抛异常（配了但连不上）。消费端 `_buildResourceTab` 只看得见一个 `null`，于是三种情况共用同一句 `t.download_backend_not_configured`（「请先配置下载后端。」）和同一个跳转到「下载设置」的按钮。

  用户现场：qBittorrent 后端已配好（`http://127.0.0.1:1236`、账密齐、分类 `fushi`），受管视频来源 0 条，默认下载目标来源未设。页面报「请先配置下载后端」，用户照提示跳到下载设置页，看见后端配置完好无缺，无从下手——提示把他指向了一个根本没问题的地方。

  注：`getManagedVideoDownloadSources()`（`app_model.dart:3734`）只收 `transport == 'local'` 且 `rootPath` 是**真实存在的绝对路径目录**的视频来源，所以「加过网络来源」或「加过但目录已删」同样会落到这一支。

- **[x] ① 已修复** — 把「缺什么」从页面里抽成纯函数，三种原因分开：
  - 新增 `fushi/lib/src/pages/implementations/downloads_resource_gap.dart`：`sealed class DownloadsResourceGap` = `DownloadsResourceNoBackend({String? detail})` | `DownloadsResourceNoManagedSource()`，加纯函数 `findDownloadsResourceGap({backendReady, managedSourceCount, identityError})`（返回 null = 前置条件齐备）。判定顺序（先后端、再来源、最后身份）也收在这里，不掺 I/O。
  - `downloads_page.dart` 的 `_DownloadsResourceState` 改为 `_DownloadsResourceBlocked(gap)` | `_DownloadsResourceReady(...)`；空态按 gap 分流：缺来源 → 「还没有受管视频来源…」+「添加视频来源」按钮，就地开 `MediaSourcesDialog(mediaKind: 'video')`，关掉后重算前置条件；缺后端 → 原文案 +「去设置」，且后端自己报的不可用原因（`VideoDownloadBackendUnavailable.message`）优先透传，不再退化成「请先配置」。
  - 顺带修掉一次无谓的网络往返：没来源时不再去连后端解析身份。
  - 新增 i18n key `download_no_managed_video_source` / `download_add_video_source`（走 `tool/i18n_sync.dart --add`，17 份齐，`dart run slang` 重新生成）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/downloads_resource_gap_test.dart`（7 条）：钉死「后端就绪 + 0 来源」必须判 `DownloadsResourceNoManagedSource` 且**不得**是 `DownloadsResourceNoBackend`（即用户现场那一支）、后端未就绪时的优先级、不可用原因透传、非预期异常不编造原因。
  - 变异实测：把缺来源那支改回 `DownloadsResourceNoBackend()` → 红；还原后文件 sha256 与变异前逐字节一致。
- **备注**：`home_page.dart` 的两个同形入口（`_openVideoDiscoveryResourceSearch` / `_openVideoDiscoverySubscription`）此前就已分开报 `media_source_no_sources`，不受本 bug 影响，未动。
