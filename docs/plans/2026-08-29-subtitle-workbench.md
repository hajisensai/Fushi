# 字幕工作台：全屏调整 + 搜索/配置结构重构 + 合集作用域 + AJATT 字幕源

日期：2026-08-29 · 状态：**已确认（2026-08-29）**：① 底部抽屉+视频全幅继续播 ② AJATT 默认开启 ③ 合集加「语言 + 版本组」两列，**语言 null = 跟随视频内容语言（`resolveContentLanguage`），不是 ja** ④ 三条 PR A→B→C · 分支 `worktree-subtitle-fullscreen-refactor`（基底 origin/develop `e880296955`）

## 0. 需求理解（请确认）

1. **字幕调整改全屏**：现在字幕样式/调轴/位置都塞在右侧半透明「设置」侧栏（`fushiQuickSettingsPanelWidth` 560~900px），遮掉三分之一画面还要滚。要改成**全屏调整模式**：视频继续放当实时预览，控件浮在画面上、可收起。
2. **重构字幕搜索/配置结构**：现在搜索入口叫 `JimakuSubtitleDialog`（1413 行，名字是 Jimaku、实际已聚合 OpenSubtitles），合集批量是另一个 `JimakuBatchDialog`（**直连 `JimakuClient`，绕过 `VideoSubtitleRegistry`**，所以 OpenSubtitles 永远进不了批量路径），语言记忆按「番名小写」当 key 存 prefs。三处各写一套，要收成一个。
3. **合集内视频可给整个合集搜/配字幕**：播放页目前只有单集搜索；批量只在媒体库右键 / 合集详情页。
4. **新增字幕源 `subtitles.ajatt.top`**（Ajatt-Tools/kitsunekko-mirror 镜像）。

## 1. 现状事实（沿真实代码路径核过）

| 事实 | 位置 |
|---|---|
| provider 抽象已存在：`VideoSubtitleProvider{search,download,allowsFreeProbeDownload}`，候选 `VideoSubtitleCandidate` 带 `collectionId/episode/language/uploadedAtMs` | `fushi/lib/src/media/video/subtitle/video_subtitle_provider.dart` |
| 注册表并行搜全部 provider、按 anime 把 jimaku 排前 | `media/video/download/video_subtitle_registry.dart` |
| 装配点：Jimaku（enabled && key）/ OpenSubtitles（enabled && key），**没 key 的用户一个源都没有** | `models/app_model.dart:3963-3999` |
| 单集判据唯一原语 `chooseJimakuFileForEpisode`，但类型钉死 `JimakuFile` | `media/video/jimaku_matching.dart:154` |
| 身份种子 `SubtitleSearchSeed`（AniList/TMDB id + 日文原名优先） | `media/video/subtitle/subtitle_search_seed.dart` |
| 播放页调起：`_openJimakuDialog` → `showDialog(JimakuSubtitleDialog)`；seriesKey = query 小写 | `pages/implementations/video_fushi/subtitle.part.dart:1102` |
| 播放页知道合集：`widget.playlistCollectionId` | `video_fushi_page.dart:480, 2170` |
| 合集级已有：`MediaCollections.subtitleDelayMs / secondarySubtitleDelayMs`，解析 `effectiveSeriesDelayMs` | `packages/fushi_core/.../tables.dart:973,980`；`media/video/series_playback_prefs.dart` |
| 每集：`VideoBooks.subtitleSource / secondarySubtitleSource / delayMs / secondaryDelayMs` | `tables.dart:590-640` |
| 字幕样式/调轴 UI = 快捷设置侧栏 `_VideoSidePanelKind.settings` → `VideoQuickSettingsSheet`（schema 投影）+ `VideoQuickSettingsHost` 能力槽（预览/提交回调齐全） | `video_fushi_page.dart:6817-6960`；`video_fushi/side_panel.part.dart` |
| 已有「拖拽调字幕位置」全屏模式 `_enterSubtitleDragAdjust`（关侧栏 + 开拖拽） | `video_fushi/layout.part.dart:996` |
| 已有「波形对轴」弹窗，带整表快捷键透传 | `subtitle_waveform_align_panel.dart` |
| **第三个搜索宿主**：发现页 `VideoDiscoverySubtitleSearchPage`（同 registry、状态机另写一套，BUG-1685 记录过） | `pages/implementations/video_discovery_acquisition_dialogs.dart:1434`；调起 `home_page.dart:1612` |
| 互联远端路径 `remote_jimaku_subtitle_handlers.dart` **有意绕过** registry——改 registry 契约时要一并核 | `sync/remote_jimaku_subtitle_handlers.dart:12` |
| 全屏路由复用同一个 controls builder（`_buildVideoControlsInner`），侧栏/popover/OSD/拖拽横幅在全屏下自动存在 → 新抽屉挂进这个 Stack 即可，不另起 `showDialog` 层（波形弹窗是反例） | `video_fushi/layout.part.dart:271, 507-522`；`fullscreen.part.dart:105` |
| `VideoQuickSettingsSheet` 已有 `initialCategory`/`onSubtitleCategoryShown`/`subtitleTrackSection` 槽 | `media/video/video_quick_settings_sheet.dart:26`；`video_quick_settings_host.dart:214-215` |
| i18n 源文件是 `fushi/lib/i18n/strings.i18n.json`（非 en.i18n.json）；前缀族 `video_setting_subtitle_*`（行+`_hint`）/ `video_subtitle_*`（运行时）/ `video_jimaku_*`（对话框，**新 key 不再用**） | — |

