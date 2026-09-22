# AI 下视频：跟 AI 说作品名 → 识别 / 选版本 / 下载或订阅 / 自动配字幕

- 日期：2026-09-22
- 分支：PR1 底座 `pr/ai-acquire-foundation`（#1588）→ PR2 对话层 `pr/ai-video-acquire`
- 状态：实现中
- 前置：`docs/specs/2026-09-15-ai-feature-expansion.md`（AI 硬边界）、`docs/specs/2026-09-07-video-library-workflow.md`（资源搜索规则）

## 1. 需求（所有者 2026-09-21 / 22 原话要点）

1. 「我希望我能跟 AI 说作品，然后他给我下」——**不是**「我去搜、让 AI 排序」（旧资源搜索页 / 字幕面板的「AI 排序」按钮本 PR 移除）。
2. 画质：提前配置默认值；有人要 1080、有人要糊的、有人时大时小 → 给「每次询问」选项。
3. 字幕：肯定要（自动配）。语言默认「对应作品语言的字幕」，**第一次问、后面不问**；想临时换（「突然想看英语的」）就再跟 AI 说。
4. 直接下载还是订阅：每次问，两个都要；**只有新番才有订阅**。
5. 没有的信息 AI 会问。
6. 「以后默认」勾选框**默认勾上**。

## 2. 边界（与 `ai_feature.dart` 硬边界一致，不可违反）

- **本地纯函数状态机**（`video_acquisition_reducer.dart`）决定缺什么、问什么、何时提交；热路径（搜作品、拉详情、搜资源、选版本、入队、建订阅）全是确定性代码。
- AI 只在两处介入：① 把用户一句话解析成结构化补丁（`parseVideoAcquisitionIntent`，逐字段本地校验）；② 在已取回的作品候选里选唯一命中（复用 `AiVideoIdentityQuery / Decision`，阈值 `kAiVideoIdentityAutoAcceptConfidence`）。第三处 tie-break（同分辨率做种相近的两张卡）可选、默认不接。
- 助手发言全是 [`VideoAcquisitionSay`]（i18n 键 + 参数）+ chip；**AI 输出里没有自由文本字段**，模型散文永不进 UI。
- 未指派提供商（`AiFeature.videoAcquire`）→ 入口不渲染；AI 调用失败 → 原文当查询词 / 重出 chip，流程照样走完；chip 点击永不经 AI。
- 三处 AI 调用共用 `videoAcquire` 一个指派；旧 `videoSearch` 只剩后台 `aiSubtitleBackfillReorder`。

## 3. 底座（PR1）

| 能力 | 落点 |
|---|---|
| 放送状态归一 | `packages/fushi_engine/lib/media/video/metadata/video_airing_status.dart`：`VideoAiringStatus{airing, finished, upcoming, cancelled, hiatus}` + `normalizeVideoAiringStatus`（认不出 → null）；MAL / AniList 补填 `status` / `endDate`；`VideoMetadataWork.status` 保持原串 |
| 按作品字幕语言 | `video_download_subtitle_language.dart`：管线 `subtitleLanguageResolver` 注入点（字幕阶段每任务问一次，拿到码即**排序首选**；所有者合入 #1588 时改成「只提名次、不收窄搜索面」——它来自字幕工作台的筛选记忆，当硬过滤会让该语言没字幕的任务一条都下不到；只有全局默认字幕语言非空时才把它排到过滤列表最前；null 走全局链；异常按阶段错误冒泡）；`videoDownloadCollectionName` / `videoDownloadSeriesKey` 是合集名与每系列记忆键的唯一算法；backfill 同样吃 `SubtitleBackfillTarget.explicitLanguage`；app 接既有 `jimaku_pref_langs`。零 schema |
| 提交逻辑 | `video_discovery_submit.dart`：`enqueueLocalVideoDownload` / `createLocalVideoDownloadSubscription` / `videoResourceSubscriptionSearchQuery` 从 HomePage 抽出 |
| 库内存在性 | `video_library_presence.dart`：`resolveVideoLibraryPresence`（从订阅服务 `_managedEpisodeKeys` 抽出，单身份语义） |

## 4. 对话层（PR2）

### 4.1 文件

| 文件 | 职责 |
|---|---|
| `media/video/download/video_discovery_selection.dart` | 从 dialogs 页面抽出的选择模型 / `deriveStrictVideoSubscriptionFilter` / `videoDiscoverySubscriptionId`（页面 re-export） |
| `media/video/acquisition/video_acquisition_models.dart` | 槽位 / 问题 / 状态 / 事件 / 效果 / 意图 / 资源计划 |
| `.../video_acquisition_reducer.dart` | `reduceVideoAcquisition(state, event, defaults) → (state, effects)`，纯函数 |
| `.../video_acquisition_resource_picker.dart` | 画质过滤、订阅可行性、下载模式选集（纯函数） |
| `.../video_work_content_language.dart` | 「跟随作品语言」解析：`originalLanguage` → 制作国 → 标题文字系统 → unknown（**不硬编码日语**） |
| `.../video_acquisition_service.dart` | 编排器：执行效果、回灌事件；全部外部能力经 `VideoAcquisitionPorts` 注入 |
| `ai/ai_video_acquisition_assistant.dart` | 意图解析提示词 / 解析 / 校验；口头作品名语境的身份判定提示词；生产装配 |
| `ai/ai_video_acquisition_preferences.dart` | 两个偏好的类型化三态 |
| `pages/implementations/ai_video_acquisition_page.dart` | 对话页（不挂 Riverpod，端口注入） |
| `settings/settings_schema_ai.dart` | AI 分类下「AI 下视频」两项设置 |

