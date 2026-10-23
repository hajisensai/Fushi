# 跨模块联动（作品图谱）

状态：方案稿（2026-10-24），由音乐 ↔ 视频联动引出，所有者要求「其他地方也互相联动」。

## 现状（2026-10-24 实测代码）

各模块已经各自存了外部作品身份，但**互相不知道对方**：

| 模块 | 已有身份 | 位置 |
|---|---|---|
| 视频 | AniDB / MAL / TMDB（作品、季、集、人物、角色） | `VideoMetadataProviderIdentities`、`AnidbFileIdentities`、`MediaCollections.anilistId/organizeKey` |
| 书（含漫画） | ISBN；Bangumi / DLsite 刮削候选 | `EpubBooks.isbn`、`book_metadata_scraper.dart` |
| 游戏 | VNDB（`v12345`）/ Bangumi | `GalgameSources(gameId, source, externalId)` |
| 音乐（新） | MusicBrainz / AcoustID / VGMdb | 音乐方案 §10 |

已有的「跨」只有两处：`MediaCollectionItems` 允许一个合集里混放书 / 视频 / 游戏
（手动）；`CollectionRelations` 只连视频合集之间（前传 / 续集…）。制卡记录
`MinedSentences.source` 只有 `book | video | audiobook | lyrics`，没有游戏 / 漫画，
且视频来源把 `normCharOffset` / `normCharLength` 复用成毫秒（语义随 `source` 变）。

## 核心：一张作品图谱

不另起一套「作品」实体去取代各模块的数据，而是加一层**连接**：

- `media_links`：`(from_kind, from_key) —relation→ (to_kind, to_key)`
  - kind：`video_collection` / `video_episode` / `book` / `game` / `music_album` /
    `music_track` / `audiobook`
  - relation：`adaptation`（改编，带方向：原作 → 改编）/ `theme_song`（OP / ED /
    插入曲 / 主题曲，带 `role` 与适用集数范围）/ `soundtrack` / `same_work` /
    `cast`（声优 / 角色）
  - `source`：`manual` / 推断来源名；`confidence`；`is_user_confirmed`；`deleted_at`
  - 手动连接永远优先；推断结果低于阈值只作「可能相关」建议，不自动显示成事实。
- 本地条目的身份统一用各模块现有的稳定 key（书 bookKey、视频 bookUid / collectionId、
  游戏经 `GameIdentityIndex` 换算后的跨端身份、音乐 track_uid），所以连接能随同步走。
- 推断只用**各模块已在用的身份**，不为联动新增元数据主源：
  - 动画 ↔ 视觉小说：VNDB 的 VN 条目自带关联动画的 AniDB id（游戏已有 VNDB id，
    视频已有 AniDB id）——强判据。
  - 动画 / 游戏 ↔ 专辑：VGMdb 的 album「product」关系 + MusicBrainz 关系；
    以及音乐方案里的声纹比对（见下 2）——强判据。
  - 动画 ↔ 原作轻小说 / 漫画：MAL（Jikan）的 adaptation 关系给出原作，再按 ISBN /
    标题匹配本地书——中等判据，需用户确认。
  - **联动一律不用 Bangumi**（所有者 2026-10-24 拍板，书 / 游戏 / 动画都不用）：
    书 / 游戏侧已存的 Bangumi id 不参与推断。

### AI 辅助判断（所有者 2026-10-24 要求）

确定性判据（共享外部 id、声纹）之外，用 AI 补「标题对不上」的那部分：

- **何时用**：两个条目没有共享 id、但标题 / 罗马字 / 译名 / 系列名疑似同一作品；
  或 MAL 给出了原作、本地书却只能靠标题模糊匹配；或 VGMdb / MusicBrainz 关系里的
  曲名与本地曲目写法不同（假名 / 汉字 / 英译）。
- **怎么用**：先用确定性规则把候选缩到少数几个，再把**候选 + 证据**（标题各写法、
  年份、话数 / 卷数、制作公司、作者、曲目时长、已知 id）交给 AI 做裁决，要求输出
  结构化结果（关系类型、方向、置信度、理由），不让 AI 自由检索或编造 id。
- **落地**：走现有 AI 装配（`packages/fushi_engine/lib/ai/`，与
  `ai_collection_order_assistant.dart` 同一套 provider 配置与代理），未配置 AI 时
  整段跳过，只剩确定性推断。