### AJATT 源的形态（实测 2026-08-29）

- 站点是**纯静态 HTML**，无 JSON/API：`index.html`（4998 行：anime_tv 3530 / anime_movie 1042 / unsorted 426，3.6 MB）+ `drama.html`（7688 行：drama_tv 3640 / drama_movie 4048）。每行 `<tr data-timestamp data-entry-type>` + `<a href="anime_tv/<slug>.html">` + `english_name` + `japanese_name`。
- 作品页 `<type>/<slug>.html`：文件表每行 `data-download-url`（**指向 `raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/subtitles/<type>/<dir>/<file>`**）+ `data-filename` + `data-file-size` + `data-timestamp`；分 srt / ass / all 三段。
- 每个作品目录里有 **`.kitsuinfo.json`**：`{entry_id, name, entry_type, english_name, japanese_name, anilist_id}` → **可以按 AniList id 确认身份**（和 Jimaku 同一强身份路线）。
- 仓库每 3 小时更新；无 API key、无配额；GitHub Git Trees API 被截断（>44907 项），Contents API 未登录 60 次/小时——**不能当主索引**。
- 文件名集号写法与 Jimaku 同一生态（`S01E01` / ` - 01 ` / `第1話` / 无集号整季单文件），现有 `JimakuFile.episode` 解析器直接复用。

## 2. Linus 三问

- 真问题？是。四处真实缺口：① 无 key 用户零字幕源；② 批量路径绕过 registry；③ 播放页没有合集作用域；④ 调整面板遮画面。
- 更简单的办法？**不做第四个对话框**。把「单集 / 合集」做成同一个工作台的作用域开关；把 `JimakuFile` 钉死的判据泛化到 `VideoSubtitleCandidate`，AJATT 只是 registry 里第三个 provider，批量/回填/流水线自动受益。
- 会破坏什么？持久化 key（`jimaku_*` prefs、`subtitleSource` 编码、`MediaCollections` 列）**全部冻结不动**；老入口（媒体库右键 / 合集详情页 AppBar）保留、只换目标 widget。

## 3. 设计

### 3.1 数据结构先行

```dart
/// 工作台作用域：一集，或一个合集的全部成员。播放页/库页/合集页都只构造这个。
class SubtitleWorkbenchTarget {
  final SubtitleScope scope;            // episode | collection
  final VideoBookRow current;           // 当前集（合集作用域下用于默认高亮）
  final MediaCollectionRow? collection; // 合集作用域必填
  final List<VideoBookRow> members;     // 合集有序成员（episode 作用域 = [current]）
  final SubtitleSearchSeed seed;        // 身份种子（AniList/TMDB id + 日文原名…）
  final String? videoPath;              // 本地路径（OSDb 指纹用；远端 null）
}
```

