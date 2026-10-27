[根目录](../../CLAUDE.md) > [packages](../) > **fushi_core**

# fushi_core

## 模块职责

共享核心模块：定义 Drift SQLite 数据库 schema（当前 schemaVersion=136；以 `database.dart` 的 `schemaVersion` getter 与 `@DriftDatabase(tables: [...])` 注册清单为准，本文数字仅作快照。v82：ReaderPositions/Bookmarks/BookCustomCss/RevealedImages 书键从 bookKey 切稳定 uid；v90：网页播放器自动制卡队列 `web_mine_queue`；v114：收藏词上下文；v115：排行榜 isbn / completedAt；v116：设备端待发制卡队列 `pending_mine_queue`；v117：Fushi SRS——`profiles.uid` 全局身份 + 八张 `srs_*` 表；v118：`epub_books` / `srt_books` / `video_books` 加 `localAddedAt`——本机开始拥有的时刻，与原始入库时刻 `importedAt` 拆开，删除墓碑仲裁与首页「最近添加」读它，设备本地不进 wire；v119：`video_metadata_characters.originalName`（角色日文原名）+ 视频字幕 AI 校对作品级专名表 `video_subtitle_glossaries`；v120：`srs_field_edits` 加卡片前身链接的部分覆盖索引 `idx_srs_field_edits_history_from`——缓存刷新找后继卡不再全表扫描修改记录表，BUG-3543；v121：`srs_sent_batches`——SRS 多目录同步的本机已冻结批次留存（设备本地，不进备份、恢复后清空）；v122：作品级「私密」标记表 `media_privacy_flags`——不上传排行榜、不推 Bangumi，键与 `tag_assignments` 同一套 `(mediaKind, entryKey)`，两只 LWW 时钟搭互联标签清单的 `privacy` 字段跨端同步；v123：`srs_cards_cache.new_position`——新卡出卡位置（卡片修改记录 `newPos` 的生效值，「按词频重排新卡」写它；NULL = 没排过，按笔记创建时刻出卡）；v124：AI 整理库——`media_collections.origin` / `organize_key` / `organize_aliases`（合集由谁建归谁管 + 跨端分组身份）、`collection_member_tombstones.organize_key` / `organize_merged`（删除哨兵上的分组键与「被并掉 vs 用户删」）、设备本地整理记录 `library_organize_runs` / `library_organize_changes`，设计见 `docs/specs/2026-10-20-ai-library-organize-design.md`；v125：SRS 写入路径读放大的三条索引——`idx_srs_field_edits_profile_register`（同步冲突角标按 profile 分组只扫索引）、`idx_srs_notes_cache_type`（笔记类型成员查找）、`idx_srs_notes_cache_pending`（待裁决笔记部分索引）；v126：`collection_member_tombstones.published_at`——墓碑知识进入本库的时刻，本机作互联 host 时作合集清单的 publishedAt / deletedPublishedAt 输出，NULL = 本机用户亲手移出或存量行）；v127：`bookmarks.char_offset`（书签页首字符章内精确偏移，存量 -1）+ `bookmarks.chapter_key`（在线漫画书签所在章的稳定键，存量 NULL）；v128：内置浏览器五张新表 `web_browser_history` / `web_browser_bookmarks`（含文件夹）/ 标签页会话 / 最近关闭 / 下载记录——历史与书签随备份、经聚合快照跨端同步，其余设备本地；v129：跨模块作品图谱 `media_links`（手动连接 + 推断建议 + 否决墓碑，随互联同步与备份走，设计见 `docs/specs/2026-10-24-cross-media-links.md`）；v130：音乐模块 P0 十张 `music_*` 表（曲目 / 专辑 / 艺人 / 署名 / 歌词缓存 / MV 绑定 / 光盘来源 / 歌单 / 歌单条目 / 播放流，定义在 `music_tables.dart`，P0 整组设备本地），设计见 `docs/specs/2026-10-23-music-module-design.md` §10；v131：OP / ED 声纹比对按集缓存 `video_theme_song_spans`（`theme_song_span_tables.dart`，设备本地纯缓存）；v132：`mined_sentences` 加显式定位列 `position_ms` / `duration_ms` / `page_index`，视频来源旧值从 `norm_char_offset` / `norm_char_length` 搬入新列并清空旧列；v133：音乐 P4 刮削三表 `music_scrape_meta` / `music_metadata_raw_snapshots` / `music_locked_fields`（`music_scrape_tables.dart`，设备本地；识别身份经 `writeMusicScanBatch` 同一事务重放到曲库目录，显示列仍以文件标签为准）；v134：游戏台词 `galgame_text_lines`（`galgame_text_line_tables.dart`，文本钩子台词唯一的持久副本，「我库里的例句」的游戏来源；`(game_id, text)` 唯一、外键 cascade；随备份 games 类别走，合并按游戏身份重映射去重，不进互联同步）；v135：作品图谱 L5 三表 `game_voice_casts` / `person_identity_bridges` / `adaptation_progress_anchors`（`people_tables.dart`）；v136：AI 助手设备本地两表 `ai_agent_sessions`（对话存档，本机保留 30 天）/ `ai_agent_actions`（操作记录与撤销载荷，`session_id` 不挂外键），不同步、不进备份、不分 Profile，设计见 `docs/specs/2026-10-26-ai-operations-agent-design.md` §5.3。v129–v135 在音乐 / 作品图谱分支上原用 v125–v131，合入时整体后移；两条阶梯争用的 user_version 125–131 一律按 `from < 132` 补跑两侧全部幂等产物（develop 的 v125–v128 与分支的 media_links / 音乐表 / 主题曲区间））、表迁移逻辑、偏好键值编解码器（PrefCodec）、语言配置模型和文本选区模型。是所有其他 packages 的基础依赖。

