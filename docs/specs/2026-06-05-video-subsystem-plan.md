# 视频子系统计划（底栏入口 + 自动播放列表 + 自动字幕 + mpv 着色器）

> 起于 2026-06-05 用户/团队（shishamo / 哈吉千歳）需求：把视频做成一等媒体类型。
> 现状：视频播放/查词/制卡（`VideoHibikiPage`）+ 多集播放列表数据结构（`VideoBooks` 表 +
> `playlistJson` + `currentEpisode` + 每集独立进度）已落地；导入入口被编译期常量
> `kVideoImportEnabled=false` 关着；书架页已有视频分区。本计划在此地基上扩展。

## 需求拆解（原话）

1. 视频单独一个底栏按钮，放在「书架」和「词典管理」中间，只有在设置开启「实验性功能」才显示。
2. 识别视频名 → 自动做成播放列表（参照 Jellyfin 按文件名合并同番）。
3. 参照 asbplayer 取 jimaku 字幕 → 自动获取字幕。
4. 支持导入 mpv 的着色器（Anime4K 等）。

## 设计约束（来自 CLAUDE.md）

- 根因修复、不破坏现有功能（底栏现有 3 tab、书架视频分区、播放页全链路）。
- 消除特殊情况优先：底栏「写死索引 0/1/2」必须先重构成逻辑枚举，否则插条件 tab 会炸
  `_currentTab==2` / `case 1/2` / `%3`。
- i18n 必须走 `tool/i18n_sync.dart` + `dart run slang`，禁手改 17 文件。
- 播放/着色器/字幕这类「设备相关」功能：声明修好前需真机复测（device 验证待用户）。

---

## Phase A — 底栏视频 tab + 视频库页 + 实验开关（容器，其它 Phase 的地基）

**数据结构改动（核心）**：`home_page.dart` 把 `int _currentTab` 改成
`enum HomeTab { books, video, dictionaries, settings }`，消除所有写死索引：

- `_activeTabs()` = `[books, if(experimentalVideo) video, dictionaries, settings]`。
- 底栏/侧栏渲染的位置索引 ↔ `HomeTab` 双向映射（位置只在渲染层存在）。
- `buildBody()` / `_selectTab` / 快捷键（homeTabBooks/Dict/Settings、next/prev、focusSearch）
  全部按枚举身份而非位置。
- 守卫：实验开关关闭时若 `_currentTab==video`，build 时回落 `books`（不破坏）。
- 「六个塞不下吗」：MD3 底栏建议 3–5；现 3→4 没问题，未来超 5 需溢出/侧栏分流（记风险）。

**实验开关**：
- 偏好 `experimental_video_enabled`（`preferences_repository.dart` get + set(bool) + notify）。
- `AppModel.experimentalVideoEnabled` / `setExperimentalVideoEnabled`。
- 设置 schema 在 `_systemDestination` 新增「实验性功能」section + `SettingsSwitchItem`。
- 开关 ON 同时放出视频导入入口：书架的 `if (kVideoImportEnabled)` 改为
  `if (kVideoImportEnabled || appModel.experimentalVideoEnabled)`，视频页导入按钮同门控。

**视频库页** `home_video_page.dart`：列 `VideoBookRepository.listAll()` 的卡片
（复刻书架 `HibikiCard` + 封面 + 标题），tap → `VideoHibikiPage`，AppBar 导入按钮 →
`VideoImportDialog` → 刷新。书架视频分区暂保留（不破坏；去重留作 A 的后续）。

**i18n**：`nav_video` / `section_experimental` / `experimental_video` /
`experimental_video_hint` / `video_library_empty`。

**测试**：tab 枚举映射（开/关视频时位置↔身份、next/prev 环、settings 回退来源）、
设置开关写穿 DB、视频页空态/列表渲染、导入门控源码守卫。

---

## Phase B — 识别视频名 + 文件夹扫描自动分组成播放列表（纯 Dart，可单测）

- 新增 `video_filename_parser.dart`：从文件名抽 `{series, season, episode}`，参考 anitomy
  规则的轻量实现（剥 `[字幕组]` / `(...)` / 分辨率/编码 token，找集号 `\b\d{1,4}\b` /
  `EP?(\d+)` / `第(\d+)话`，季 `S(\d+)` / `Season`）。纯函数，重单测覆盖各种命名。
- 导入对话框新增「导入文件夹」：扫目录视频文件 → 按解析出的 series 分组 → 每组排序集号 →
  写成现成 `playlistJson`（一个 series = 一个 `VideoBook` 多集），单文件回退单集。
- 决策默认：选文件夹自动扫描分组（Jellyfin 式）；解析不确定时 series 回退文件名主干。
- 不动 DB schema（复用 playlist），不破坏现有单文件/m3u8 导入。

---

## Phase C — 导入 mpv 着色器（Anime4K 等；先桌面）

- media_kit 底层是 libmpv；经 `(player.platform as NativePlayer).setProperty('glsl-shaders', <路径>)`
  设着色器（多个用平台分隔符拼接）。
- 新增着色器管理：用户把 `.glsl` 导入固定目录（`<appDir>/shaders/`），播放页设置面板列出 +
  开关启用/清空，选择持久化（可挂 `VideoBooks` 或全局偏好，倾向全局偏好 + 每书覆写后续）。
- 平台：先桌面（libmpv 成熟）；移动端 GPU 着色器性能/兼容实测后再放（门控）。
- **device 验证待用户**：着色器实际生效需真机/真显卡跑 libmpv 观察画面。

---

## Phase D — 自动获取字幕（参照 asbplayer 取 Jimaku；链路最长，放最后）

- 链路：视频文件名 → AniList GraphQL 搜番拿 anilist id → Jimaku API（`/search?anilist_id=` +
  `/files`）列日语字幕 → 下载 `.srt/.ass` → 写入 sidecar + 挂 `VideoBook` 字幕源 + 解析 cue。
- **硬依赖**：Jimaku 需 API key（用户在设置填）；匹配不准时提供手动选 AniList 条目。
- 新增 `jimaku_client.dart`（API key + 搜索 + 下载，可 mock 单测）+ 设置项（API key 输入）+
  播放页/导入流「自动获取字幕」动作。
- **network/API-key 验证待用户**：真实拉取需有效 key + 联网。

---

## 分期顺序与可发性

A → B → C → D，各 Phase 独立可发、互不阻塞；A 是其余三个的容器，先落。
C/D 含外部依赖（显卡 / Jimaku key），代码可写但「生效」需 device/网络验证（按 CLAUDE.md 标注待用户）。
