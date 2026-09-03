## BUG-1713 · 未配置索引器时资源/字幕搜索显示「没有匹配的作品」，把配置缺失伪装成搜不到
- **报告**：2026-08-18（用户：详情页「搜索资源」搜 `Spider-Man: Brand New Day` 只得「没有匹配的作品」，且看不出「默认受管视频来源」是干什么的）
- **真实性**：✅ 真 bug。
  - 一个 Torznab 索引器都没配时 `TorznabClient.search` 走空扇出：`fushi/lib/src/media/torrent/torznab_client.dart:466-487` —— `enabled` 为空 → `Future.wait([])` → 返回 items 空、failures 空、`successfulProviderCount == 0`。
  - 电影/剧集只有 Torznab 参与（`fushi/lib/src/media/video/download/video_resource_registry.dart:40` 把内置 Nyaa 门控在动漫），所以整批结果就是「零来源、零失败、零结果」。
  - `ProviderBatchResult` 的既有判据只有 `isPartial` / `isTotalFailure`（`fushi/lib/src/media/external_provider.dart:132-133`），两者都为假，UI 落到 `items.isEmpty` 分支
    `fushi/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:1105` → `t.video_discovery_empty`「没有匹配的作品」。
    「一个来源都没参与」与「来源都答了但没有匹配」共用同一个空态，用户只会一遍遍换搜索词。字幕搜索同形（同文件 `:1591`，两家 provider 都没填 key 时 registry 也是空扇出）。
  - 「默认受管视频来源」下拉只有标签没有说明（同文件 `:1179`），读起来像「搜哪个源」；它其实是下载落地的本地目录（`video_download_target_source_hint`「新下载会整理到此本地视频来源中。」，该文案只在设置页用过）。
- **[x] ① 已修复** — 提交 `<pending>`。
  - `ProviderBatchResult` 新增 `hasNoActiveProvider`（`successfulProviderCount == 0 && !hasFailures`）——零来源在数据里本来就与「来源答了」可区分，不需要新字段，只需要把这个状态说出来。
  - 资源搜索与字幕搜索各自新增 `_NoProviderEmptyState`：标题「未配置资源索引器 / 未配置字幕来源」+ 指路 `设置 → 下载 → 外部资源与字幕来源`，并说明内置 Nyaa 只覆盖动漫。
  - 「默认受管视频来源」下拉补 `helperText: t.video_download_target_source_hint`，不再让人以为它是「搜索用的源」。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_discovery_acquisition_dialogs_test.dart`
  - `零可用来源时资源搜索给配置引导而不是没有匹配的作品`；
  - `来源答了但零结果仍然是没有匹配的作品`（fake provider 返回成功空批，守住两种空态不被合并回去）；
  - `零可用字幕来源时给配置引导`。
  - 变异实测：把资源侧判据改成恒假 → 第一条红；还原后文件 sha256 与变异前逐字节一致。
- **备注**：仍是配置缺失的引导，不是替用户内置公共索引器；「要不要内置更多视频资源源」属产品决策，见 PR 说明。