- **判据泛化**：`jimaku_matching.dart` 的 `JimakuEpisodeIndex` / `chooseJimakuFileForEpisode` 改成对 `VideoSubtitleCandidate` 工作（新文件 `subtitle/subtitle_episode_matching.dart`，`SubtitleEpisodeIndex` / `chooseSubtitleForEpisode`），旧名保留为薄 re-export 兼容层（现有 5 条路径的测试不动）。
- **合集级字幕配置**（新）：`MediaCollections` 加两列（schema v89（实际落地号；方案初稿误写 v63））：`subtitleLanguage TEXT NULL`、`subtitleReleaseGroup TEXT NULL`（版本组/来源标签，来自 `subtitle_version_groups.dart` 的分组键）。语义与 `subtitleDelayMs` 同款：**null = 没人配过 → 回退视频内容语言链 `resolveContentLanguage`（BUG-1700：用户显式 > 视频内容语言 > 不表态；绝不硬编码 ja）**，非 null 覆盖每集。现有 prefs `jimakuPreferredLanguages[seriesKey]` 只读迁移：合集有列值优先，否则回退 seriesKey 记忆（Never break userspace）。
- **AJATT 目录缓存**：`<appSupport>/subtitle_catalogs/ajatt.json`（解析后的紧凑条目：type/slug/name/en/ja/lastModified），带 `fetchedAt` + `ETag`；24 h 内不重拉，拉取/解析在 isolate 里做。

### 3.2 `AjattSubtitleProvider`（id `ajatt`，priority 150，Jimaku 之后）

搜索流程（对齐 Jimaku 「先身份后文本」）：
1. 目录缓存就绪（首次约 9 MB，之后 24 h 一次 HEAD/ETag）。
2. 候选作品：按 `alternateTitles`+`originalTitle`+`query` 对 `japanese_name / english_name / name` 做 `matchesMediaSearch` 归一化匹配，取前 5。
3. 若请求带 `anilistId`：逐个拉候选作品的 `.kitsuinfo.json`（≤5 次 raw 请求），`anilist_id` 相等的**直接确认、其余丢弃**；没带 id 才走纯文本命中。
4. 拉作品页 HTML，解析文件表 → `VideoSubtitleCandidate`（`collectionId`=作品 slug、`collectionLabel`=name、`episode` 复用 `parseJimakuEpisode`、`language` 复用 `detectSubtitleLanguage`、`uploadedAtMs`=data-timestamp、`fileSize`）。
5. 下载 = GET raw.githubusercontent（走 `createDownloadHttpClient` 代理策略）；`allowsFreeProbeDownload = true`（无配额）。

失败映射：站点 4xx/5xx → `unavailable`（retryable=5xx）；HTML 结构对不上 → `invalidResponse`（守卫测试用真实页面 fixture）。

设置页：`video_external_provider_settings_section.dart` 加第三张卡「AJATT（kitsunekko 镜像）」，只有开关 + 「清目录缓存」；**默认开启**（零配置，首个无 key 也能用的源；GitHub 不通只是一条 provider failure，不影响其它源）。新 pref `video_subtitle_ajatt_enabled`（默认 true）。

### 3.3 统一「字幕工作台」`SubtitleWorkbenchPage`——**全屏页面**（取代两个 Jimaku 对话框 + 发现页搜索页）

> 用户 2026-08-29 明确：字幕下载页也要改成全屏（不再是 `showDialog` 弹窗）。整页路由 `Navigator.push`（全屏态下推到 root navigator，关闭后 `_focusOwnership.reclaim`）；宽屏左栏筛选/身份 + 右栏列表，窄屏单列。

```
┌ 字幕 ───────────────────────────────── [本集 ▾ | 整个合集] ──┐
│ 作品：けいおん! (AniList 5680) [换作品]  语言 [ja][en][zh]  格式 [srt][ass] │
│ 来源  ○ Jimaku 12 文件  ○ AJATT 51 文件  ○ OpenSubtitles 3      │
│ ─────────────────────────────────────────────────────────── │
│ 本集：候选列表（版本组聚类 + 时长校验标记 + 下载/应用）           │
│ 合集：逐集表  # | 集名 | 匹配文件 | 状态  … [全部下载并应用]      │
│ 合集配置：默认语言 ▾  版本组 ▾  调轴 ±ms  副轨调轴 ±ms            │
└──────────────────────────────────────────────────────────────┘
```

