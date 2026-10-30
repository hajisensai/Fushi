# 歌词来源插件（v1）

状态：设计（未实现）。建立在音乐插件宿主之上（[`2026-10-28-music-plugins.md`](2026-10-28-music-plugins.md)），
不改其「仓库不内置任何平台协议实现」「iOS 不提供」两条边界。

所有者已拍板：
- LRCLIB 是**内置默认来源**，永远排第一、不可移除；
- 其余来源**全部是插件**，用户手动安装：不内置任何插件、首次启动不弹引导；
- 插件由用户（自己）用 Ed25519 签名，放在独立仓库，本仓不收；
- 旧的单开关「非官方在线歌词」（`music_lyrics_unofficial_online`）由**来源列表**取代（启停 + 排序）。

非目标：不在本仓移植网易云 / QQ / 酷狗的 Dart 客户端；不做歌词编辑（CLAUDE.md 黑名单）；不做自动注音。

## 1. 现状（本分支）

| 事实 | 位置 |
|---|---|
| `lyrics` 能力 = 「**插件自己的曲目**按曲目 id 要歌词」，参数 `{id}`，返回 `{original?, translation?, romanization?}`（`LyricText{format,text,language?}`） | `packages/fushi_music/lib/src/plugin/plugin_source.dart:553`，DTO `plugin_models.dart:892`（`MusicPluginLyrics`），枚举 `plugin_models.dart:172` |
| 能力词表（Rust 真值）与依赖规则（如 `searchBest` 需 `search`） | `native/fushi_music/src/plugin/manifest.rs:11`、`:112-150` |
| 歌词解析链：user → sidecar → 内嵌 → ③'插件自带 → ④LRCLIB。③' 只在 `plugin != null`（曲目路径是 `fushi-music-plugin://`）时走，本地 / 服务器曲目永远走不到插件 | `fushi/lib/src/media/music/lyrics/music_lyrics_service.dart:378-440` |
| 插件歌词缓存键 `provider:plugin:<id>`，LRCLIB `provider:lrclib`；缓存行 + 负缓存（插件 1 天、LRCLIB 7 天） | `music_lyrics_sources.dart:9-23`，`music_lyrics_service.dart:28-30` |
| 原文 + 译文按时间合并、落库存 TTML | `buildMusicPluginLyrics`（`music_lyrics_service.dart:36` 起） |
| 装配：`pluginLyrics:` 回调直取 `musicPluginManager.source(id).lyrics(trackId)`；LRCLIB 受 `music_lyrics_online` 总开关控制 | `fushi/lib/src/models/app_model.dart:1856-1864`，偏好 `preferences_repository.dart:4543` |
| 设置：「歌词」分区只有 `music_lyrics_online` 开关；插件管理在「插件音源」分区 | `fushi/lib/src/settings/settings_schema_music.dart:335-372`，`pages/implementations/music/music_plugin_settings.dart`（能力标签 `:23-30`） |
| iOS 门：`isMusicPluginSourcesAvailable`（`StoreRestrictedCapability.onlineMusicSource` + 原生库带插件特性） | `media/music/plugin/music_plugin_gate.dart:11` |
| **`music_lyrics_unofficial_online` 在本分支不存在**，只在 `integ/samu-on-develop`（`preferences_repository.dart:4463`、`settings_schema_music.dart:339`）。该分支的 `online_lyrics_provider.dart` 是评分 / 查询词的参考实现（只读） | 见 §5 迁移 |

结论：现有 `lyrics` 与本需求不同——它假定宿主已握有平台曲目 id；歌词插件面对的是**本地 / 服务器曲目的
标题 + 艺人 + 时长**，要先搜索再取词。故新增两个能力，不改动 `lyrics` 语义。

## 2. 插件契约

新增能力 `lyricsSearch` 与 `lyricsFetch`（入口模块导出同名函数，可 async）。**必须成对声明**
（只有一个 → 拒装），与 `search` / `stream` 等**无依赖**，所以「纯歌词插件」只声明这两个。

