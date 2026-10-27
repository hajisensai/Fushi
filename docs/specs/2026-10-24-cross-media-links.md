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

## L2 落地记录（2026-10-24）

- **声纹**：`native/fushi_music/src/fingerprint.rs`（rusty-chromaprint `preset_test2` + 自写滑窗
  对齐），Dart 绑定 `packages/fushi_music/lib/src/audio_fingerprint.dart`。解码走统一 FFmpeg 后端
  （BD `.mpls` / DVD title 由 `resolveFfmpegBackend` 透明处理），一集一次 `compute`、一对一次
  `align`，都在后台 isolate。
- **缓存**：新表 `video_theme_song_spans`（**schema v131**），键 `(book_uid, episode_index,
  track_uid)`，失效判据 = 文件大小 / 修改时刻 / 声纹算法版本；没出现也落一行。没复用既有结构的
  理由写在 `theme_song_span_tables.dart` 头注释（容器章节不持久化、`video_metadata_episodes` 是刮削
  骨架、`video_file_specs` 一行一文件）。设备本地、无外键（覆盖恢复按 `INSERT … SELECT *` 回灌），
  删视频由 `deleteVideoBooks` 同事务清。
- **何时识别**：建主题曲连接后台跑这首歌的全部集；曲目详情「识别出现位置」；视频页打开某集时只识别
  这一集（不在播放时扫整部作品——BD 一集解码要读整个 7 GB 文件，和正在播放的读盘抢带宽）。只认
  已确认的连接；建议态不改播放行为。
- **角色**：连接编辑器的主题曲分支可选 OP / ED / 插入曲与适用集数（`1-12`、`1,3,5-7`）；没写角色
  的旧连接 / 推断连接按位置推断（前半 OP、后半 ED）。插入曲不自动跳。
- **播放**：可选自动跳过（默认关，落点 = 段尾前 0.5 s，只在刚进段 3 s 内触发一次，拖回段中不再
  弹走），段首段尾画进进度条章节刻度层。**画面上不出任何提示**：原有的「跳过片头 / 片尾」按钮与
  OP / ED 期间左上角「♪ 曲名 · 在音乐库打开」角标按用户决定删除（BUG-3801，同 BUG-3218），
  守卫 `fushi/test/pages/video_skip_chapter_removed_guard_test.dart`。
- **音乐侧**：曲目详情页（曲目列表行尾「详情」/ 长按）列「出现在：第 1–12 集 OP」，点集号从那一集
  的 OP 起点播；页内带「同一作品」区块（主题曲连接在这里建）。
- **MV 偏移**：`ThemeSongDetector.mvOffset`（同一对齐，返回 MV 相对音频的偏移），UI 留给 P4。
- **实测**（本机《魔女之旅》BD Vol.1）：NCOP（00007.m2ts）对 4 集正片：第 1 集无 OP（与片源一致），
  其余三集置信度 0.97 / 0.97 / 0.98；从第 2 集截 60 s 音轨当「歌曲」对整集比对，起点误差 95 ms。
  一集解码 ~20 s（读整盘文件），声纹 ~250 ms，对齐 ~30 ms。
- **偏离**：手动连接的音乐端只开放「曲目」（OP / ED 是单曲；编辑器分段按钮放不下第六段）；专辑端点
  照常解析（同步 / 推断带来的专辑连接展开成该专辑 ≤ 8 分钟的曲目，每集取置信度最高的一首）。

## L4 落地记录（2026-10-24）

- **Rust 胖核心** `native/fushi_corpus/`（C ABI 前缀 `fcorp_`，Dart 绑定 `packages/fushi_corpus`）：
  切句（`fcorp_split`，Unicode 各文字句末标点一张表，不分语言）、写入 / 替换 / 删除文档、
  一次查询返回分组 top-N（句长惩罚 → 文档新旧 → 库内先后；每模块 / 每文档条数上限、原文去重）、
  读回原文（`fcorp_export`）。句柄带读写锁，可跨 isolate 共用：后台写入时 UI 照常查。