- 文件 `pages/implementations/subtitle_workbench_page.dart`；`jimaku_subtitle_dialog.dart` 的搜索/候选/探测/下载状态机整体搬入（不是重写：`_search / _fetchCandidates / _probeUnknownLanguageGroups / _downloadSource` 逐段迁移），`jimaku_batch_dialog.dart` 的逐集匹配+`_downloadAll/_persist` 迁成合集作用域分支，**改走 registry**（这是它第一次能用 OpenSubtitles/AJATT）。
- 两个旧类保留为薄壳（构造同签名 → 内部 `SubtitleWorkbenchPage`），媒体库右键 / 合集详情页入口不改调用方；改完跑现有 `jimaku_*` 测试确认零回归后再删壳。
- 发现页 `VideoDiscoverySubtitleSearchPage` 同样改为工作台的第三个调用方（episode 作用域、无本地路径），三处状态机合一；互联远端 handler 保持绕过 registry 不动。
- 播放页字幕菜单：「自动获取字幕(Jimaku)」→「搜索字幕…」（i18n `--rename`），`playlistCollectionId != null` 时工作台默认作用域仍是本集、顶部可切「整个合集」。
- 命名：类名/文件/新 i18n key 全部 `subtitle_*`，不再产生 `jimaku_*` 新名（Jimaku 只作 provider 名出现）；存量 prefs key 冻结。

### 3.4 全屏字幕调整 `SubtitleAdjustOverlay`

- 挂载点：`layout.part.dart:520` 旁的 controls Stack（与侧栏/popover 同层），因此窗口态与全屏路由**同一份代码自动生效**；不用 `showDialog(useRootNavigator)`（那是波形弹窗的反例，得靠 guardOverlay 归还焦点）。
- 新前景层（`video_foreground_layers.dart` 加一层，与 `_enterSubtitleDragAdjust` 同一互斥组：进入时关侧栏/popover/弹幕匹配面板）。
- 形态（推荐 A）：**底部半透明抽屉 + 顶部薄条**。视频全幅可见、继续播放；抽屉高度可拖（默认 38%，可收成一条 tab 栏）；tab = 样式 / 位置 / 调轴 / 轨道。字幕区域高亮描边，样式滑块拖动即 `onSubtitleStylePreview`、松手 `onSubtitleStyleCommit`；「位置」tab 直接进拖拽（复用现成的拖拽层，不再是单独模式）；「调轴」tab 内嵌波形面板（已存在）；「轨道」tab = 现在字幕菜单那一列（主/副轨、导入、搜索字幕…）。
  - 备选 B：整屏磨砂卡片盖住视频只留缩略预览——否定，预览失真、和「全屏」诉求相反。
- 内容**不重写**：抽屉里放 `VideoQuickSettingsSheet(initialCategory: subtitle, host: _buildVideoQuickSettingsHost())` 同一 schema 投影，只是换容器 + 分 tab；这样设置页/侧栏/全屏三处永远同一份行。
- 入口：字幕菜单第一项「调整字幕…」、快捷设置侧栏字幕分类顶部按钮、新 `ShortcutAction.videoOpenSubtitleAdjust`（默认无键，进整表可重映射）、手柄 Y 长按不占用。
- 退出：Esc / 返回 / 抽屉「完成」；退出后 `_focusOwnership.reclaim(FocusReclaimCause.overlayClosed)`。
- 快捷键：抽屉打开时复用 `buildVideoPlayerShortcutsFromRegistry(..., exclude: {globalBack, toggleFullscreen, toggleSubtitleList, immersiveLock, openSubtitleAdjust})`，与波形弹窗同一套排除表。
- 触屏：抽屉手势拖高/收起；`FushiAppUiScale` 包一层（与侧栏一致）。

## 4. 影响范围与风险

