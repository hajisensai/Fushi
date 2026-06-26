[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_core**

# hibiki_core

## 模块职责

共享核心模块：定义 Drift SQLite 数据库 schema（28 张表，当前 schemaVersion=28）、表迁移逻辑、偏好键值编解码器（PrefCodec）、语言配置模型和文本选区模型。是所有其他 packages 的基础依赖。

## 入口与启动

- 库入口：`lib/hibiki_core.dart`
- 数据库在 `lib/src/database/database.dart` 中通过 `HibikiDatabase(dbDirectory)` 构造，内部使用 `NativeDatabase.createInBackground()` 在后台线程打开 `hibiki.db`。
- PRAGMA 配置：`journal_mode=WAL`，`foreign_keys=ON`。

## 对外接口

- `HibikiDatabase` -- 全部数据访问层，提供 media items / anki mappings / search history / audiobooks / audio cues / srt books / reader positions / bookmarks / reading statistics / preferences / dictionary metadata / epub books / book tags / profiles 等完整 CRUD API。
- `PrefCodec` -- 偏好值的 `encode<T>` / `decode<T>` 泛型编解码。
- `LanguageConfig` -- 语言配置枚举。
- `HibikiTextSelection` -- 跨模块共享的文本选区数据模型。

## 关键依赖与配置

- `drift: ^2.23.0` + `sqlite3_flutter_libs: ^0.5.28` -- ORM 和 SQLite native 绑定。
- `path: ^1.8.2` -- 路径处理。
- 代码生成：`drift_dev` + `build_runner`，生成 `database.g.dart`。

## 数据模型

28 张 Drift 表（按功能分组）：

| 分组 | 表名 |
|------|------|
| 媒体 | `MediaItems` |
| Anki | `AnkiMappings` |
| 搜索 | `SearchHistoryItems` |
| 有声书 | `Audiobooks`, `AudioCues`, `SrtBooks` |
| 阅读位置 | `ReaderPositions`, `Bookmarks` |
| 统计 | `ReadingStatistics`, `ReadingHourlyLogs` |
| 偏好 | `Preferences` |
| 词典 | `DictionaryMetadata`, `DictionaryHistory` |
| EPUB | `EpubBooks` |
| 标签 | `BookTags`, `BookTagMappings`, `SrtBookTagMappings` |
| Profile | `Profiles`, `ProfileSettings`, `MediaTypeProfiles`, `BookProfiles` |
| 同步 | `SyncBaselines` |
| 视频 | `VideoBooks`, `VideoBookTagMappings`, `VideoWatchStatistics`, `VideoHourlyLogs` |
| 收藏/制卡 | `FavoriteWords`, `MiningStatistics` |

迁移策略：`onUpgrade` 逐版本增量迁移（v1->v24），支持降级时自动备份并重建。

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
- `lib/src/language/language_config.dart` -- 语言配置
- `lib/src/models/hibiki_text_selection.dart` -- 文本选区模型

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
