[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_core**

# hibiki_core

## 模块职责

共享核心模块：定义 Drift SQLite 数据库 schema（53 张表，当前 schemaVersion=62）、表迁移逻辑、偏好键值编解码器（PrefCodec）、语言配置模型和文本选区模型。是所有其他 packages 的基础依赖。

## 入口与启动

- 库入口：`lib/hibiki_core.dart`
- 数据库在 `lib/src/database/database.dart` 中通过 `HibikiDatabase(dbDirectory)` 构造，内部使用 `NativeDatabase.createInBackground()` 在后台线程打开 `hibiki.db`。
- PRAGMA 配置：`journal_mode=WAL`，`foreign_keys=ON`。

## 对外接口

- `HibikiDatabase` -- 全部数据访问层，提供 media items / anki mappings / search history / audiobooks / audio cues / srt books / reader positions / bookmarks / reading statistics / preferences / dictionary metadata / epub books / book tags / profiles 等完整 CRUD API。
- `PrefCodec` -- 偏好值的 `encode<T>` / `decode<T>` 泛型编解码。
- `HibikiTextSelection` -- 跨模块共享的文本选区数据模型。

## 关键依赖与配置

- `drift: ">=2.33.0 <2.34.0"` + `sqlite3_flutter_libs: ^0.5.28` -- ORM 和 SQLite native 绑定。
- `path: ^1.8.2` -- 路径处理。
- 代码生成：`drift_dev: ^2.23.0` + `build_runner`，生成 `database.g.dart`。

## 数据模型

53 张 Drift 表（按功能分组，以 `database.dart` 的 `@DriftDatabase(tables: [...])` 注册清单为准）：

| 分组 | 表名 |
|------|------|
| 媒体 | `MediaItems` |
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
| 标签 | `BookTags`, `BookTagMappings`, `SrtBookTagMappings`, `CollectionTagMappings` |
| Profile | `Profiles`, `ProfileSettings`, `MediaTypeProfiles`, `BookProfiles` |
| 同步基线 | `SyncBaselines` |
| 视频 | `VideoBooks`, `VideoBookTagMappings`, `VideoWatchStatistics`, `VideoHourlyLogs` |
| 收藏/制卡 | `FavoriteWords`, `MiningStatistics`, `MinedSentences`, `LookupMiningCounters` |
| 合集/系列 | `MediaCollections`, `MediaCollectionItems`, `Series`, `ShelfEntries` |
| 互联 | `HibikiPairedPeers` |
| 游戏库 | `Galgames`, `GalgameSources`, `GalgameSessions`, `GalgameTagMappings` |
| 删除墓碑 | `BookTombstones`, `StatisticsTombstones`, `CollectionMemberTombstones`, `BookTagMembershipTombstones`, `SyncDeletionTombstones` |

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
- `HibikiPairedPeers` -- 互联（局域网配对）的 per-peer 授权凭据表，token 明文列存（红线：不进日志/明文导出）。
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

迁移策略：`onUpgrade` 逐版本增量迁移（v1->v57），支持降级时自动备份并重建。

## 测试与质量

测试位于 `hibiki/test/database/` 下，覆盖：
- `migration_test.dart` -- 迁移路径验证
- `preferences_test.dart` / `pref_codec_test.dart` -- 偏好读写
- `epub_books_test.dart` / `audiobooks_test.dart` / `media_items_test.dart` 等 -- 各表 CRUD
- `concurrent_writes_test.dart` -- 并发写入
- `foreign_keys_test.dart` -- 外键约束
- `profiles_test.dart` / `reader_positions_test.dart` / `tags_test.dart` 等

## 相关文件清单

- `lib/hibiki_core.dart` -- 库入口
- `lib/src/database/database.dart` -- 数据库定义与 CRUD
- `lib/src/database/database.g.dart` -- 生成文件（勿手动修改）
- `lib/src/database/tables.dart` -- 全部表定义
- `lib/src/database/pref_codec.dart` -- 偏好编解码
- `lib/src/models/hibiki_text_selection.dart` -- 文本选区模型

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