- **展示**：AI 结论写成 `source=ai` 的连接，**一律作为建议**，用户确认后才显示成
  事实；理由文本保存在连接上，建议卡片里能看到「为什么认为是同一作品」。
  同时有确定性 id 佐证且 AI 给出高置信时，可以按设置自动确认（默认关）。
- 同一对条目被用户否决后记墓碑，AI 不再重复提议。

## 联动清单（按价值排序）

### 1. 详情页「同一作品」区块（所有模块）

动画合集页、书详情、游戏详情、专辑页都加一条横向区块：原作 / 改编 / 游戏 /
OST·OP·ED / 声优，点了直接跳到对应模块的条目；本地没有的显示为「未入库」灰卡，
可一键去搜（走各模块已有的发现 / 下载入口，iOS 按 `StoreRestrictedCapability`）。
设计稿：`CrossMedia.dc.html`。

### 2. 视频 ↔ 音乐：OP / ED 自动识别

- 音乐库里有某作品的 OP / ED 时，用声纹（音乐模块 Rust 的 chromaprint）在该作品
  每集音轨上滑窗比对，得到每集 OP / ED 的精确起止 → 写成章节标记。
- 播放时：「跳过片头 / 片尾」按钮（现在仓库里没有任何片头检测）；OP 期间角落
  显示「♪ 夜明けの窓 · 在音乐库打开」；可选叠加该歌的逐字 / 卡拉 OK 字幕。
- 音乐侧：曲目详情列出「出现在：第 1–12 集 OP」，点击跳到那一集的 OP 起点。
- 比对是计算型工作，进 Rust；一集一次粗粒度调用，结果按集缓存。

### 3. 查词弹窗「我库里的例句」

- 词典弹窗多一个区块：这个词在**你自己的**书、字幕、歌词、游戏文本里出现过的
  句子，按模块分组，点击跳回原处（书 → 字符偏移，视频 / 音乐 → 时间点，
  游戏 → 文本钩子历史）。
- 实现：新的 Rust 胖核心 `fushi_corpus`（倒排索引，按词典的词形还原归一，
  支持语言按现有三档能力自动生效，**不假设日语**）；各模块入库 / 字幕加载 /
  歌词解析 / 游戏文本落盘时增量喂进去，查询一次 FFI 返回 top-N 句。
- 现在仓库里没有这个功能（`example_sentences_dialog_page.dart` 的例句来源与用户库
  无关）。

### 4. 卡片「回到出处」

- 复习卡片时显示出处（书名 / 第几集 / 哪首歌 / 哪个游戏），一键回到原位置并播放
  原音频片段。
- 数据层：`SentenceSourceKind` / `MinedSentences.source` 补 `game` / `manga` /
  `music`；把视频复用 `normCharOffset` 当毫秒的做法拆成显式的 `position_ms` /
  `duration_ms` 列（迁移旧行：`source=video` 的值搬过去），不再一列两义。

### 5. 声优 / 角色聚合页

视频已有 `VideoMetadataPeople` / `VideoMetadataCharacters`；游戏的 VNDB 数据里有
配音；音乐有 MusicBrainz 的 `vocal` 关系与角色歌 credit。聚合成一个人物页：
TA 配音的动画角色、游戏角色、唱过的角色歌，全部可点进各模块。

### 6. 动画进度 ↔ 原作进度（低优先，需验证数据源）

「动画看到第 N 集 ≈ 原作第 M 卷」需要集 ↔ 卷映射，现有 provider 都不直接给。
先只做手动映射 + 从字幕与书的文本相似度推断（可复用 `fushi_corpus`），推断不准就
不展示。

## 分期

| 期 | 内容 |
|---|---|
| L0 | `media_links` 表 + 手动连接 UI + 详情页「同一作品」区块（只显示手动连接） |
| L1 | 推断：VNDB↔AniDB、VGMdb / MusicBrainz、MAL 原作 + AI 辅助裁决；建议 → 用户确认 |
| L2 | OP / ED 声纹识别 + 跳过片头 + 音乐联动（依赖音乐模块 P0 的 chromaprint） |
| L3 | 卡片回到出处（含 `MinedSentences` 列拆分迁移） |
| L4 | `fushi_corpus` + 查词弹窗「我库里的例句」 |
| L5 | 声优聚合页；动画 ↔ 原作进度（视 L4 效果决定） |

## 决策

- **D-L1**：不用 Bangumi（2026-10-24 拍板）；自动判断支持 AI 辅助（见上）。
- **D-L2**：「我库里的例句」默认开（全在本机，不上传；所有者未反对）。