```ts
lyricsSearch({ query, title, artist?, album?, durationMs? })
  → { items: [Candidate] }          // 宿主最多取前 20 条，空数组 = 没有
Candidate { title, artist, durationMs?, ref }
  // ref：插件自定的不透明 JSON（id / mid / id+accesskey 等），序列化后 ≤2 KiB，宿主原样回传
lyricsFetch({ ref })
  → { original: LyricText, translation?: LyricText } 或 null      // null = 这条没有可用歌词
LyricText { format: 'lrc'|'yrc'|'qrc'|'krc'|'ttml'|'txt', text, language? }   // 与 §4 `lyrics` 同一类型
```

- `query` 由宿主生成（§4），`title` / `artist` / `album` / `durationMs` 是原始曲目信息，插件愿意可自己拼。
  宿主会对同一首歌依次用多个 `query` 调 `lyricsSearch`（见 §4），所以插件**不要**自己做多轮回退。
- `format` 直接当 Rust 解析器 hint（`FushiLyricsAsync.parse(bytes, hint: format)`）；`yrc` 逐字、`lrc` 逐行。
  与所有者口述的 `{raw, format, translation?}` 的差别只是字段名：复用 `LyricText` 才能原样走
  `MusicPluginLyrics.fromJson` + `buildMusicPluginLyrics`（译文合并、TTML 落库）零新增解析代码（待确认，见 §9）。
- 不可信输入处理（只影响显示，不让整次失败）：候选缺 `title` / `ref` 丢弃；`title` / `artist` 去空白并截断 200；
  `durationMs` 非负整数否则当缺失；`text` 空 → 当 null；`text` 上限 1 MiB。
- 超时：`lyricsSearch` / `lyricsFetch` 各用现有单步 2 s CPU 预算；网络超时由插件在 `fushi.http.request` 给（≤60 s）。
  宿主对一次完整「搜索 + 取词」另设 25 s 总限，超时当失败。
- 错误：抛错 = 该来源失败（不写负缓存，继续下一个来源）；返回空 / null = 「没有」（写负缓存）。

### 清单示例（纯歌词插件）

```json
{
  "schema": 1, "id": "moe.example.lyrics", "name": "示例歌词源", "version": "0.1.0", "api": 1,
  "entry": "main.js",
  "capabilities": ["lyricsSearch", "lyricsFetch"],
  "permissions": ["network", "insecureHttp"],
  "network": { "domains": ["lyric-api.example.com", "*.cdn.example.com"], "methods": ["GET", "POST"] }
}
```

- 不需要 `searchTypes`（只有声明 `search` 才要，`manifest.rs:118`）；通常也不需要 `storage` / `credentials`。
- 必须 `network` + `network.domains`（歌词插件不联网没有意义；规则同 §2 现有校验）。
- 只有站点只给 `http://` 才加 `insecureHttp`；授权界面照常提示。IP 字面量 / 私网 / 回环照旧拒绝。
- 新增 Rust 规则：`lyricsSearch` 与 `lyricsFetch` 必须同时声明；纯歌词插件（没有 `search`/`home`/…
  任何浏览类能力）**不出现在「插件音源」浏览页与服务器曲库入口**，只出现在设置里（见 §6）。

## 3. 来源模型与优先级

解析链改为（`music_lyrics_service.dart`）：user → sidecar → 内嵌 → **来源列表依次问**：

1. 插件曲目的「自带歌词」（现有 ③'，`lyrics` 能力，键 `provider:plugin:<id>`）仍排最前——它按平台曲目 id 取，最准；
2. **LRCLIB**（固定第一，`provider:lrclib`，精确匹配 + 现有逻辑，不变）；
3. 用户启用的歌词插件，按用户排序，逐个：缓存命中（含负缓存）→ 否则 `lyricsSearch` → 评分挑 → `lyricsFetch` →
   落库 `provider:plugin:<id>`；第一个拿到歌词的胜出，其余不问。