- **改**：`app_model.dart`（装配 ajatt）、`video_subtitle_registry.dart`（排序表加 ajatt）、`jimaku_matching.dart`（泛化+兼容层）、`subtitle.part.dart`（入口/调起）、`side_panel.part.dart` + `layout.part.dart`（前景层互斥）、`video_foreground_layers.dart`、`settings_schema_video.dart`（provider 卡）、`preference_keys.dart`、`tables.dart`+`database.dart`（v89 两列）、`jimaku_subtitle_dialog.dart` / `jimaku_batch_dialog.dart`（搬空成壳）、`home_video_page.dart` / `media_collection_detail_page.dart`（调用方不改签名，仅目标类）。
- **新**：`media/video/subtitle/ajatt_catalog.dart`（HTML 解析 + 缓存）、`ajatt_subtitle_provider.dart`、`subtitle_episode_matching.dart`、`pages/implementations/subtitle_workbench_page.dart`、`media/video/subtitle_adjust_overlay.dart`。
- **风险**：
  1. GitHub 在部分网络不可达 → 只表现为 AJATT 一条 failure，其它源正常；设置页可关。
  2. schema v89（实际落地号；方案初稿误写 v63） 迁移：两列 nullable、无回填，迁移阶梯只 `addColumn`；升级不改任何既有行为。
  3. 判据泛化是全仓 5 条字幕路径的共同依赖 → 保留旧符号 re-export + 跑全部 `jimaku_*`/`subtitle_*` 测试（含 PR#878 那批）。
  4. 前景层互斥：新层必须进 `_hideVideoSidePanel`/`_hideControlPopover` 的关闭链，否则会出现「抽屉开着侧栏也开着」的双层（BUG-1864 备注：侧栏/popover 是兄弟，焦点进去整表失效）。
  5. i18n：改名只准 `--rename`，新 key 全 17 语言。

## 5. 分期与验证

| 期 | 内容 | 可独立合入 | 验证 |
|---|---|---|---|
| PR-A ✅ 2026-08-29 | AJATT provider + 目录缓存 + 设置开关 + 装配 | 是 | 真实 HTML fixture 单测（index/drama/作品页/`.kitsuinfo.json`，`test/media/video/ajatt_*_test.dart`）；真联网冒烟：目录 12686 条 0.96s / 缓存 2.4MB 二次 64ms / AniList 5680 搜索 1.6s 得 4 条 K-ON! ep1 / 真实下载 36114B。**App 内 UI 真机验证未做**（provider 走 registry，播放页/设置页只多一张卡）。踩坑：站点 `unsorted` 行 class 是 `entry_name missing_meta`（正则按前缀匹配，否则 426 条整体漏）；`http.Response(String)` 桩默认 latin1，含日文必抛 |
| PR-B ✅ 2026-08-29 | 判据泛化 + `SubtitleWorkbenchPage`（单集+合集作用域，改走 registry）+ 三处入口 + 合集级语言/版本组列（v89） | 是 | 定向 380 条绿（含 8 份存量 jimaku 页面测试、MD3/源码守卫、迁移）。**未做**：Windows 真机点击验证；发现页 `VideoDiscoverySubtitleSearchPage` 仍是独立状态机（第三宿主，后续）；`JimakuSubtitleDialog` 壳只剩测试在用（8 份测试待迁到面板后删）；`runJimakuBatch` 留给老订阅路径。**撞号提醒**：PR#1051（统一代理）也用 v89，后合入者改 v90 |
| PR-C ↩ 2026-08-31 | 撤回字幕入口的底部抽屉分流；字幕轨按钮继续打开右侧设置栏并直达「字幕」分类，避免轨选择入口改变既有容器位置 | 是 | 源码守卫锁定 `_showPlayerSettings(initialCategory: 'subtitle')` 仍使用 `_VideoSidePanelKind.settings`，并禁止 `subtitleAdjust` 专用分流。**未做**：Windows 真机/离屏像素验证 |

## 6. 需要你拍板的点

1. 全屏调整形态选 **A（底部抽屉 + 视频全幅继续播）** 还是别的？
2. AJATT **默认开启**（零配置源）是否接受？
3. 合集级「版本组」要不要入库（schema v89（实际落地号；方案初稿误写 v63））？不入库则只做「语言」一列，版本偏好只在本次批量内生效。
4. 三期分 PR 还是一条 PR 到底？