### 4.2 槽位决策表（reducer 真相源）

| 槽位 | 默认来源 | 是否问 | chip |
|---|---|---|---|
| work | AI 补丁 `workQueries`（否则用户原文）依次搜到首个非空 | 0 命中 → 换个名字；1 → 不问；≥2 → AI 判定 ≥0.85 自动选并显示「已选 X（AI 判定）」，否则问 | 候选 ≤ 6 +「都不是」 |
| season | 补丁 / `reference.season` | 仅 tv 且非 anime 且 `seasonCount > 1` 且未指定 | S1..Sn +「全部」 |
| mode | 补丁 | movie → download 不问；tv 且 airing ∈ {airing, hiatus, upcoming, null} → **每次问**（null 先说「放送状态未知」）；finished / cancelled → download 不问 | 「直接下载」「订阅更新」必同时出现 |
| quality | 偏好 `ai_video_download_quality` | `''` → 问 + 「以后默认」**默认勾上**；`ask` → 问、默认不勾；固定档 → 不问。补丁 `quality` = 单次覆盖，`qualityRemember` 才写偏好 | 2160p / 1080p / 720p / 480p / 不限 |
| subtitleLanguage | 偏好 `ai_video_download_subtitle_language` | `''` → **只问一次**，预选「跟随作品语言」，勾选默认勾上 → 选完固化；`ask` → 每次问；`original` → 解析作品语言，判不出 → 临时追问一次（唯一允许再问的情形）；补丁 `subtitleLanguage` = 本作品覆盖（写每系列记忆），`subtitleLanguageRemember` 才改全局 | 跟随作品语言 / ja / zh / en / ko / 不配 |
| targetSource | 偏好 `video_download_target_source_id`；只有 1 个来源直接用 | 仅多来源且无默认 | 来源名 |
| presence | `resolveVideoLibraryPresence` 逐身份 | 已在库 / 已订阅 → 先说，问「仍要继续？」 | 继续 / 取消 |
| resource | picker 自动选第一张卡 | 总是给一次摘要确认；画质不命中 → 问「只有 {可用}，要吗？」（**不静默降级**）；订阅无可订版本 → 问「改为直接下载？」 | 就这个 / 换一个 / 取消 |

### 4.3 资源确定性规则

1. `registry.search(VideoResourceSearchRequest(media, query: videoResourceSubscriptionSearchQuery(reference), season))` → `buildVideoResourceVersionGroups`（组间序不重排）。
2. 画质：`VideoAcquisitionQuality.matchesResolution(group.resolution)` 精确匹配；`any` 不过滤；命中 0 → `resolutionMismatch` + 可用分辨率。
3. 订阅：只留 `deriveStrictVideoSubscriptionFilter(representative) != null` 的卡；`startAfterEpisode = group.episodes.min`。
4. 下载：movie → 代表条；tv Single(n) → `pickResourceVersionCandidate`；Range → 命中集 + `missingEpisodes`；All → 有合集只取做种最多的合集（`usesBatch`），否则所有能解析出集号的成员。
5. 「换一个」= 游标 +1，越界停在末组并说「没有更多版本」。
6. 提交：先 `SetSeriesSubtitleLanguageEffect(reference, code)`（`none` 不写；`original` 写解析出的具体码），再入队 / 建订阅；`subtitlePolicy` 恒 `bestEffort`（`none` → `none`）。

### 4.4 AI 契约

- 意图解析：system prompt 从代码枚举推导白名单；输入 `{locale, stage, pendingQuestion{slot, options[{index,label}]}, slots, history(≤6), utterance}`；输出 `{intent, patch{workQueries, category, season, episode, episodeRange, allEpisodes, quality, qualityRemember, subtitleLanguage, subtitleLanguageRemember, mode, choiceIndex}}`；本地校验逐字段丢弃越界值、`choiceIndex` 必须在 `[0, optionCount)`、补丁全空 → unclear。
- 身份判定：复用 `AiVideoIdentityQuery`（候选 key = `provider:mediaId`），提示词换成口头作品名语境；`parseAiVideoIdentityDecision` 白名单不变。
- 失败退化：`AiChatFailure` → UI 一行 `aiFailureText(code)`；未选定作品 → 原文当查询词；有问题挂起 → 重出 chip。

## 5. 取舍

- **每系列记忆而非 job 级列**：零 schema；代价是「这次要英文」等价于「这部作品以后都用英文」，摘要里明说「已记为本作品偏好」。
- **不移除 `AiFeature.videoSearch`**：后台补字幕重排仍用它；只删两个页面的「AI 排序 / 补词」按钮。
- **不做**：互联 host 远端订阅走 AI 流程、`fushi_server` WebUI、tie-break 之外的 AI 排序。