## 入口与启动

- 库入口：`lib/fushi_core.dart`
- 数据库在 `lib/src/database/database.dart` 中通过 `FushiDatabase(dbDirectory)` 构造，内部使用 `NativeDatabase.createInBackground()` 在后台线程打开 `fushi.db`。
- PRAGMA 配置：`journal_mode=WAL`，`foreign_keys=ON`。

## 对外接口

- `FushiDatabase` -- 全部数据访问层，提供 media items / anki mappings / search history / audiobooks / audio cues / srt books / reader positions / bookmarks / reading statistics / preferences / dictionary metadata / epub books / book tags / profiles 等完整 CRUD API。
- `PrefCodec` -- 偏好值的 `encode<T>` / `decode<T>` 泛型编解码。
- `FushiTextSelection` -- 跨模块共享的文本选区数据模型。

## 关键依赖与配置

- `drift: ">=2.33.0 <2.34.0"` + `sqlite3` -- ORM 与 SQLite 绑定。**本包零 Flutter**（pubspec 不声明 `sdk: flutter`，包测试用 `package:test`）；SQLite 原生库由 `sqlite3` 3.x 的 build hook 作为 native asset 提供：app 随 `flutter build` 打包，服务端走 `dart build cli`；不要加 `sqlite3_flutter_libs`（只配 2.x，会多塞一份 SQLite）。
- `path: ^1.8.2` -- 路径处理。
- 代码生成：`drift_dev: ^2.23.0` + `build_runner`，生成 `database.g.dart`。

## 数据模型

100 张 Drift 表（按功能分组，以 `database.dart` 的 `@DriftDatabase(tables: [...])` 注册清单为准）：

| 分组 | 表名 |
|------|------|
| 媒体 | `MediaOpenHistory`（v78 最近打开流，取代 jidoujisho 血统的 `MediaItems`） |
| 来源库 | `MediaSources` |
| Anki | `AnkiMappings` |
| 搜索 | `SearchHistoryItems` |
| 有声书 | `Audiobooks`, `AudioCues`, `SrtBooks` |
| 阅读位置 | `ReaderPositions`, `Bookmarks` |
| 阅读器渲染 | `BookCustomCss`, `RevealedImages` |
| 统计 | `ReadingStatistics`, `ReadingHourlyLogs` |
| 偏好 | `Preferences` |
| 剪贴板/活动 | `ClipboardHistory`, `ActivityEvents` |
| 词典 | `DictionaryMetadata`, `DictionaryHistory` |
| EPUB | `EpubBooks` |
| 标签 | `BookTags`, `TagAssignments`（v77 五张映射表合一，宿主逻辑外键）, `MediaPrivacyFlags`（v122 作品私密标记，同一套宿主键） |
| Profile | `Profiles`, `ProfileSettings`, `MediaTypeProfiles`, `BookProfiles` |
| 同步基线 | `SyncBaselines` |
| 视频 | `VideoBooks`, `VideoWatchStatistics`, `VideoHourlyLogs`, `VideoSubtitleGlossaries`（v119 字幕 AI 校对专名表，随备份「视频」类别，不进合并导入） |
| 收藏/制卡 | `FavoriteWords`, `MiningStatistics`, `MinedSentences`, `LookupMiningCounters`, `WebMineQueue`, `PendingMineQueue`（后两张设备本地） |
| 合集/系列 | `MediaCollections`, `MediaCollectionItems`, `CollectionBookAliases`, `Series`, `ShelfEntries` |
| 互联 | `FushiPairedPeers` |
| 游戏库 | `Galgames`, `GalgameSources`, `GalgameSessions` |
| 删除墓碑 | `BookTombstones`, `StatisticsTombstones`, `CollectionMemberTombstones`, `BookTagMembershipTombstones`, `SyncDeletionTombstones` |
| SRS（v117） | 同步事件本体 `SrsEntities`, `SrsFieldEdits`, `SrsReviewLogs`, `SrsUnknownEvents`（随备份走，合并导入走 SRS 专用步骤）；本机状态 / 可重建缓存 `SrsEventLocal`, `SrsLocalState`, `SrsNotesCache`, `SrsCardsCache`, `SrsSentBatches`（v121，设备本地，不进备份、恢复后清空）。身份是 `profiles.uid` |

新增表（相对旧文档的 28 张补齐的 18 张）用途：

