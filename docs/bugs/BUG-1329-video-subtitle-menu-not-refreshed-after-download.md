## BUG-1329 · 下载/导入字幕后字幕轨列表不刷新，且重新枚举时长时间挂加载条
- **报告**：2026-08-01（用户：视频页「字幕」分类截图 —— 「我手动下载完以后，这里没有下载的字幕，而且一直在加载」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart`（修复前的 `_invalidateSubtitleMenuSourcesCache` 及其两个调用点：`_openJimakuDialog` / `_importExternalSubtitleInner`）。

  字幕轨列表 `_subtitleMenuSources` 的**唯一**重建驱动事件是「进入字幕分类」
  （`VideoQuickSettingsSheet.onSubtitleCategoryShown` → `_ensureSubtitleMenuSourcesLoaded`，
  见 `video_quick_settings_sheet.dart:70/86/104`）。而 Jimaku 下载 / 外挂导入完成后，代码
  只做了 `_subtitleMenuSourcesPath = null`（作废缓存 key），**指望「下次进入字幕分类」再重
  枚举**。两个后果：

  1. **列表不刷新**：下载几乎总是**从已经打开的「字幕」分类里**发起的（用户就是点那一行
     「获取字幕」进去的）。面板不关、分类不切 → `onSubtitleCategoryShown` 不会再触发 →
     列表原样停在旧枚举结果，刚下载的字幕根本不出现。另外
     `listAllSubtitleSources` 按设计只看内嵌轨 + 视频同目录 sidecar，落在
     `<dataRoot>/documents/video_subtitles/` 的下载档只能靠
     `includeCurrentPersistedSubtitleForMenu` 作为「当前项」被注入 —— 而那一步同样只在重枚举
     时才跑。
  2. **长时间加载条**：真去重枚举时又要对整个容器重跑一遍 `ffmpeg -i`（超时预算按文件体积
     放大，见 `subtitleExtractTimeoutForBytes`），期间 `_subtitleMenuLoading=true`，字幕轨区
     顶部挂 `LinearProgressIndicator`，旧行还在、新行没有 —— 正是截图里的样子。而这趟重探
     带来的唯一新信息，就是我们手里那个已知路径的外挂文件。

  同一批顺手补掉一处**结构性**加载态泄漏（诚实标注可达性）：`_applyYoutubeCaptionTrack` 里
  `_subtitleMenuLoading = true` 之后靠三条各自复位的 return 路径收尾，一旦
  `resolveYoutubeCaptionCues` 抛出，谁也走不到，标志永久留在 true 且再无入口能关掉它。
  **但复核发现这条当前不可从网络/解析失败触发**：`resolveYoutubeCaptionCues` 自己带
  `catch (_) { return const <AudioCue>[]; }`（`youtube_source_resolver.dart:979`）把 body 里
  的一切都吞成空 cue，仅剩 `YoutubeHttpClient()` 构造与 `http.close()` 两条极窄的抛出面。
  所以这是**防御性收敛**，不是已复现的用户症状；价值在于那层 blanket catch 一旦被收窄
  （它本身就是个该收窄的东西），泄漏立刻变成活的。加载态收进 try/finally 后与之解耦。

- **[x] ① 已修复** — `_registerImportedSubtitleSource(path)` 取代缓存作废式刷新：新档是 app 自己
  刚写下的外挂文件，路径与标签都在手里，直接插进 `_subtitleMenuSources` 首位（与
  `includeCurrentPersistedSubtitleForMenu` 的「当前导入排最前」约定一致），枚举缓存 key 保持
  有效、不重探容器。两个落盘点（Jimaku 下载 / 外挂导入）统一走它。另外
  `_ensureSubtitleMenuSourcesLoaded` 的加载态收敛成单出口（枚举失败用 `null` 表达，不再有
  「某条 return 忘了复位」的分支），`_applyYoutubeCaptionTrack` 的 cue 解析包进 try/finally。
  提交：见本分支 `fix(video): ...` commit。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_subtitle_menu_refresh_guard_test.dart`
  （静态守卫：两个落盘点都调 `_registerImportedSubtitleSource`；并入路径不重置缓存 key、不点亮
  加载态、按 `sameExternalSubtitlePathForMenu` 去重；旧的缓存作废 helper 零残留；YouTube cue
  解析必须 try/finally 收敛加载态；枚举加载态置真后只有唯一复位点）。media_kit 跑不了 headless、
  ffmpeg 枚举也不能在单测里真跑，故锁调用点契约。
- **备注**：同批用户诉求还有两项（非 bug，属改进）：①「自动获取字幕」改名为「获取字幕」
  （i18n key `video_jimaku_fetch` 值改，17 语言同步）；② Jimaku 对话框支持按字幕**类型**筛选
  （ass/srt/ssa/vtt chip，纯函数 `filterCandidatesByFormat` / `availableFormats`，测试见
  `hibiki/test/pages/jimaku_filter_test.dart` 与 `jimaku_format_filter_widget_test.dart`）。