- **归一 = 词典形**：fushidicts 新导出 `fushidicts_corpus_terms`（一批句子一次 FFI），每个命中位置
  给出首条结果的 `term.expression`——就是查词弹窗词头显示的那个写法；词形还原 / 文本变体都在
  `Lookup` 里按已装载的词典与变形表生效，**不分语言**（没词典的语言一个词元都不出，有变形表的
  18 种自动带还原）。未命中的拉丁等空格分词字母整串跳过，不从词中间起查。弹窗按词头查询。
  词元线格式原样从 fushidicts 交给 Rust，Dart 不解码。
- **书的定位**：句子起止换算成章内学习单位前缀（fushi_compute 新导出
  `ffc_parse_study_char_prefixes`，一章一次 FFI），与阅读器 `charAnchor` 同一把尺子；跳回走收藏句
  同款 `Bookmark(charAnchor, charAnchorLength, preserveSavedPosition)`。
- **索引不进 Drift**：`<数据根>/corpus/` 一文档一文件（格式见 `src/corpus.rs` 头注释），
  打开时载入倒排、句子原文按偏移回读。理由：索引是派生数据，不该进备份 / 同步，也不该和 UI 写事务
  抢 SQLite 写锁（首次建索引要写上百万句）；状态归 Rust。
- **游戏台词进 DB 与备份（v134，所有者 2026-10-24 拍板）**：文本钩子历史只在会话内存里，台词的
  持久副本是新表 `galgame_text_lines`（`(game_id, text)` 唯一、外键 cascade 跟游戏走），语料库的
  游戏文档从它派生（按本机 id 每 500 行一块，新台词只让最后一块变化），与书 / 字幕 / 歌词一样可
  整库重建。选 DB 而不是把语料文件打进备份：备份的类别裁剪与合并导入的游戏身份重映射（同 id /
  同刮削 id / 同 exe 路径）都只作用于 DB 表，语料文件是按词典归一过的派生格式，不适合当交换格式。
  - 备份：随 `games` 类别出境（按游戏选择裁剪时经外键 cascade 跟着走）；覆盖恢复整库落地，语料
    目录不进包（坏了 / 缺了都不影响备份），恢复后启动对账从表重建索引。
  - 合并导入：经 `_buildGameIdMap` 重映射到本机同一部游戏，按 `(游戏, 台词)` 去重（同一份包合并
    两次不重复，本机已有行保留自己的 `received_at`）。
  - **互联同步不带**：同步走聚合数据（进度 / 统计 / 合集），台词是整部游戏的原文流水（量大、商业
    剧本文本），文本钩子又只在 Windows 上，换设备由备份承担；需要时再单独加，不放进默认同步面。
  - L4 首版直接存在语料文档里的台词（指纹无 `db:` 前缀），首次对账时读回写进表再换成派生文档。
- **增量**：书 / 音乐 / 游戏删除按来源表变化（drift `tableUpdates`）去抖对账，覆盖导入、同步、
  备份合并等所有入库路径；视频在播放页每次换上字幕时喂这一集（`VideoPlayerController.onCuesReplaced`，
  覆盖不落库的播放列表各集），对账补上已落库 cue 的单视频；游戏台词在 `_recordActivity` 攒批、
  去抖 / 停止捕获 / 退出时落盘。首次建索引逐份提交，中途退出下次接着做；词典集合变了（签名 =
  释义词典路径 + 目录修改时刻）就从语料库读回原文重新分词。启动 20 s 后才开始，全部在后台 isolate。