- `MediaSources` -- TODO-817 网络/本地来源库：一个媒体根扫描产出多本书/视频，敏感凭据绝不入 `configJson`。
- `ActivityEvents` -- 首页活动时间轴，每次 session 一行的精确时间戳事件流（read/watch/added）。
- `ClipboardHistory` -- 桌面剪贴板复制历史，供查词面板/瞬态浮窗的历史按钮读取。
- `MinedSentences` -- 制卡历史逐条记录（句子 + 跳回原文的定位锚点），供收藏夹跨媒体查看。
- `LookupMiningCounters` -- per-book 查词/制卡终身累加计数（区别于 `MinedSentences` 的滚动历史）。
- `Series` -- 旧「系列」容器，自 v38 冻结为遗留残留（勿再读写系列语义）。
- `ShelfEntries` -- 以 `(mediaType, entryKey)` 统管本地+远端条目的自定义排序权重与（遗留）系列归属。
- `MediaCollections` -- 统一合集容器（collection 无序 / playlist 有序，Jellyfin BoxSet/Playlist 式）。
- `MediaCollectionItems` -- 合集成员引用（复合键按合集去重，同一条目可属多个合集）。
- `CollectionMemberTombstones` -- 合集成员移出/合集删除墓碑，防跨端并集同步复活。
- `CollectionTagMappings` -- 合集 ↔ 标签 多对多映射（复用共享 `BookTags` 标签池）。
- `FushiPairedPeers` -- 互联（局域网配对）的 per-peer 授权凭据表，token 明文列存（红线：不进日志/明文导出）。
- `BookTombstones` -- 已删书墓碑，供备份「合并导入」跳过、避免复活已删的书。
- `StatisticsTombstones` -- per-book/video 统计删除墓碑，防 MAX-union 同步/备份把删掉的统计加回。
- `BookTagMembershipTombstones` -- 书/视频标签移除墓碑（LWW-element-set add/remove 裁决，防跨端复活/误删）。
- `SyncDeletionTombstones` -- sync 通道跨资产统一的删除墓碑（带发布状态，删除需双向确认、不静默传播）。
- `BookCustomCss` -- per-book 自定义 CSS 文本 + `updatedAt` 的跨端同步载体（LWW，`deleted`=重置墓碑）。
- `RevealedImages` -- 图片防剧透遮罩「已揭开」状态的持久真相源（书内 ↔ 图片库双向同步）。
- `Galgames` -- v55 galgame 游戏库真相源，取代旧偏好 key `galgame_library` 的 6 字段 JSON；TEXT 主键沿用旧微秒时间戳（封面文件名与之绑定）。
- `GalgameSources` -- 游戏元数据源纵表（`(gameId, source)` 复合键 + JSON 快照 + 上提的 score/rank），加数据源零 schema 变更。
- `GalgameSessions` -- 游玩会话事实表，由前台窗口计时器写入（脱离 hook 文本）。**刻意无统计投影表**，时长/次数/最后游玩一律现算 GROUP BY。
- `GalgameTagMappings` -- v59（BUG-1113）游戏 ↔ 用户标签映射（复用共享 `BookTags` 池）。**无 `addedAt` 时钟、无移除墓碑**：游戏是本机局域身份，整套游戏数据不进 live-sync 也不进备份合并导入，标签跟随宿主不跨端传播。与游戏**元数据标签**（bgm/vndb 刮削字符串）是两条正交轴。

迁移策略：`onUpgrade` 逐版本增量迁移，**最低可升级 schema 是 `kMinSupportedSchemaVersion`（v75）**——v2–v75 的阶梯（含 Hibiki 时代的 `hibiki.db` 改名与 `reader_ttu` / `sasayaki` / `hoshi://` / `s:hibikiServer` 等存量改写）已删除。低于门槛的库（含目录里只有改名前 `hibiki.db` 的情况）在任何迁移语句之前抛 `UnsupportedLegacySchemaException`，库文件原样保留，app 提示先装 `kLegacySchemaBridgeAppVersion`（v2.9.1，仍带完整阶梯）打开一次再更新；备份恢复 / 合并导入用 `checkSupportedSchemaVersion` + 文件头 `user_version` 在覆盖前做同样判定。降级（库比代码新）同样拒绝打开（`FushiDatabaseDowngradeException`），绝不重建。

## 测试与质量

测试位于 `fushi/test/database/` 下，覆盖：
- `migration_test.dart` -- 迁移路径验证
- `preferences_test.dart` / `pref_codec_test.dart` -- 偏好读写
- `epub_books_test.dart` / `audiobooks_test.dart` / `media_items_test.dart` 等 -- 各表 CRUD
- `concurrent_writes_test.dart` -- 并发写入
- `foreign_keys_test.dart` -- 外键约束
- `profiles_test.dart` / `reader_positions_test.dart` / `tags_test.dart` 等

## 相关文件清单

- `lib/fushi_core.dart` -- 库入口
- `lib/src/database/database.dart` -- 数据库定义与 CRUD
- `lib/src/database/database.g.dart` -- 生成文件（勿手动修改）
- `lib/src/database/tables.dart` -- 全部表定义
- `lib/src/database/pref_codec.dart` -- 偏好编解码
- `lib/src/models/fushi_text_selection.dart` -- 文本选区模型

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