缓存键沿用 `provider:plugin:<id>`：同一插件对同一曲目只会走「自带」或「搜索」其中一条路，不冲突；
`MusicLyricsSource.isPlugin` / `pluginIdOf` 无需改。负缓存 1 天（`kPluginLyricsNegativeCacheTtl`）逐来源记录。
用户重排 / 启停来源后不清缓存；缓存里有高优先级来源的有效行就直接用，不会被低优先级覆盖。

## 4. 宿主侧评分

把 samu 分支 `online_lyrics_provider.dart` 里**纯函数**抽成独立文件（不带任何平台客户端、不带 HTTP）：
`fushi/lib/src/media/music/lyrics/lyrics_candidate_scoring.dart`。

- `LyricsCandidate`（≈ 原 `OnlineLyricsHit`：`providerId` / `title` / `artist` / `durationMs?` / `ref`）；
- `pickBestLyricsCandidate(...)` = 原 `pickBestOnlineHit`：标题相似度 <0.6 剔除；艺人已知却对不上剔除；
  时长两侧已知且差 >5 s（`kOnlineLyricsDurationToleranceMs`）剔除；得分 `标题×2 + 艺人`，同分取时长差小者；
- `lyricsNameSimilarity`（原 `onlineLyricsNameSimilarity`：相等 1 / 包含 0.85 / 二元组 Jaccard）；
- `lyricsQueries(title, artist, {max = 4})`（原 `onlineLyricsQueries`）与 `searchWithFallbackQueries` 回退循环
  （累计候选，一旦能挑出像样的就停，按 `ref|title|artist` 去重）；
- 复用本分支已有的 `lrclibTitleParts` / `lrclibStripBrackets`（`lrclib_client.dart:100,126`），不复制。

行为注记：一次解析里评分只用于「自动采用」。LRCLIB 的模糊候选仍只给用户手选（沿用现状），歌词插件的候选
**自动采用**（用户已显式启用该插件）。「手动从某插件搜歌词」入口 v1 不做（§9）。

## 5. 来源列表偏好与迁移

- 键 `music_lyrics_providers`，值 JSON 字符串：`[{"id":"moe.example.lyrics","enabled":true}, …]`，**只存插件**，
  数组顺序即优先级；LRCLIB 不在其中，读取时宿主固定在最前（所以「不可移除 / 不可重排」由结构保证，无从误写）。
- 存储：Drift `preferences` 表（`preferences_repository.dart` 新增 `musicLyricsProviders` getter/setter +
  `preference_keys.dart` 登记，使其进 `profile_settings` 每 Profile 快照；守卫 `preference_keys_guard_test`）。
- 读取时与「已装且 `usable` 且声明了 `lyricsSearch`」的插件求并：列表里有但插件已卸载 / 缺能力的项丢弃（不写回，
  避免重装前丢设置：写回时才剔除）；已装但不在列表的新插件**追加到末尾，默认启用**（用户手动装的就是要用）。
  纯 Dart 逻辑放 `fushi/lib/src/media/music/lyrics/lyrics_provider_list.dart`（`mergeLyricsProviders(stored, installed)`）。
- 总开关 `music_lyrics_online` **保留**，语义收窄为「所有在线歌词查询（LRCLIB + 插件）」的离线总闸；
  UI 文案 `music_lyrics_online_*` 相应改写，不改键。
- 迁移 `music_lyrics_unofficial_online`：**本分支无此键、无需迁移，也不引入**。若 `integ/samu-on-develop` 的
  构建被用户用过，库里会留一个孤儿偏好行——无害；且它控制的三家内置客户端不在本仓，没有可迁移到的插件。
  不写迁移代码；若所有者要求清理孤儿行，作为 §9 的开放问题。

## 6. 设置界面

「歌词」分区（`settings_schema_music.dart:360`）在 `music.lyrics_online` 之后加一项
`music.lyrics_providers`（`visible: isMusicPluginSourcesAvailable`），点进子页 `MusicLyricsProvidersBody`
（新文件 `pages/implementations/music/music_lyrics_providers.dart`，套现有 `SettingsSubPage` 写法，参照
`MusicPluginSettingsBody`）：