- **弹窗**：`popup.js` 一份实现，app 内 WebView 弹窗（阅读器 / 视频 / 查词页 / 悬浮词典…）与
  Windows / macOS app 外查词窗都接了两根 deferred 桥（`librarySentences` / `librarySentenceOpen`），
  点击经根状态的 `WidgetRef` 回到出处（L3 的出口）。**浏览器扩展不支持**：扩展的 shim 对未知桥回
  null，区块不出现（索引只在 app 本机，扩展端要另开服务端 API，未做）。Flutter 原生弹窗
  `DictionaryPopupNative`（只有悬浮词典窗用）没有加。设置 → 查词 →「我库里的例句」：开关（默认开）
  与「重建例句索引」（带进度 / 规模状态行；四类来源全部从各自的真相源重建）。
- **限制**：用户查的是复合词的一部分、而分词把整串切成了更长的词元时，查不到（索引键是分词得到的
  最长匹配词元）；游戏出处只能打开游戏详情（与 L3 同）。

## L5 落地记录（2026-10-24）

- **schema v135**（三张表，`people_tables.dart`）：`game_voice_casts`（游戏 VNDB 配音表缓存，设备本地、
  无外键，删游戏同事务清）、`person_identity_bridges`（人物身份桥：`wikidata` 桥接缓存——自环行 =「查过」
  标记，30 天过期重查；`manual` = 用户确认 / 否决「同一人」，`deleted_at` 墓碑）、
  `adaptation_progress_anchors`（动画集 ↔ 原作卷 / 章手动对应点）。后两张按类别随备份，不进合并导入、
  不进互联同步。
- **同一人判据**：`fushi_engine/media/people/person_identity.dart` 的并查集，节点是 `id:<scheme>:<值>`
  （AniDB creator / MAL people / TMDB person / VNDB staff / MusicBrainz artist / Wikidata QID）与
  `ref:<域>:<键>`。只有共享外部 id、Wikidata 桥、用户手动确认会合并；**名字相同（全半角 / 空白 / 罗马字
  段序归一）只出「可能是同一人」建议**，否决过的一对不再建议（外部 id 合并不受名字否决影响）。
- **桥的来源**：VNDB `va.staff.extlinks` 直接给出声优的 `anidb` / `wikidata` / `musicbrainz_artist`
  （2026-10-24 实测 `v17`），是三域合并的主桥；视频 / 音乐侧只有单一 id 时，人物页打开时对未查过的 id 跑
  一次 Wikidata SPARQL（属性 P5649 / P4084 / P4985 / P434 / P3180，`wbgetentities` 实测核对），结果落库。
- **游戏配音数据**：此前游戏侧没有任何配音数据。游戏详情页打开时，已绑定 VNDB id 的游戏后台取一次
  `POST /kana/vn` 的 `va`（缓存 30 天；换绑 VN 重取；失败只记诊断不写缓存）。角色图 `sexual` 均值 > 0.5 不保留。
- **音乐**：只读 `music_track_credits`（`vocal_cv` = CV 演唱、`character` = 角色名义）+ `music_artists.mb_artist_id`；
  音乐刮削尚未写入这类署名时人物页「演唱与角色歌」显示空态，曲目详情「署名」不渲染。
- **入口**：视频合集 / 单文件作品的人物轨道（`VideoCreditRail`，点头像）、游戏详情「配音」、曲目详情「署名」
  → `PersonDetailPage`；页内卡片经 `openMediaLinkEntry` 进各模块条目。
- **动画 ↔ 原作进度（§6）**：只做手动对应点 + 展示（「同一作品」区块下，已确认的书 → 视频改编连接一张卡：
  「看到第 N 集 ≈ 原作第 M 卷」，取集号 ≤ N 的最后一个对应点、不插值）。文本相似度推断依赖 L4
  `fushi_corpus`，**未做**：`AdaptationProgressInferrer` 只有接口，`kAdaptationProgressInferrer` 恒为 null。
- **偏离**：人物图在 Dart 里建（IO / 编排层的小图，几万节点并查集线性时间，不是 CPU 热点）。

## 决策

- **D-L1**：不用 Bangumi（2026-10-24 拍板）；自动判断支持 AI 辅助（见上）。
- **D-L2**：「我库里的例句」默认开（全在本机，不上传；所有者未反对）。