- 第一行固定 LRCLIB：图标 + 名称 + 「内置，始终第一」副标，无开关、无拖拽柄；
- 其后 `ReorderableListView`：每行 = 拖拽柄 + 插件名 / 版本 + `Switch`；列表错峰进场用
  `FushiEntranceScope` + `fushiStaggeredItemBuilder`，行按压用 `FushiPressScale`，时长取 `fushiMotionDuration`
  （守卫 `fushi_entrance_wiring_guard_test`）；拖拽排序同时给「上移 / 下移」菜单项（焦点 / 手柄可用）；
- 空态：说明「没有歌词插件」+ 按钮「安装插件」跳到「插件音源」分区的安装流程（复用 `music_plugin_settings.dart`
  的安装入口，不另写）；
- 「插件音源」页：`musicPluginCapabilityLabel`（`:23`）补 `lyricsSearch` / `lyricsFetch`，详情页权限 / 能力照列；
  纯歌词插件的卡片标「歌词来源」，不显示登录 / 浏览入口；
- 移动端 / 桌面都用同一页面；不新增工具栏。

## 7. iOS 与合规

- 不新增 `StoreRestrictedCapability`：歌词插件属于既有 `onlineMusicSource`（下载并执行第三方代码 + 接入未授权来源）。
- iOS：`isMusicPluginSourcesAvailable == false` → 来源列表入口不渲染、`MusicLyricsService` 的 `pluginLyrics` /
  `pluginSearch` 回调为 null，解析链只剩 LRCLIB（与现状一致）；iOS 伞形库仍不编入 JS 引擎。
- 守卫 `fushi/test/build/ios_store_compliance_guard_test.dart` 增加：新子页 / 新装配只经 `isMusicPluginSourcesAvailable`
  取，不得出现 `Platform.isIOS`。

## 8. i18n（一律 `dart run tool/i18n_sync.dart --add <key> <en> <zh>`，再 `dart run slang` + `dart format` 生成文件）

| key | en | zh |
|---|---|---|
| `music_lyrics_providers_title` | Lyrics sources | 歌词来源 |
| `music_lyrics_providers_hint` | LRCLIB is always asked first, then your plugins in this order. | 先查 LRCLIB，再按此顺序查已启用的插件。 |
| `music_lyrics_providers_builtin_note` | Built in, always first | 内置，始终第一 |
| `music_lyrics_providers_empty` | No lyrics plugins installed | 尚未安装歌词插件 |
| `music_lyrics_providers_install_action` | Install a plugin | 安装插件 |
| `music_lyrics_providers_move_up` / `_move_down` | Move up / Move down | 上移 / 下移 |
| `music_plugins_cap_lyrics_search` | Lyrics source | 歌词来源 |

`music_lyrics_online_title/_hint` 文案改写（`--rename` 不适用，键不变；用 `--add` 同名覆盖英中后其余语言保持英文待补，
或逐语言走既有翻译流程）。其余 15 种语言按 `i18n_sync` 无参补全。

## 9. 测试

- Rust `manifest.rs`：纯歌词清单通过；只声明 `lyricsSearch`（缺 `lyricsFetch`）拒装；`KNOWN_CAPABILITIES` 含新名；
  纯歌词插件无 `searchTypes` 通过。
- Dart `packages/fushi_music/test/`：fixture 插件（QuickJS 真跑）`lyricsSearch` / `lyricsFetch` 往返；DTO 清洗
  （超长 / 缺 ref / 负时长 / 超 20 条 / ref >2 KiB）；越权域名请求被拒。
- `fushi/test/media/music/lyrics/lyrics_candidate_scoring_test.dart`：把 samu 分支
  `online_lyrics_providers_test.dart` 里评分 / 查询词用例（标题阈值、艺人「A/B」、时长容差、同分取近、文件名式标题）整体搬来。
- `music_lyrics_service_test.dart`：来源顺序（LRCLIB 无 → 插件 A 报错 → 插件 B 命中）、错误不写负缓存、「没有」写负缓存
  1 天、过期重问、总闸关闭不问任何网络、iOS（回调为 null）只剩 LRCLIB、重排后缓存行不被低优先级覆盖。
- `lyrics_provider_list_test.dart`：`mergeLyricsProviders` 的并集 / 剔除 / 新装追加末尾默认启用 / 容忍坏 JSON。
- Widget：`music_lyrics_providers_test.dart`（LRCLIB 行固定且无开关、拖拽 / 上移下移改顺序并写偏好、空态）。
- 守卫：`preference_keys_guard_test`、`i18n_keys_sorted_guard_test`、`ios_store_compliance_guard_test`、
  `fushi_entrance_wiring_guard_test`。

## 10. 实施任务（按序，A/C/D 可并行，各自独立可合）

| 块 | 内容 | 文件 | 依赖 |
|---|---|---|---|
| A | Rust 能力词表 + 校验规则 + Rust 测试；同步更新 `2026-10-28-music-plugins.md` §4 能力表 | `native/fushi_music/src/plugin/manifest.rs`、`docs/specs/2026-10-28-music-plugins.md` | — |
| B | Dart 插件层：枚举加 `lyricsSearch` / `lyricsFetch`，`LyricsCandidate` DTO（含清洗），`MusicPluginSource.searchLyrics` / `fetchLyrics`；纯歌词插件在浏览入口过滤；测试 | `packages/fushi_music/lib/src/plugin/{plugin_models,plugin_source}.dart`、`fushi_music.dart` 导出、`packages/fushi_music/test/**`、浏览入口（grep `MusicPluginManager.list()` 的使用点） | A |
| C | 评分 / 查询词纯函数抽取 + 测试 | 新 `fushi/lib/src/media/music/lyrics/lyrics_candidate_scoring.dart`、新测试 | — |
| D | 来源列表偏好 + 合并逻辑 + 测试 | `preferences_repository.dart`、`preference_keys.dart`、新 `lyrics_provider_list.dart`、新测试 | — |
| E | 解析链改造：`MusicLyricsService` 新增 `pluginSearch` / `providers` 注入，按 §3 顺序走；`app_model.dart` 装配（iOS 为 null）；服务测试 | `music_lyrics_service.dart`、`music_lyrics_sources.dart`（如需）、`app_model.dart`、`music_lyrics_service_test.dart` | B C D |
| F | 设置 UI + i18n：子页、设置 schema 项、能力标签、17 份 json + 生成文件；Widget 测试 + 守卫 | `settings_schema_music.dart`、新 `music_lyrics_providers.dart`、`music_plugin_settings.dart`、`fushi/lib/i18n/*.i18n.json`、`strings.g.dart` | D（E 可后合） |
| G | 收尾：本 spec 状态改「已实现」；`ios_store_compliance_guard_test` 补断言；BUGS / 变更记录 | `docs/specs/2026-10-30-lyrics-plugins.md`、守卫测试 | E F |

## 11. 开放问题

1. `fetch` 返回形状：用 `{original, translation?}`（复用 `LyricText`）还是所有者口述的 `{raw, format, translation?}`？本文取前者；改后者只多一层适配。
2. `music_lyrics_online` 是否保留为离线总闸（本文：保留）？还是 LRCLIB 也彻底不可关？
3. 新装插件追加末尾且默认启用，是否可接受（本文：是）？
4. 是否需要「手动从某个歌词插件搜索并选一条」（歌词页换源）？v1 不做；候选 DTO 已够用。
5. 孤儿偏好 `music_lyrics_unofficial_online`（来自 integ 分支构建）要不要在 settle 时清理？
6. 多个歌词插件结果不同时，是否要「并行问、取评分最高」而非「按序第一个命中」？本文取按序（可预期、省请求）。
7. 独立插件仓库的目录 / 签名工具 / 样例插件是否由本仓提供模板（目前 §6 待决「官方插件仓库」同一问题）。
