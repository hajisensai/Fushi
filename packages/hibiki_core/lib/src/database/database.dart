import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'pref_codec.dart';
import 'tables.dart';

part 'database.g.dart';

/// Thrown when the on-disk database was created by a NEWER build of Hibiki than
/// the one currently running (`db user_version > code schemaVersion`).
///
/// 降级保护：当用户用旧版应用打开由新版创建的库时，绝不 DROP/迁移/重建，而是抛出此
/// 异常让打开失败、事务回滚、库文件原样保留，并由 UI 提示用户更新应用。这是修复
/// 「旧 app 启动把用户数据库降级破坏」整类事故的根因拦截。
class HibikiDatabaseDowngradeException implements Exception {
  /// The schema version stored in the on-disk DB file (created by a newer app).
  final int dbVersion;

  /// The schema version this (older) build of the code knows about.
  final int appSchemaVersion;

  const HibikiDatabaseDowngradeException({
    required this.dbVersion,
    required this.appSchemaVersion,
  });

  @override
  String toString() =>
      'HibikiDatabaseDowngradeException: database was created by a newer '
      'version of Hibiki (schema v$dbVersion); this app only understands '
      'schema v$appSchemaVersion. Opening was refused to protect your data.';
}

LazyDatabase _openDb(String dbDirectory) {
  return LazyDatabase(() async {
    final file = File(p.join(dbDirectory, 'hibiki.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA busy_timeout = 5000');
      },
    );
  });
}

/// Opens an arbitrary `.db` FILE (not a directory). Used by the backup MERGE
/// import (TODO-888) to migrate an extracted backup DB up to the current schema
/// before ATTACHing it to the live DB. Same PRAGMAs as [_openDb].
LazyDatabase _openDbFile(String dbFilePath) {
  return LazyDatabase(() async {
    final file = File(dbFilePath);
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA busy_timeout = 5000');
      },
    );
  });
}

@DriftDatabase(tables: [
  MediaItems,
  AnkiMappings,
  SearchHistoryItems,
  Audiobooks,
  AudioCues,
  SrtBooks,
  ReaderPositions,
  Bookmarks,
  ReadingStatistics,
  ReadingHourlyLogs,
  Preferences,
  DictionaryMetadata,
  DictionaryHistory,
  EpubBooks,
  BookTags,
  BookTagMappings,
  SrtBookTagMappings,
  Profiles,
  ProfileSettings,
  MediaTypeProfiles,
  BookProfiles,
  SyncBaselines,
  VideoBooks,
  VideoBookTagMappings,
  VideoWatchStatistics,
  VideoHourlyLogs,
  FavoriteWords,
  MiningStatistics,
  MinedSentences,
  MediaSources,
])
class HibikiDatabase extends _$HibikiDatabase {
  HibikiDatabase(String dbDirectory) : super(_openDb(dbDirectory));

  /// Opens a specific `.db` FILE (not a directory). Backup MERGE import
  /// (TODO-888) uses this to migrate an extracted backup DB to the current
  /// schema before merging it into the live DB.
  HibikiDatabase.atFile(String dbFilePath) : super(_openDbFile(dbFilePath));

  HibikiDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 29;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from > to) {
            // DOWNGRADE PROTECTION (root-cause fix for the recurring "old app
            // downgrades & destroys the user DB" incidents). drift dispatches
            // onUpgrade whenever the stored user_version != code schemaVersion,
            // INCLUDING when the DB is NEWER than the code (from > to). This is
            // the EARLIEST hook drift gives us, and it runs BEFORE any DROP /
            // migration / customStatement below. We refuse the open here by
            // throwing, which aborts beforeOpen: drift never advances
            // user_version and the DB file is left byte-for-byte intact. NEVER
            // drop / migrate / rebuild in this branch — a previous build did
            // exactly that and wiped users' libraries twice. The app layer
            // catches this exception and shows an "update your app" notice.
            throw HibikiDatabaseDowngradeException(
              dbVersion: from,
              appSchemaVersion: to,
            );
          }
          if (from < 2) {
            if (!await _columnExists('dictionary_metadata', 'type')) {
              await m.addColumn(dictionaryMetadata, dictionaryMetadata.type);
            }
          }
          if (from < 3) {
            await m.createTable(readingHourlyLogs);
          }
          if (from < 4) {
            // 历史 v4 加的是 ttu_char_offset；后续 v16 重建仍带它，最终 v24 整列删除
            // （合并到 char_offset）。表定义已无 ttuCharOffset getter，用 raw SQL 保
            // 历史列名，让 v16/v24 找得到它。
            if (!await _columnExists('reader_positions', 'ttu_char_offset')) {
              await customStatement(
                'ALTER TABLE reader_positions '
                'ADD COLUMN ttu_char_offset INTEGER NOT NULL DEFAULT -1',
              );
            }
          }
          if (from < 5) {
            await m.createTable(epubBooks);
          }
          if (from < 6) {
            await m.createTable(bookTags);
            await m.createTable(bookTagMappings);
          }
          if (from < 7) {
            if (!await _columnExists('book_tags', 'sort_order')) {
              await m.addColumn(bookTags, bookTags.sortOrder);
            }
            await customStatement(
              'UPDATE book_tags SET sort_order = id WHERE sort_order = 0',
            );
          }
          if (from < 8) {
            await m.createTable(profiles);
            await m.createTable(profileSettings);
            await m.createTable(mediaTypeProfiles);
            await m.createTable(bookProfiles);
          }
          if (from < 9) {
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
            );
          }
          if (from < 10) {
            // The book_id orphan cleanup references the legacy `book_id`
            // column. A DB whose book_tag_mappings was created fresh later in
            // this same ladder (via m.createTable with the current v16
            // `book_key` schema) has no `book_id` column, so guard on it — the
            // v16 step re-derives the mapping under `book_key` anyway.
            if (await _columnExists('book_tag_mappings', 'book_id')) {
              await customStatement(
                'DELETE FROM book_tag_mappings '
                'WHERE book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            await customStatement(
              'DELETE FROM book_tag_mappings '
              'WHERE tag_id NOT IN (SELECT id FROM book_tags)',
            );
            await customStatement(
              'DELETE FROM profile_settings '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM media_type_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM book_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
          }
          if (from < 11) {
            await m.createTable(bookmarks);
            // bookmarks is created via m.createTable using the CURRENT (v16)
            // generated schema (column `book_key`, not legacy `ttu_book_id`),
            // so only create the legacy-named index when that column actually
            // exists. The v16 step recreates it under `book_key`.
            if (await _columnExists('bookmarks', 'ttu_book_id')) {
              await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
                'ON bookmarks (ttu_book_id, created_at DESC)',
              );
            }
            await migrateLegacyBookmarkPreferences();
          }
          if (from < 12) {
            Future<bool> tableExists(String name) async {
              final row = await customSelect(
                'SELECT COUNT(*) AS c FROM sqlite_master '
                "WHERE type='table' AND name=?",
                variables: [Variable.withString(name)],
              ).getSingle();
              return row.read<int>('c') > 0;
            }

            // These orphan cleanups reference legacy int columns
            // (ttu_book_id / book_uid). A DB whose tables were created fresh
            // earlier in this ladder uses the v16 `book_key` schema and lacks
            // those columns, so each is additionally column-guarded; the v16
            // step re-runs the equivalent cleanup against `book_key`.
            if (await tableExists('reader_positions') &&
                await tableExists('epub_books') &&
                await _columnExists('reader_positions', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM reader_positions '
                'WHERE ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            // Remove srt_books whose backing epub is gone (standalone SRT
            // books keep ttu_book_id = 0 and are preserved). Run BEFORE the
            // audio_cues cleanup so cues of removed srt_books become orphans.
            if (await tableExists('srt_books') &&
                await tableExists('epub_books') &&
                await _columnExists('srt_books', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM srt_books '
                'WHERE ttu_book_id > 0 '
                'AND ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            // audio_cues.book_uid is owned by EITHER audiobooks.book_uid OR
            // srt_books.uid. Only delete cues orphaned from BOTH owners; the
            // previous audiobooks-only predicate silently wiped every SRT
            // book's cues on upgrade (data loss, HBK-AUDIT-001).
            if (await tableExists('audio_cues') &&
                await tableExists('audiobooks') &&
                await tableExists('srt_books') &&
                await _columnExists('audio_cues', 'book_uid') &&
                await _columnExists('audiobooks', 'book_uid')) {
              await customStatement(
                'DELETE FROM audio_cues '
                'WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks) '
                'AND book_uid NOT IN (SELECT uid FROM srt_books)',
              );
            }
            if (await tableExists('bookmarks') &&
                await tableExists('epub_books') &&
                await _columnExists('bookmarks', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM bookmarks '
                'WHERE ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
          }
          if (from < 13) {
            await m.createTable(srtBookTagMappings);
          }
          if (from < 14) {
            // Indexes were previously (re)created in beforeOpen on every open
            // (12 extra sqlite_master probes per launch). Create them once on
            // upgrade so existing DBs gain any missing index; fresh DBs get
            // them in onCreate. This runs on the PRE-v16 schema, so it uses the
            // OLD column names (book_uid / ttu_book_id / book_id). The v16 step
            // below rebuilds those tables and recreates the indexes under the
            // new book_key column names via _ensureIndexes().
            await _ensureLegacyIndexesV14();
          }
          if (from < 15) {
            await m.createTable(syncBaselines);
          }
          if (from < 16) {
            await _migrateBookKeyV16(m);
          }
          if (from < 17) {
            // VideoBooks landed on the name-PK baseline as v17 (the video
            // worktree's original v16-v19 step numbering was rebased onto
            // develop's name-PK v16). develop users never had a video_books
            // table, so a single createTable builds the full schema
            // (book_uid PK + playlist_json / current_episode / audio_track_id /
            // delay_ms). Guard so a fresh DB (which already has the table from
            // onCreate's createAll) doesn't try to recreate it.
            if (!await _tableExists('video_books')) {
              await m.createTable(videoBooks);
            }
          }
          if (from < 20) {
            // Convergence point. The video worktree forked BEFORE develop's
            // name-PK v16 and burned its own v16-v19 numbers on video_books, so
            // a real user DB can sit at user_version 16-19 with epub_books still
            // id-keyed and a legacy id-PK video_books — the from<16 / from<17
            // steps above never fire for it (version already past them). This
            // step converges BOTH lineages by inspecting the ACTUAL schema, not
            // the version number (the two lineages' v16-v19 are semantically
            // different, so only column/PK probes can tell them apart). Both
            // paths are idempotent and lossless for real user data.
            //
            // (1) epub_books still id-keyed (video-line fork never ran name-PK)
            //     -> re-key now. _migrateBookKeyV16 self-guards with
            //     `if (!_columnExists('epub_books','id')) return`, so it is a
            //     no-op for develop name-PK users. It rebuilds books + reading
            //     relations inside one atomic transaction and never touches
            //     video_books (content-keyed, no FK to epub id).
            await _migrateBookKeyV16(m);
            // (2) video_books on the legacy autoincrement id PK (built by the
            //     video line's v16-v19) -> rebuild as book_uid PK. Video data is
            //     reimportable test data, so drop+recreate is simplest and
            //     safest. develop users' video_books (just built by from<17) is
            //     already book_uid-keyed and is left alone.
            if (await _tableExists('video_books') &&
                !await _videoBooksKeyedByBookUid()) {
              await m.deleteTable('video_books');
            }
            if (!await _tableExists('video_books')) {
              await m.createTable(videoBooks);
            }
          }
          if (from < 21) {
            // video_book_tag_mappings: lets video books share the same BookTags
            // pool as EPUB/SRT books. video_books is guaranteed to exist by the
            // from<20 convergence above (FK target). Guard so a fresh DB (table
            // already built by onCreate's createAll) doesn't recreate it.
            if (!await _tableExists('video_book_tag_mappings')) {
              await m.createTable(videoBookTagMappings);
            }
          }
          if (from < 22) {
            // 视频统计：两张独立表 + video_books.completed_at 列。与阅读统计完全
            // 隔离，不碰 reading_statistics。fresh DB 已由 onCreate 的 createAll
            // 建好，故用 _tableExists / _columnExists 守卫避免重复创建。
            if (!await _tableExists('video_watch_statistics')) {
              await m.createTable(videoWatchStatistics);
            }
            if (!await _tableExists('video_hourly_logs')) {
              await m.createTable(videoHourlyLogs);
            }
            if (!await _columnExists('video_books', 'completed_at')) {
              await m.addColumn(videoBooks, videoBooks.completedAt);
            }
          }
          if (from < 23) {
            // 收藏词条 + 制卡计数：查词弹窗收藏与制卡计入阅读/视频统计。fresh DB
            // 已由 onCreate 的 createAll 建好，用 _tableExists 守卫避免重复创建。
            if (!await _tableExists('favorite_words')) {
              await m.createTable(favoriteWords);
            }
            if (!await _tableExists('mining_statistics')) {
              await m.createTable(miningStatistics);
            }
          }
          if (from < 24) {
            // BUG-162: 阅读位置精确字符偏移合并为单一列 char_offset，删除原
            // ttu_char_offset（sync 精确缓存列——云同步精度退化为 normCharOffset 分数后
            // 不再需要）。用 ADD/DROP COLUMN（与表里其他列名无关，避免依赖 book_key 是否
            // 已 re-key；SQLite 3.35+ 支持 DROP COLUMN，bundled sqlite3 够新）。既有行
            // char_offset 默认 -1（首次退出再进回退分数，翻一页 re-save 即精确）。
            // partial 测试 DB 无此表 → _tableExists 守卫跳过。
            if (await _tableExists('reader_positions')) {
              if (!await _columnExists('reader_positions', 'char_offset')) {
                await customStatement(
                  'ALTER TABLE reader_positions '
                  'ADD COLUMN char_offset INTEGER NOT NULL DEFAULT -1',
                );
              }
              if (await _columnExists('reader_positions', 'ttu_char_offset')) {
                await customStatement(
                  'ALTER TABLE reader_positions DROP COLUMN ttu_char_offset',
                );
              }
            }
          }
          if (from < 25) {
            // 制卡历史：逐条制卡记录（句子 + 跳回原文的定位锚点），供收藏夹页全局查看。
            // fresh DB 已由 onCreate 的 createAll 建好，用 _tableExists 守卫避免重复创建。
            if (!await _tableExists('mined_sentences')) {
              await m.createTable(minedSentences);
            }
          }
          if (from < 26) {
            // TODO-809 自愈回填：历史（BUG-414 修复前）sync/导入侧用
            // sanitizeTtuFilename(title) 重算 audiobook 的 book_key 而非 host 真实
            // key 写库，导致 audiobooks.book_key 与 epub_books.book_key 集体失配 →
            // 书架耳机徽章判据（audiobooks.book_key == epub_books.book_key 纯字符串
            // 相等）查不中，有声书集体「变成普通书」。写入侧已彻底修干净，但已落库的
            // 失配旧行永远查不中，故需一次性安全回填。详见
            // backfillMismatchedAudiobookKeysV26 的契约说明。
            await backfillMismatchedAudiobookKeysV26();
          }
          if (from < 27) {
            // TODO-817 网络/本地来源库地基：新增 media_sources 表 + video_books /
            // epub_books 的 source_id 外键列（onDelete:setNull）。无损迁移：只
            // createTable + addColumn（nullable 无 default → 既有行 source_id 全
            // NULL），不 DROP / 不改既有列 / 不删行。守卫幂等（fresh DB 已由 onCreate
            // 的 createAll 建好，重复升级 no-op）。**顺序必须先 createTable(mediaSources)
            // 再两 addColumn**（FK 目标表须先存在；SQLite ADD COLUMN 带 REFERENCES 仅
            // 当新列默认 NULL 时合法，sourceId nullable 无 default 满足）。
            if (!await _tableExists('media_sources')) {
              await m.createTable(mediaSources);
            }
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'source_id')) {
              await m.addColumn(videoBooks, videoBooks.sourceId);
            }
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'source_id')) {
              await m.addColumn(epubBooks, epubBooks.sourceId);
            }
          }
          if (from < 28) {
            // TODO-857 视频双字幕（Path A）：video_books 加 secondary_subtitle_source。
            // 无损迁移：只 addColumn（nullable 无 default → 既有行全 NULL = 无副字幕），
            // 不 DROP / 不改既有列 / 不删行。守卫幂等（fresh DB 已由 onCreate 的
            // createAll 建好，用 _columnExists 守卫避免重复加列，重复升级 no-op）。
            if (await _tableExists('video_books') &&
                !await _columnExists(
                    'video_books', 'secondary_subtitle_source')) {
              await m.addColumn(videoBooks, videoBooks.secondarySubtitleSource);
            }
          }
          if (from < 29) {
            // TODO-894：自愈 EPUB-backed 有声书缺失的配对 srt_books 行。历史上
            // _importEpubWithAlignment 只写 audiobooks，不写 srt_books → push 两条
            // 消费路径（live push + syncAudiobookPackages）查 getSrtBookByBookKey
            // ==null → 整本永不上传。本步只 INSERT 缺失的配对行（不改既有列/不删行）。
            await backfillMissingAudiobookSrtBooksV29();
          }
        },
        onCreate: (m) async {
          await m.createAll();
          await _ensureIndexes();
        },
        beforeOpen: (details) async {
          // Second, belt-and-suspenders downgrade guard. drift calls beforeOpen
          // on every open with the on-disk version (`versionBefore`, null for a
          // freshly created DB) and the code version (`versionNow`). On a real
          // downgrade onUpgrade already threw above (hadUpgrade is true when
          // versionBefore != versionNow), but if that branch is ever weakened
          // this independent check still refuses the open before any query runs.
          // No DROP / migration here — just throw to abort the open with the DB
          // untouched.
          final int? before = details.versionBefore;
          if (before != null && before > schemaVersion) {
            throw HibikiDatabaseDowngradeException(
              dbVersion: before,
              appSchemaVersion: schemaVersion,
            );
          }
        },
      );

  /// Creates all secondary indexes idempotently. Called from onCreate (fresh
  /// install) and the one-time v14 onUpgrade step — NOT on every open. Each
  /// index is guarded by a table-existence check because a partially-migrated
  /// legacy DB may lack some v1 baseline tables (those are created only in
  /// onCreate, never in the onUpgrade ladder).
  Future<void> _ensureIndexes() async {
    const List<List<String>> indexes = <List<String>>[
      [
        'profile_settings',
        'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)'
      ],
      [
        'media_type_profiles',
        'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)'
      ],
      [
        'book_profiles',
        'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)'
      ],
      [
        'bookmarks',
        'CREATE INDEX IF NOT EXISTS idx_bookmarks_book_key_created '
            'ON bookmarks (book_key, created_at DESC)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_type '
            'ON media_items (media_type_identifier)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_source '
            'ON media_items (media_source_identifier)'
      ],
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_key '
            'ON audio_cues (book_key)'
      ],
      [
        'search_history_items',
        'CREATE INDEX IF NOT EXISTS idx_search_history_key '
            'ON search_history_items (history_key)'
      ],
      [
        'audiobooks',
        'CREATE INDEX IF NOT EXISTS idx_audiobooks_book_key '
            'ON audiobooks (book_key)'
      ],
      [
        'srt_books',
        'CREATE INDEX IF NOT EXISTS idx_srt_books_book_key '
            'ON srt_books (book_key)'
      ],
      [
        'book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_book_tag_mappings_book_key '
            'ON book_tag_mappings (book_key)'
      ],
    ];
    for (final List<String> entry in indexes) {
      if (await _tableExists(entry[0])) {
        await customStatement(entry[1]);
      }
    }
  }

  /// PRE-v16 index creation for the from<14 upgrade step. Mirrors the old
  /// (book_uid / ttu_book_id / book_id) column names that still exist before
  /// the v16 book-key migration rebuilds those tables. The v16 step recreates
  /// these under the new book_key column names via [_ensureIndexes].
  ///
  /// Each entry is `[table, sql, requiredColumn?]`. When [requiredColumn] is
  /// present it is also column-guarded: a DB that arrives at this step with its
  /// book tables already created fresh under the v16 schema (e.g. a pre-v11 DB
  /// where the from<11 ladder step ran `createTable` with the current
  /// generated `book_key` columns) does NOT have the legacy `ttu_book_id` /
  /// `book_uid` / `book_id` column, so creating the legacy-named index would
  /// throw "no such column". The v16 step recreates these under `book_key`.
  Future<void> _ensureLegacyIndexesV14() async {
    const List<List<String>> indexes = <List<String>>[
      [
        'profile_settings',
        'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)'
      ],
      [
        'media_type_profiles',
        'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)'
      ],
      [
        'book_profiles',
        'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)'
      ],
      [
        'bookmarks',
        'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
            'ON bookmarks (ttu_book_id, created_at DESC)',
        'ttu_book_id'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_type '
            'ON media_items (media_type_identifier)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_source '
            'ON media_items (media_source_identifier)'
      ],
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_uid '
            'ON audio_cues (book_uid)',
        'book_uid'
      ],
      [
        'search_history_items',
        'CREATE INDEX IF NOT EXISTS idx_search_history_key '
            'ON search_history_items (history_key)'
      ],
      [
        'audiobooks',
        'CREATE INDEX IF NOT EXISTS idx_audiobooks_book_uid '
            'ON audiobooks (book_uid)',
        'book_uid'
      ],
      [
        'srt_books',
        'CREATE INDEX IF NOT EXISTS idx_srt_books_ttu_book_id '
            'ON srt_books (ttu_book_id)',
        'ttu_book_id'
      ],
      [
        'book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_book_tag_mappings_book_id '
            'ON book_tag_mappings (book_id)',
        'book_id'
      ],
    ];
    for (final List<String> entry in indexes) {
      if (!await _tableExists(entry[0])) continue;
      if (entry.length > 2 && !await _columnExists(entry[0], entry[2])) {
        continue;
      }
      await customStatement(entry[1]);
    }
  }

  static final RegExp _identifierRe = RegExp(r'^[a-zA-Z_]\w*$');

  Future<bool> _columnExists(String tableName, String columnName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    if (!_identifierRe.hasMatch(columnName)) {
      throw ArgumentError.value(
          columnName, 'columnName', 'not a valid identifier');
    }
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    return rows.any((row) => row.read<String>('name') == columnName);
  }

  Future<bool> _tableExists(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    return rows.isNotEmpty;
  }

  /// Whether video_books is keyed by book_uid (the unified v20 shape) rather
  /// than the legacy autoincrement `id` PK the video worktree's v16-v19 used.
  /// Probes the actual table_info so the v20 convergence step can tell a
  /// video-line fork (id PK -> must rebuild) from an already-correct table.
  Future<bool> _videoBooksKeyedByBookUid() async {
    final rows = await customSelect("PRAGMA table_info('video_books')").get();
    final Iterable<QueryRow> pkCols =
        rows.where((QueryRow r) => r.read<int>('pk') > 0);
    return pkCols.length == 1 &&
        pkCols.first.read<String>('name') == 'book_uid';
  }

  /// TODO-809 自愈回填：把 `audiobooks` 里 `book_key` 与任一 `epub_books.book_key`
  /// 失配的旧行，经其 SRT 伴生记录的标题在 `epub_books` 中**唯一匹配**到的真实
  /// book_key，三表（audiobooks / srt_books / audio_cues）一致改写回去，让书架耳机
  /// 徽章（判据 = `audiobooks.book_key == epub_books.book_key`）重新查得中。
  ///
  /// 失配根因：BUG-414 修复前，sync/导入侧用 `sanitizeTtuFilename(title)` 重算
  /// book_key 而非 host 真实 key 写库。写入侧现已干净，但已落库失配旧行需此一次性
  /// 安全回填修复。
  ///
  /// 匹配链路：失配 audiobook -> 同 book_key 的 srt_books 行（伴生 SRT）-> 该 SRT
  /// 的 `title` -> `epub_books.title`。仅当该 title 在 epub_books 中**恰好 1 条**
  /// （`COUNT(*) == 1`）时才视为安全匹配并改写；0 条（孤儿）或 >1 条（同名歧义）
  /// 一律保持原值不动，仅记日志。
  ///
  /// 安全边界（Never break userspace）：
  /// - 只在唯一安全匹配（m == 1）时改写，绝不盲改、绝不删行。
  /// - 改写前先排除「目标真实 key 已被另一行 audiobook 占用」的情形（避免撞
  ///   `audiobooks.book_key UNIQUE` 等唯一约束），歧义同样跳过。
  /// - 全程单事务；幂等——健全库（无失配行）下自动 no-op，零行变更；可重复执行无
  ///   副作用（再次执行时所有行已匹配，候选集为空）。
  /// - 缺表（partial DB 无 audiobooks/srt_books/epub_books）守卫跳过。
  Future<void> backfillMismatchedAudiobookKeysV26() async {
    if (!await _tableExists('audiobooks') ||
        !await _tableExists('srt_books') ||
        !await _tableExists('epub_books')) {
      return;
    }
    // 列守卫：极端 partial/legacy DB 可能缺 book_key 列（理论上到 v26 已 re-key，
    // 但守卫成本低、可彻底避免 "no such column" 抛错中断整条迁移）。
    if (!await _columnExists('audiobooks', 'book_key') ||
        !await _columnExists('srt_books', 'book_key') ||
        !await _columnExists('srt_books', 'title') ||
        !await _columnExists('epub_books', 'book_key') ||
        !await _columnExists('epub_books', 'title')) {
      return;
    }
    final bool hasAudioCues = await _tableExists('audio_cues') &&
        await _columnExists('audio_cues', 'book_key');

    await transaction(() async {
      // 候选：audiobooks.book_key 不在 epub_books 任何 book_key 里（失配），且其
      // 同 book_key 的 srt_books.title 在 epub_books 中唯一匹配（COUNT == 1）。
      // newKey = 该唯一 epub_books.book_key。
      final List<QueryRow> candidates = await customSelect(
        'SELECT a.book_key AS old_key, '
        '(SELECT e.book_key FROM epub_books e WHERE e.title = s.title) AS new_key '
        'FROM audiobooks a '
        'JOIN srt_books s ON s.book_key = a.book_key '
        'WHERE a.book_key NOT IN (SELECT book_key FROM epub_books) '
        'AND (SELECT COUNT(*) FROM epub_books e WHERE e.title = s.title) = 1',
      ).get();

      int rewritten = 0;
      int skippedTargetOccupied = 0;
      int skippedAmbiguousOldKey = 0;
      final Set<String> claimedNewKeys = <String>{};

      // 同一 old_key 经多条 SRT 解析到不同 new_key 的歧义行剔除（srt_books 对
      // book_key 不设唯一约束，防御性处理）。
      final Map<String, Set<String>> oldToNew = <String, Set<String>>{};
      for (final QueryRow row in candidates) {
        final String oldKey = row.read<String>('old_key');
        final String newKey = row.read<String>('new_key');
        (oldToNew[oldKey] ??= <String>{}).add(newKey);
      }

      for (final MapEntry<String, Set<String>> entry in oldToNew.entries) {
        final String oldKey = entry.key;
        if (entry.value.length != 1) {
          skippedAmbiguousOldKey += 1;
          continue;
        }
        final String newKey = entry.value.first;
        // 目标真实 key 已被另一行 audiobook（或本批已认领）占用 -> 跳过，避免撞
        // audiobooks.book_key UNIQUE。
        final List<QueryRow> occupied = await customSelect(
          'SELECT 1 FROM audiobooks WHERE book_key = ? LIMIT 1',
          variables: <Variable>[Variable<String>(newKey)],
        ).get();
        if (occupied.isNotEmpty || claimedNewKeys.contains(newKey)) {
          skippedTargetOccupied += 1;
          continue;
        }
        claimedNewKeys.add(newKey);

        await customStatement(
          'UPDATE audiobooks SET book_key = ? WHERE book_key = ?',
          <Object?>[newKey, oldKey],
        );
        await customStatement(
          'UPDATE srt_books SET book_key = ? WHERE book_key = ?',
          <Object?>[newKey, oldKey],
        );
        if (hasAudioCues) {
          await customStatement(
            'UPDATE audio_cues SET book_key = ? WHERE book_key = ?',
            <Object?>[newKey, oldKey],
          );
        }
        rewritten += 1;
      }

      debugPrint(
        '[hibiki-migration v26] audiobook book_key backfill: '
        'rewritten=$rewritten, '
        'skippedAmbiguousOldKey=$skippedAmbiguousOldKey, '
        'skippedTargetOccupied=$skippedTargetOccupied '
        '(orphans/同名歧义的失配行保持原值不动)',
      );
    });
  }

  /// TODO-894：为缺失配对 srt_books 行的 EPUB-backed 有声书补写一条 srt_books
  /// 行（v29 自愈迁移），仿 [backfillMismatchedAudiobookKeysV26] 范式：表/列守卫 →
  /// transaction → 裸 SQL → debugPrint 计数。
  ///
  /// 候选只取「audiobooks.book_key 能 JOIN 上 epub_books（即 EPUB-backed），且其
  /// book_key 不在任何 srt_books.book_key 里」。standalone 纯字幕书（有 srt_books
  /// 但**无 audiobooks 行**）天然不进 `FROM audiobooks a`，永不误伤。
  ///
  /// uid 与导入路径共用稳定派生 `srtbook_epub_<book_key>`；`INSERT OR IGNORE` +
  /// `WHERE NOT IN` 双重幂等（重复跑迁移不新增行、不改既有行）。cover_path 留空
  /// （export 不依赖 srtBook.coverPath）。
  Future<void> backfillMissingAudiobookSrtBooksV29() async {
    if (!await _tableExists('audiobooks') ||
        !await _tableExists('srt_books') ||
        !await _tableExists('epub_books')) {
      return;
    }
    if (!await _columnExists('audiobooks', 'book_key') ||
        !await _columnExists('audiobooks', 'alignment_path') ||
        !await _columnExists('audiobooks', 'audio_paths_json') ||
        !await _columnExists('srt_books', 'uid') ||
        !await _columnExists('srt_books', 'book_key') ||
        !await _columnExists('srt_books', 'srt_path') ||
        !await _columnExists('srt_books', 'title') ||
        !await _columnExists('epub_books', 'book_key') ||
        !await _columnExists('epub_books', 'title') ||
        !await _columnExists('epub_books', 'imported_at')) {
      return;
    }

    await transaction(() async {
      final List<QueryRow> candidates = await customSelect(
        'SELECT a.book_key AS book_key, '
        'a.alignment_path AS srt_path, '
        'a.audio_paths_json AS audio_json, '
        'e.title AS title, e.author AS author, e.imported_at AS imported '
        'FROM audiobooks a '
        'JOIN epub_books e ON e.book_key = a.book_key '
        'WHERE a.book_key NOT IN (SELECT book_key FROM srt_books)',
      ).get();

      int inserted = 0;
      for (final QueryRow row in candidates) {
        final String bookKey = row.read<String>('book_key');
        await customStatement(
          'INSERT OR IGNORE INTO srt_books '
          '(uid, title, author, audio_paths_json, srt_path, cover_path, '
          'imported_at, book_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'srtbook_epub_$bookKey',
            row.read<String>('title'),
            row.read<String?>('author'),
            row.read<String?>('audio_json'),
            row.read<String>('srt_path'),
            null, // cover_path: export 不依赖
            row.read<int>('imported'),
            bookKey,
          ],
        );
        inserted += 1;
      }

      debugPrint(
        '[hibiki-migration v29] EPUB-backed audiobook srt_books backfill: '
        'inserted=$inserted '
        '(standalone 字幕书无 audiobooks 行天然豁免，重复迁移幂等)',
      );
    });
  }

  // ── preferences helpers ─────────────────────────────────────────
  Future<String?> getPref(String key) async {
    final q = select(preferences)..where((t) => t.key.equals(key));
    final row = await q.getSingleOrNull();
    return row?.value;
  }

  /// TODO-855: persisted monotonic counter, bumped on every preference write
  /// at this single lowest-level write choke point ([setPref]). It is the
  /// cross-process change signal the separate :popup process reads (via a cheap
  /// indexed row lookup) to decide whether to reload its warm-reuse pref cache,
  /// instead of unconditionally re-scanning the whole preferences table on each
  /// lookup. Sinking the bump here means EVERY path that writes a preference —
  /// PreferencesRepository, ThemeNotifier (theme / app_ui_scale), MediaSource
  /// (per-source font sizes etc.), profile switch, sync/backup restore —
  /// automatically advances it; no caller can forget to bump.
  static const String prefsVersionKey = 'prefs_version';

  Future<void> setPref(String key, String value) async {
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(key: key, value: value),
    );
    // Bump the cross-process change signal for every real pref write. Skip the
    // version key itself (a direct write of it — e.g. a sync/backup restore
    // replaying the persisted counter — must NOT recursively bump on top of
    // its own value, which would double-count and break monotonic alignment).
    if (key != prefsVersionKey) {
      await _bumpPrefsVersion();
    }
  }

  /// Atomically increment the persisted prefs-version directly in the DB so the
  /// next cross-process read observes a strictly larger value. Encoded as a
  /// PrefCodec int (`i:N`) so it round-trips identically to every other int
  /// preference. Writes via the raw [into]/[insertOnConflictUpdate] path (NOT
  /// [setPref]) to avoid re-entering the recursion guard above.
  Future<void> _bumpPrefsVersion() async {
    final String? raw = await getPref(prefsVersionKey);
    final int current = raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        key: prefsVersionKey,
        value: PrefCodec.encode(current + 1),
      ),
    );
  }

  Future<T> getPrefTyped<T>(String key, T defaultValue) async {
    final raw = await getPref(key);
    if (raw == null) return defaultValue;
    return PrefCodec.decode<T>(raw, defaultValue);
  }

  Future<void> setPrefTyped<T>(String key, T value) =>
      setPref(key, PrefCodec.encode(value));

  Future<void> deletePref(String key) async {
    await (delete(preferences)..where((t) => t.key.equals(key))).go();
  }

  Future<Map<String, String>> getAllPrefs() async {
    final rows = await select(preferences).get();
    return Map.fromEntries(rows.map((r) => MapEntry(r.key, r.value)));
  }

  Future<void> migrateLegacyBookmarkPreferences() async {
    if (!await _tableExists('preferences')) {
      return;
    }
    if (!await _tableExists('bookmarks')) {
      return;
    }
    // Legacy `bookmarks_<int>` prefs predate the v16 book-key migration and key
    // on the int ttu_book_id column. After v16 that column is gone (renamed to
    // book_key) and the v16 prefs migration already drained/re-keyed these, so
    // this drainer is a no-op on the post-v16 schema. Guard on the column so it
    // only runs against the pre-v16 schema it understands.
    if (!await _columnExists('bookmarks', 'ttu_book_id')) {
      return;
    }
    final Map<String, String> allPrefs = await getAllPrefs();
    await transaction(() async {
      for (final MapEntry<String, String> entry in allPrefs.entries) {
        if (!entry.key.startsWith('bookmarks_')) continue;
        final int? ttuBookId =
            int.tryParse(entry.key.substring('bookmarks_'.length));
        if (ttuBookId == null || entry.value.isEmpty) continue;
        final QueryRow countRow = await customSelect(
          'SELECT COUNT(*) AS c FROM bookmarks WHERE ttu_book_id = ?',
          variables: [Variable<int>(ttuBookId)],
        ).getSingle();
        final int existing = countRow.read<int>('c');
        if (existing == 0) {
          List<dynamic> list;
          try {
            list = jsonDecode(entry.value) as List<dynamic>;
          } catch (_) {
            await customStatement(
              'DELETE FROM preferences WHERE key = ?',
              [entry.key],
            );
            continue;
          }
          for (final dynamic raw in list) {
            if (raw is! Map<String, dynamic>) continue;
            final int sectionIndex = raw['sectionIndex'] as int? ?? 0;
            final int normCharOffset = raw['normCharOffset'] as int? ?? 0;
            final String label = raw['label'] as String? ?? '';
            final DateTime createdAt = DateTime.tryParse(
                  raw['createdAt'] as String? ?? '',
                ) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            final int rowBookId = raw['ttuBookId'] as int? ?? ttuBookId;
            // bookmarks.ttu_book_id is a FK to epub_books(id). Legacy TTU ids
            // need not map to an imported epub, and INSERT OR IGNORE does NOT
            // suppress FK violations — an unmatched id would abort the whole
            // upgrade transaction (app can't open the DB). Skip orphans.
            final bookExists = await customSelect(
              'SELECT 1 FROM epub_books WHERE id = ? LIMIT 1',
              variables: [Variable<int>(rowBookId)],
            ).getSingleOrNull();
            if (bookExists == null) continue;
            await customStatement(
              'INSERT OR IGNORE INTO bookmarks '
              '(ttu_book_id, section_index, norm_char_offset, label, '
              'created_at, book_title, page_in_chapter, total_pages_in_chapter) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
              [
                rowBookId,
                sectionIndex,
                normCharOffset,
                label,
                createdAt.millisecondsSinceEpoch,
                raw['bookTitle'] as String?,
                raw['pageInChapter'] as int?,
                raw['totalPagesInChapter'] as int?,
              ],
            );
          }
        }
        await customStatement(
          'DELETE FROM preferences WHERE key = ?',
          [entry.key],
        );
      }
    });
  }

  // ── media items ─────────────────────────────────────────────────
  Future<List<MediaItemRow>> getAllMediaItems() =>
      (select(mediaItems)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<void> upsertMediaItem(MediaItemsCompanion item) =>
      into(mediaItems).insertOnConflictUpdate(item);

  Future<int> deleteMediaItemByUniqueKey(String uk) =>
      (delete(mediaItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> deleteMediaItemById(int id) =>
      (delete(mediaItems)..where((t) => t.id.equals(id))).go();

  Future<int> deleteMediaItemsByIdentifier(String ident) =>
      (delete(mediaItems)..where((t) => t.mediaIdentifier.equals(ident))).go();

  Future<List<MediaItemRow>> getMediaItemsByType(String typeId) =>
      (select(mediaItems)
            ..where((t) => t.mediaTypeIdentifier.equals(typeId))
            ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<List<MediaItemRow>> getMediaItemsBySource(String sourceId) =>
      (select(mediaItems)
            ..where((t) => t.mediaSourceIdentifier.equals(sourceId))
            ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<MediaItemRow?> getMediaItemByUniqueKey(String uk) =>
      (select(mediaItems)..where((t) => t.uniqueKey.equals(uk)))
          .getSingleOrNull();

  Future<void> trimMediaHistory(String typeId, int maxItems) async {
    await transaction(() async {
      final cnt = countAll();
      final q = selectOnly(mediaItems)
        ..where(mediaItems.mediaTypeIdentifier.equals(typeId))
        ..addColumns([cnt]);
      final row = await q.getSingle();
      final count = row.read(cnt)!;
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(mediaItems)
            ..where((t) => t.mediaTypeIdentifier.equals(typeId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(mediaItems)..where((t) => t.id.isIn(oldestIds))).go();
    });
  }

  // ── search history ──────────────────────────────────────────────
  Future<List<SearchHistoryItemRow>> getAllSearchHistoryItems() =>
      select(searchHistoryItems).get();

  Future<void> upsertSearchHistoryItem(SearchHistoryItemsCompanion item) async {
    await into(searchHistoryItems).insert(
      item,
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<int> deleteSearchHistoryByUniqueKey(String uk) =>
      (delete(searchHistoryItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> clearSearchHistory(String historyKey) =>
      (delete(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .go();

  Future<List<SearchHistoryItemRow>> getSearchHistory(String historyKey) =>
      (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .get();

  Future<int> countSearchHistory(String historyKey) async {
    final cnt = countAll();
    final q = selectOnly(searchHistoryItems)
      ..where(searchHistoryItems.historyKey.equals(historyKey))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  Future<SearchHistoryItemRow?> getSearchHistoryByUniqueKey(String uk) =>
      (select(searchHistoryItems)..where((t) => t.uniqueKey.equals(uk)))
          .getSingleOrNull();

  Future<void> trimSearchHistory(String historyKey, int maxItems) async {
    await transaction(() async {
      final count = await countSearchHistory(historyKey);
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(searchHistoryItems)..where((t) => t.id.isIn(oldestIds)))
          .go();
    });
  }

  // ── audiobooks ──────────────────────────────────────────────────
  Future<AudiobookRow?> getAudiobookByBookKey(String bookKey) =>
      (select(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<List<AudiobookRow>> getAllAudiobooks() => select(audiobooks).get();

  Future<void> upsertAudiobook(AudiobooksCompanion ab) =>
      into(audiobooks).insert(ab,
          onConflict: DoUpdate((_) => ab, target: [audiobooks.bookKey]));

  Future<int> deleteAudiobookByBookKey(String bookKey) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        return (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });

  // ── video_books ─────────────────────────────────────────────────
  Future<void> upsertVideoBook(VideoBooksCompanion vb) =>
      into(videoBooks).insert(vb,
          onConflict: DoUpdate((_) => vb, target: [videoBooks.bookUid]));

  Future<VideoBookRow?> getVideoBookByBookUid(String bookUid) =>
      (select(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<List<VideoBookRow>> allVideoBooks() => select(videoBooks).get();

  Future<void> updateVideoBookPosition(String bookUid, int positionMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(lastPositionMs: Value(positionMs)));

  Future<void> updateVideoBookEpisode(String bookUid, int episodeIndex) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(currentEpisode: Value(episodeIndex)));

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updateVideoBookPlaylistJson(
          String bookUid, String playlistJson) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(playlistJson: Value(playlistJson)));

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateVideoBookDelayMs(String bookUid, int delayMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(delayMs: Value(delayMs)));

  /// 更新用户选中的字幕源（外挂存路径；内嵌存 `embedded:<n>`；关闭存 null）。
  Future<void> updateVideoBookSubtitleSource(
          String bookUid, String? subtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(subtitleSource: Value(subtitleSource)));

  /// 更新用户选中的副字幕源（TODO-857）：与 [updateVideoBookSubtitleSource] 同款
  /// 四态编码（外挂路径 / `embedded:<n>` / `off:` / null）。
  Future<void> updateVideoBookSecondarySubtitleSource(
          String bookUid, String? secondarySubtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid))).write(
          VideoBooksCompanion(
              secondarySubtitleSource: Value(secondarySubtitleSource)));

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateVideoBookAudioTrackId(
          String bookUid, String? audioTrackId) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(audioTrackId: Value(audioTrackId)));

  /// 更新视频封面图绝对路径（用户在书架/视频库长按菜单手动设置）。
  Future<void> updateVideoBookCover(String bookUid, String coverPath) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(coverPath: Value(coverPath)));

  /// 更新视频/播放列表标题（用户在视频库长按菜单「重命名」）。title 列已存在，
  /// 无 schema 变更。
  Future<void> updateVideoBookTitle(String bookUid, String title) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(title: Value(title)));

  /// 删除视频书：FK `onDelete: cascade` 自动清掉它在 video_book_tag_mappings 的
  /// 标签映射；audio_cues 的 bookKey 不是外键（它对有声书/SRT/视频共用一个字符串
  /// owner key，无法挂 FK），故必须在同一事务里显式删掉本视频的字幕 cue 行
  /// （BUG-276：否则删视频后 cue 行永久残留，删一本占用却不降）。
  Future<void> deleteVideoBook(String bookUid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookUid))).go();
        await (delete(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
            .go();
      });

  // ── media_sources ───────────────────────────────────────────────
  // TODO-817：网络/本地来源库 CRUD。configJson 绝不裸存明文密码（本地恒 NULL，
  // 网络只存凭据引用键，密码本体 M3 才落）。

  /// 插入一条来源，返回自增 id。
  Future<int> insertMediaSource(MediaSourcesCompanion source) =>
      into(mediaSources).insert(source);

  /// 按 id 幂等 upsert（存在则整行更新）。
  Future<void> upsertMediaSource(MediaSourcesCompanion source) =>
      into(mediaSources).insertOnConflictUpdate(source);

  /// 全部来源，按 sortOrder 升序、id 升序（列表稳定排序）。
  Future<List<MediaSourceRow>> getAllMediaSources() => (select(mediaSources)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 按媒体种类（'video' | 'book'）过滤，仍按 sortOrder、id 升序。
  Future<List<MediaSourceRow>> getMediaSourcesByKind(String mediaKind) =>
      (select(mediaSources)
            ..where((t) => t.mediaKind.equals(mediaKind))
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 按 id 取单条来源（不存在返回 null）。
  Future<MediaSourceRow?> getMediaSourceById(int id) =>
      (select(mediaSources)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 删除来源：依赖 FK onDelete:setNull，归属本来源的 video_books / epub_books
  /// 自动把 source_id 归 NULL（条目保留，不连坐删）。返回删除行数。
  Future<int> deleteMediaSource(int id) =>
      (delete(mediaSources)..where((t) => t.id.equals(id))).go();

  /// 回写一次扫描结果（媒体数 / 时间 / 失败原因）。
  Future<void> updateMediaSourceScanResult({
    required int id,
    required int mediaCount,
    required DateTime lastScannedAt,
    String? lastScanError,
  }) =>
      (update(mediaSources)..where((t) => t.id.equals(id))).write(
        MediaSourcesCompanion(
          mediaCount: Value(mediaCount),
          lastScannedAt: Value(lastScannedAt),
          lastScanError: Value(lastScanError),
        ),
      );

  /// 更新来源显示名。
  Future<void> updateMediaSourceLabel(int id, String label) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(label: Value(label)));

  /// 更新来源排序权重（来源库 UI 拖拽重排后逐行回写，与 [getAllMediaSources] /
  /// [getMediaSourcesByKind] 的 orderBy(sortOrder, id) 对齐）。只写 sortOrder 列，
  /// 不动其它字段。
  Future<void> updateMediaSourceSortOrder(int id, int sortOrder) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(sortOrder: Value(sortOrder)));

  // ── audio cues ──────────────────────────────────────────────────
  // [bookKey] is the owner key: either an audiobook bookKey OR an srt_books.uid
  // (SRT books still key their cues on their own uid string).
  Future<List<AudioCueRow>> getCuesForChapter(
          String bookKey, String chapterHref) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) & t.chapterHref.equals(chapterHref))
            ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
          .get();

  Future<List<AudioCueRow>> getCuesForBook(String bookKey) => (select(audioCues)
        ..where((t) => t.bookKey.equals(bookKey))
        ..orderBy([
          (t) => OrderingTerm.asc(t.audioFileIndex),
          (t) => OrderingTerm.asc(t.startMs),
          (t) => OrderingTerm.asc(t.sentenceIndex),
        ]))
      .get();

  Future<AudioCueRow?> findCue(
          String bookKey, String chapterHref, int sentenceIndex) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) &
                t.chapterHref.equals(chapterHref) &
                t.sentenceIndex.equals(sentenceIndex)))
          .getSingleOrNull();

  Future<void> replaceCuesForBook(
          String bookKey, List<AudioCuesCompanion> cues) =>
      transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await batch((b) {
          for (final c in cues) {
            b.insert(audioCues, c);
          }
        });
      });

  // ── srt books ───────────────────────────────────────────────────
  Future<List<SrtBookRow>> getAllSrtBooks() =>
      (select(srtBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<SrtBookRow?> getSrtBookByUid(String uid) =>
      (select(srtBooks)..where((t) => t.uid.equals(uid))).getSingleOrNull();

  Future<SrtBookRow?> getSrtBookByBookKey(String bookKey) =>
      (select(srtBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> upsertSrtBook(SrtBooksCompanion book) =>
      into(srtBooks).insertOnConflictUpdate(book);

  /// Deletes the SRT book row + its cues. Returns the number of srt_books rows
  /// actually removed (0 when [uid] matched no row) so batch deletion can count
  /// only genuine deletions instead of optimistically assuming success
  /// (BUG-439).
  Future<int> deleteSrtBookByUid(String uid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
        return (delete(srtBooks)..where((t) => t.uid.equals(uid))).go();
      });

  // ── reader positions ────────────────────────────────────────────
  Future<ReaderPositionRow?> getReaderPosition(String bookKey) =>
      (select(readerPositions)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> upsertReaderPosition(ReaderPositionsCompanion pos) =>
      into(readerPositions).insert(
        pos,
        onConflict: DoUpdate(
          (old) => pos,
          target: [readerPositions.bookKey],
        ),
      );

  Future<int> deleteReaderPosition(String bookKey) =>
      (delete(readerPositions)..where((t) => t.bookKey.equals(bookKey))).go();

  // ── reading statistics ──────────────────────────────────────────
  /// OVERWRITE semantics: sets the row for (title, dateKey) to the absolute
  /// values in [stat]. Use this when the caller already holds the final total
  /// (e.g. sync merge). For incremental session deltas use
  /// [addReadingStatistic], which accumulates. Passing a delta here would
  /// silently reset the totals.
  Future<void> setReadingStatistic(ReadingStatisticsCompanion stat) =>
      into(readingStatistics).insert(
        stat,
        onConflict: DoUpdate(
          (old) => ReadingStatisticsCompanion(
            charactersRead: stat.charactersRead,
            readingTimeMs: stat.readingTimeMs,
            lastStatisticModified: stat.lastStatisticModified,
          ),
          target: [readingStatistics.title, readingStatistics.dateKey],
        ),
      );

  /// ACCUMULATE semantics: adds [charsRead]/[timeMs] to the existing totals
  /// for (title, dateKey). Use for reading-session deltas. For setting an
  /// absolute total (e.g. sync merge) use [setReadingStatistic].
  Future<void> addReadingStatistic({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
  }) =>
      transaction(() async {
        final existing = await (select(readingStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingStatisticsCompanion(
            charactersRead: Value(existing.charactersRead + charsRead),
            readingTimeMs: Value(existing.readingTimeMs + timeMs),
            lastStatisticModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(readingStatistics).insert(
            ReadingStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              charactersRead: charsRead,
              readingTimeMs: timeMs,
              lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      });

  Future<List<ReadingStatisticRow>> getAllReadingStatistics() =>
      select(readingStatistics).get();

  // ── reading hourly logs ─────────────────────────────────────────
  Future<void> addHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(readingHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingHourlyLogsCompanion(
            readingTimeMs: Value(existing.readingTimeMs + deltaMs),
          ));
        } else {
          await into(readingHourlyLogs).insert(
            ReadingHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              readingTimeMs: deltaMs,
            ),
          );
        }
      });

  Future<List<ReadingHourlyLogRow>> getHourlyLogsForDate(String dateKey) =>
      (select(readingHourlyLogs)..where((t) => t.dateKey.equals(dateKey)))
          .get();

  // ── video watch statistics ──────────────────────────────────────
  /// ACCUMULATE：把 [subtitleChars]/[watchTimeMs] 累加到 (title, dateKey) 现有
  /// 总量。对照 [addReadingStatistic]，但视频专用、与阅读统计隔离。
  Future<void> addVideoWatchStatistic({
    required String title,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoWatchStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoWatchStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoWatchStatisticsCompanion(
            subtitleChars: Value(existing.subtitleChars + subtitleChars),
            watchTimeMs: Value(existing.watchTimeMs + watchTimeMs),
            lastModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(videoWatchStatistics).insert(
            VideoWatchStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              subtitleChars: subtitleChars,
              watchTimeMs: watchTimeMs,
              lastModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      });

  Future<List<VideoWatchStatisticRow>> getAllVideoWatchStatistics() =>
      select(videoWatchStatistics).get();

  // ── video hourly logs ───────────────────────────────────────────
  Future<void> addVideoHourlyWatchTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoHourlyLogsCompanion(
            watchTimeMs: Value(existing.watchTimeMs + deltaMs),
          ));
        } else {
          await into(videoHourlyLogs).insert(
            VideoHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              watchTimeMs: deltaMs,
            ),
          );
        }
      });

  Future<List<VideoHourlyLogRow>> getVideoHourlyLogsForDate(String dateKey) =>
      (select(videoHourlyLogs)..where((t) => t.dateKey.equals(dateKey))).get();

  /// 仅当当前 completed_at 为 null 时写入（幂等首次完成；重看不覆盖）。
  Future<void> markVideoCompleted(String bookUid, DateTime completedAt) =>
      (update(videoBooks)
            ..where((t) => t.bookUid.equals(bookUid) & t.completedAt.isNull()))
          .write(VideoBooksCompanion(completedAt: Value(completedAt)));

  // ── favorite words ──────────────────────────────────────────────
  /// 收藏一个词条（幂等：(expression, reading, sourceType) 已存在则跳过）。
  /// 返回 true 表示这次新增了收藏，false 表示已收藏过。
  Future<bool> addFavoriteWord({
    required String expression,
    required String reading,
    required String glossary,
    required String sourceType,
    required String dateKey,
  }) =>
      transaction(() async {
        final existing = await (select(favoriteWords)
              ..where((t) =>
                  t.expression.equals(expression) &
                  t.reading.equals(reading) &
                  t.sourceType.equals(sourceType)))
            .getSingleOrNull();
        if (existing != null) return false;
        await into(favoriteWords).insert(
          FavoriteWordsCompanion.insert(
            expression: expression,
            reading: Value(reading),
            glossary: Value(glossary),
            sourceType: sourceType,
            dateKey: dateKey,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return true;
      });

  /// 取消收藏（按 (expression, reading, sourceType) 删除）。返回删除的行数。
  Future<int> removeFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
  }) =>
      (delete(favoriteWords)
            ..where((t) =>
                t.expression.equals(expression) &
                t.reading.equals(reading) &
                t.sourceType.equals(sourceType)))
          .go();

  Future<bool> isFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
  }) async {
    final row = await (select(favoriteWords)
          ..where((t) =>
              t.expression.equals(expression) &
              t.reading.equals(reading) &
              t.sourceType.equals(sourceType)))
        .getSingleOrNull();
    return row != null;
  }

  /// 取某来源（'book' / 'video'）的全部收藏行，供统计页按 dateKey 分桶计数。
  Future<List<FavoriteWordRow>> getFavoriteWordsBySource(String sourceType) =>
      (select(favoriteWords)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 取全部收藏词，按 createdAt 倒序（最近在前），供收藏夹导出（TODO-829）。
  /// 纯 select，不动 schema。
  Future<List<FavoriteWordRow>> getAllFavoriteWords() =>
      (select(favoriteWords)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  // ── mining statistics ───────────────────────────────────────────
  /// 制卡成功计数 +[delta]：累加到 (sourceType, dateKey) 现有计数。
  Future<void> addMiningCount({
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(miningStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(MiningStatisticsCompanion(
            count: Value(existing.count + delta),
          ));
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(delta),
            ),
          );
        }
      });

  /// MAX-union semantics: sets the (sourceType, dateKey) bucket to
  /// `max(existing, count)` rather than accumulating. Use this for backup-merge
  /// import — accumulating with [addMiningCount] would double-count on a
  /// re-import of the same backup, breaking the "merge is idempotent" invariant
  /// (mirrors [setReadingStatistic]'s absolute / `mergeStatistics` max
  /// semantics).
  Future<void> setMiningCount({
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          if (count > existing.count) {
            await (update(miningStatistics)
                  ..where((t) => t.id.equals(existing.id)))
                .write(MiningStatisticsCompanion(count: Value(count)));
          }
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(count),
            ),
          );
        }
      });

  /// 取某来源（'book' / 'video'）的全部制卡计数行，供统计页按 dateKey 分桶。
  Future<List<MiningStatisticRow>> getMiningStatisticsBySource(
          String sourceType) =>
      (select(miningStatistics)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  // ── mined sentences ──────────────────────────────────────────────
  /// 上限：保留最近 [kMinedSentenceHistoryLimit] 条制卡历史，避免无限增长。
  static const int kMinedSentenceHistoryLimit = 1000;

  /// 记录一次成功制卡：插入一条历史，并在事务内 trim 掉超额的最旧行。
  /// 定位列（[bookKey]/[sectionIndex]/[normCharOffset]/[normCharLength]）按来源可空——
  /// 独立查词页 / 首页词典制卡无书无章，传 null（展示为不可跳转条目）。
  Future<void> addMinedSentence({
    required String source,
    required String dateKey,
    String expression = '',
    String reading = '',
    String glossary = '',
    String sentence = '',
    String? documentTitle,
    String? chapterLabel,
    String? bookKey,
    int? sectionIndex,
    int? normCharOffset,
    int? normCharLength,
    int? noteId,
  }) =>
      transaction(() async {
        await into(minedSentences).insert(
          MinedSentencesCompanion.insert(
            source: source,
            dateKey: dateKey,
            expression: Value(expression),
            reading: Value(reading),
            glossary: Value(glossary),
            sentence: Value(sentence),
            documentTitle: Value(documentTitle),
            chapterLabel: Value(chapterLabel),
            bookKey: Value(bookKey),
            sectionIndex: Value(sectionIndex),
            normCharOffset: Value(normCharOffset),
            normCharLength: Value(normCharLength),
            noteId: Value(noteId),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _trimMinedSentences();
      });

  /// 取全部制卡历史，按 createdAt 倒序（最近在前），供收藏夹页展示。
  Future<List<MinedSentenceRow>> getAllMinedSentences() =>
      (select(minedSentences)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  /// 删除一条制卡历史（按 id）。返回删除的行数。
  Future<int> removeMinedSentence(int id) =>
      (delete(minedSentences)..where((t) => t.id.equals(id))).go();

  /// 清空全部制卡历史。返回删除的行数。
  Future<int> clearMinedSentences() => delete(minedSentences).go();

  /// 事务内 trim：超过 [kMinedSentenceHistoryLimit] 时按 id 升序删除最旧的超额行。
  Future<void> _trimMinedSentences() async {
    final int total = await minedSentences.count().getSingle();
    final int excess = total - kMinedSentenceHistoryLimit;
    if (excess <= 0) return;
    final List<MinedSentenceRow> oldest = await (select(minedSentences)
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(excess))
        .get();
    final List<int> ids = oldest.map((r) => r.id).toList(growable: false);
    if (ids.isEmpty) return;
    await (delete(minedSentences)..where((t) => t.id.isIn(ids))).go();
  }

  // ── dictionary metadata ─────────────────────────────────────────
  Future<List<DictionaryMetaRow>> getAllDictionaryMetadata() =>
      select(dictionaryMetadata).get();

  Future<void> upsertDictionaryMeta(DictionaryMetadataCompanion meta) =>
      into(dictionaryMetadata).insertOnConflictUpdate(meta);

  Future<int> deleteDictionaryMeta(String name) =>
      (delete(dictionaryMetadata)..where((t) => t.name.equals(name))).go();

  Future<int> clearAllDictionaryMeta() => delete(dictionaryMetadata).go();

  // ── dictionary history ──────────────────────────────────────────
  Future<List<DictionaryHistoryRow>> getAllDictionaryHistory() =>
      (select(dictionaryHistory)
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Future<void> replaceAllDictionaryHistory(
          List<DictionaryHistoryCompanion> items) =>
      transaction(() async {
        await delete(dictionaryHistory).go();
        await batch((b) {
          for (final item in items) {
            b.insert(dictionaryHistory, item);
          }
        });
      });

  Future<int> clearDictionaryHistory() => delete(dictionaryHistory).go();

  // ── epub books ──────────────────────────────────────────────────
  Future<List<EpubBookRow>> getAllEpubBooks() =>
      (select(epubBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<EpubBookRow?> getEpubBook(String bookKey) =>
      (select(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  /// Inserts a book; returns its bookKey (the primary key) on success.
  Future<String> insertEpubBook(EpubBooksCompanion book) async {
    await into(epubBooks).insert(book);
    return book.bookKey.value;
  }

  Future<void> insertEpubBookOrIgnore(EpubBooksCompanion book) =>
      into(epubBooks).insert(book, mode: InsertMode.insertOrIgnore);

  /// Renaming a book changes its primary key (bookKey = sanitized title) and
  /// therefore would orphan every related row keyed by the old bookKey. A safe
  /// rename must cascade the new key across all relation tables + prefs, which
  /// is intentionally NOT supported in this phase. Disable in-book rename until
  /// the cascading-rename task lands.
  Future<void> updateEpubBookTitle(String bookKey, String title) {
    throw UnsupportedError(
      'In-book rename changes the primary key (bookKey = sanitized title); '
      'a cascading re-key of all related reading data is required and is '
      'deferred to a later phase. See book-identity-name-key plan.',
    );
  }

  Future<void> updateEpubBookPath(String bookKey, String epubPath) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(epubPath: Value(epubPath)));

  /// Update a book's author (BUG-220). Unlike [updateEpubBookTitle], the author
  /// column is NOT the primary key (bookKey = sanitized title), so this is a
  /// plain UPDATE with no cascading re-key. Pass a blank/empty [author] to clear
  /// it (stored as NULL) so the detail dialog hides the author line.
  Future<void> updateEpubBookAuthor(String bookKey, String? author) {
    final String? trimmed = author?.trim();
    final String? value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(author: Value(value)));
  }

  /// Rewrites a book's on-disk content paths (full-data backup restore rebases
  /// absolute paths to this device's roots). Only supplied fields are written;
  /// null leaves a column unchanged.
  Future<void> updateEpubBookContentPaths(
    String bookKey, {
    String? epubPath,
    String? extractDir,
    String? coverPath,
  }) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(
          epubPath: epubPath == null ? const Value.absent() : Value(epubPath),
          extractDir:
              extractDir == null ? const Value.absent() : Value(extractDir),
          coverPath:
              coverPath == null ? const Value.absent() : Value(coverPath),
        ),
      );

  /// Rewrites an audiobook's on-disk paths (full-data backup restore). Only
  /// supplied fields are written. `alignmentPath` is non-null in the schema, so
  /// callers that rebase it always pass a value.
  Future<void> updateAudiobookPaths(
    String bookKey, {
    String? audioRoot,
    String? audioPathsJson,
    String? alignmentPath,
  }) =>
      (update(audiobooks)..where((t) => t.bookKey.equals(bookKey))).write(
        AudiobooksCompanion(
          audioRoot:
              audioRoot == null ? const Value.absent() : Value(audioRoot),
          audioPathsJson: audioPathsJson == null
              ? const Value.absent()
              : Value(audioPathsJson),
          alignmentPath: alignmentPath == null
              ? const Value.absent()
              : Value(alignmentPath),
        ),
      );

  Future<int> deleteEpubBook(String bookKey) => transaction(() async {
        await (delete(readerPositions)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        // bookmarks / book_tag_mappings declare ON DELETE CASCADE on
        // epub_books(bookKey), but we delete them explicitly rather than rely on
        // the cascade: this stays correct regardless of the runtime
        // foreign_keys pragma state and documents the full set of dependent
        // rows in one place.
        await (delete(bookmarks)..where((t) => t.bookKey.equals(bookKey))).go();
        // SRT books linked to this epub key their cues on srt_books.uid, NOT
        // the epub bookKey, so delete those cues before dropping the srt rows.
        // (HBK-AUDIT-041 follow-up: deleteEpubBook owns the full cascade; the
        // reader source no longer deletes these rows itself.)
        final List<String> srtUids = await (selectOnly(srtBooks)
              ..addColumns([srtBooks.uid])
              ..where(srtBooks.bookKey.equals(bookKey)))
            .map((r) => r.read(srtBooks.uid)!)
            .get();
        for (final String uid in srtUids) {
          await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
        }
        await (delete(srtBooks)..where((t) => t.bookKey.equals(bookKey))).go();
        // Audiobook + its cues are keyed directly by bookKey now.
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        return (delete(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });

  // ── book tags ───────────────────────────────────────────────────
  Future<List<BookTagRow>> getAllTags() => (select(bookTags)
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
      .get();

  Future<List<BookTagRow>> getTagsForBook(String bookKey) {
    final query = select(bookTags).join([
      innerJoin(
        bookTagMappings,
        bookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(bookTagMappings.bookKey.equals(bookKey))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<Set<String>> getBookKeysForAnyTag(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final query = selectOnly(bookTagMappings)
      ..addColumns([bookTagMappings.bookKey])
      ..where(bookTagMappings.tagId.isIn(tagIds));
    final rows = await query.get();
    return rows.map((row) => row.read(bookTagMappings.bookKey)!).toSet();
  }

  Future<int> createTag(String name, int colorValue) async {
    final maxQuery = selectOnly(bookTags)
      ..addColumns([bookTags.sortOrder.max()]);
    final maxRow = await maxQuery.getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    return into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: Value(colorValue),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> updateTag(int id, {String? name, int? colorValue}) =>
      (update(bookTags)..where((t) => t.id.equals(id))).write(
        BookTagsCompanion(
          name: name != null ? Value(name) : const Value.absent(),
          colorValue:
              colorValue != null ? Value(colorValue) : const Value.absent(),
        ),
      );

  Future<int> deleteTag(int id) =>
      (delete(bookTags)..where((t) => t.id.equals(id))).go();

  Future<void> setTagsForBook(String bookKey, Set<int> tagIds) =>
      transaction(() async {
        final existing = await (select(bookTagMappings)
              ..where((t) => t.bookKey.equals(bookKey)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          await (delete(bookTagMappings)
                ..where(
                    (t) => t.bookKey.equals(bookKey) & t.tagId.equals(tagId)))
              .go();
        }
        for (final tagId in toAdd) {
          await into(bookTagMappings).insert(
            BookTagMappingsCompanion.insert(
              bookKey: bookKey,
              tagId: tagId,
            ),
          );
        }
      });

  Future<void> addTagToBook(String bookKey, int tagId) =>
      into(bookTagMappings).insert(
        BookTagMappingsCompanion.insert(bookKey: bookKey, tagId: tagId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeTagFromBook(String bookKey, int tagId) =>
      (delete(bookTagMappings)
            ..where((t) => t.bookKey.equals(bookKey) & t.tagId.equals(tagId)))
          .go();

  Future<Set<String>> getBookKeysForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT book_key FROM book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY book_key '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<String>('book_key')).toSet();
  }

  Future<List<BookTagMappingRow>> getAllBookTagMappings() =>
      select(bookTagMappings).get();

  Future<void> reorderTags(List<int> orderedTagIds) => transaction(() async {
        for (int i = 0; i < orderedTagIds.length; i++) {
          await (update(bookTags)..where((t) => t.id.equals(orderedTagIds[i])))
              .write(BookTagsCompanion(sortOrder: Value(i)));
        }
      });

  Future<int> countBooksForTag(int tagId) async {
    final cnt = countAll();
    final q = selectOnly(bookTagMappings)
      ..where(bookTagMappings.tagId.equals(tagId))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── srt book tags ───────────────────────────────────────────────

  Future<List<BookTagRow>> getTagsForSrtBook(int srtBookId) {
    final query = select(bookTags).join([
      innerJoin(
        srtBookTagMappings,
        srtBookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(srtBookTagMappings.srtBookId.equals(srtBookId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<void> addTagToSrtBook(int srtBookId, int tagId) =>
      into(srtBookTagMappings).insert(
        SrtBookTagMappingsCompanion.insert(srtBookId: srtBookId, tagId: tagId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeTagFromSrtBook(int srtBookId, int tagId) => (delete(
          srtBookTagMappings)
        ..where((t) => t.srtBookId.equals(srtBookId) & t.tagId.equals(tagId)))
      .go();

  Future<void> setTagsForSrtBook(int srtBookId, Set<int> tagIds) =>
      transaction(() async {
        final existing = await (select(srtBookTagMappings)
              ..where((t) => t.srtBookId.equals(srtBookId)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          await (delete(srtBookTagMappings)
                ..where((t) =>
                    t.srtBookId.equals(srtBookId) & t.tagId.equals(tagId)))
              .go();
        }
        for (final tagId in toAdd) {
          await into(srtBookTagMappings).insert(
            SrtBookTagMappingsCompanion.insert(
              srtBookId: srtBookId,
              tagId: tagId,
            ),
          );
        }
      });

  Future<List<SrtBookTagMappingRow>> getAllSrtBookTagMappings() =>
      select(srtBookTagMappings).get();

  Future<Set<int>> getSrtBookIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT srt_book_id FROM srt_book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY srt_book_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<int>('srt_book_id')).toSet();
  }

  // ── video book tags ─────────────────────────────────────────────
  // 视频书复用共享 BookTags 标签池，映射经 video_book_tag_mappings。
  // 全套镜像 SRT 标签 API，键从 srtBookId(int) 换成 videoBookUid(String)。

  Future<List<BookTagRow>> getTagsForVideoBook(String videoBookUid) {
    final query = select(bookTags).join([
      innerJoin(
        videoBookTagMappings,
        videoBookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(videoBookTagMappings.videoBookUid.equals(videoBookUid))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<void> addTagToVideoBook(String videoBookUid, int tagId) =>
      into(videoBookTagMappings).insert(
        VideoBookTagMappingsCompanion.insert(
          videoBookUid: videoBookUid,
          tagId: tagId,
        ),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeTagFromVideoBook(String videoBookUid, int tagId) =>
      (delete(videoBookTagMappings)
            ..where((t) =>
                t.videoBookUid.equals(videoBookUid) & t.tagId.equals(tagId)))
          .go();

  Future<void> setTagsForVideoBook(String videoBookUid, Set<int> tagIds) =>
      transaction(() async {
        final existing = await (select(videoBookTagMappings)
              ..where((t) => t.videoBookUid.equals(videoBookUid)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          await (delete(videoBookTagMappings)
                ..where((t) =>
                    t.videoBookUid.equals(videoBookUid) &
                    t.tagId.equals(tagId)))
              .go();
        }
        for (final tagId in toAdd) {
          await into(videoBookTagMappings).insert(
            VideoBookTagMappingsCompanion.insert(
              videoBookUid: videoBookUid,
              tagId: tagId,
            ),
          );
        }
      });

  Future<List<VideoBookTagMappingRow>> getAllVideoBookTagMappings() =>
      select(videoBookTagMappings).get();

  Future<Set<String>> getVideoBookUidsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT video_book_uid FROM video_book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY video_book_uid '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<String>('video_book_uid')).toSet();
  }

  // ── profiles ──────────────────────────────────────────────────────
  Future<List<ProfileRow>> getAllProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<ProfileRow?> getProfileById(int id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertProfile(ProfilesCompanion p) => into(profiles).insert(p);

  Future<void> updateProfileName(int id, String name) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> deleteProfile(int id) =>
      (delete(profiles)..where((t) => t.id.equals(id))).go();

  Future<int> countProfiles() async {
    final cnt = countAll();
    final q = selectOnly(profiles)..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── profile settings ─────────────────────────────────────────────
  Future<List<ProfileSettingRow>> getProfileSettings(int profileId) =>
      (select(profileSettings)..where((t) => t.profileId.equals(profileId)))
          .get();

  Future<void> upsertProfileSetting(ProfileSettingsCompanion s) =>
      into(profileSettings).insert(
        s,
        onConflict: DoUpdate(
          (old) => ProfileSettingsCompanion(value: s.value),
          target: [
            profileSettings.profileId,
            profileSettings.category,
            profileSettings.key,
          ],
        ),
      );

  Future<void> replaceProfileSettings(
          int profileId, List<ProfileSettingsCompanion> settings) =>
      transaction(() async {
        await (delete(profileSettings)
              ..where((t) => t.profileId.equals(profileId)))
            .go();
        await batch((b) {
          for (final s in settings) {
            b.insert(profileSettings, s);
          }
        });
      });

  // ── media type profiles ──────────────────────────────────────────
  Future<List<MediaTypeProfileRow>> getAllMediaTypeProfiles() =>
      select(mediaTypeProfiles).get();

  Future<MediaTypeProfileRow?> getMediaTypeProfile(String mediaType) =>
      (select(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .getSingleOrNull();

  Future<void> setMediaTypeProfile(String mediaType, int profileId) =>
      into(mediaTypeProfiles).insertOnConflictUpdate(
        MediaTypeProfilesCompanion.insert(
          mediaType: mediaType,
          profileId: profileId,
        ),
      );

  Future<int> deleteMediaTypeProfile(String mediaType) =>
      (delete(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .go();

  // ── book profiles ────────────────────────────────────────────────
  Future<BookProfileRow?> getBookProfile(String bookKey) =>
      (select(bookProfiles)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> setBookProfile(String bookKey, int profileId) =>
      into(bookProfiles).insertOnConflictUpdate(
        BookProfilesCompanion.insert(
          bookKey: bookKey,
          profileId: profileId,
        ),
      );

  Future<int> deleteBookProfile(String bookKey) =>
      (delete(bookProfiles)..where((t) => t.bookKey.equals(bookKey))).go();

  // ── sync baselines ──────────────────────────────────────────────
  /// 读某资产某维度的基线版本；无记录返回 null。
  Future<int?> getSyncBaseline(String assetKey, String dimension) async {
    final SyncBaselineRow? row = await (select(syncBaselines)
          ..where((t) =>
              t.assetKey.equals(assetKey) & t.dimension.equals(dimension)))
        .getSingleOrNull();
    return row?.baseVersion;
  }

  /// 写/更新基线版本（主键 assetKey+dimension upsert）。
  Future<void> setSyncBaseline(
    String assetKey,
    String dimension,
    int baseVersion,
  ) =>
      into(syncBaselines).insertOnConflictUpdate(SyncBaselinesCompanion(
        assetKey: Value(assetKey),
        dimension: Value(dimension),
        baseVersion: Value(baseVersion),
      ));

  /// 删某资产所有维度基线（删书时 GC，可选调用）。
  Future<void> deleteSyncBaselines(String assetKey) =>
      (delete(syncBaselines)..where((t) => t.assetKey.equals(assetKey))).go();

  // ── v16 book-key migration ──────────────────────────────────────
  // Legacy uid prefix that wrapped the int book id in audiobooks/audio_cues/
  // book_profiles and in the uid-style audiobook_pos_ prefs. Single literal so
  // the migration's int-extraction matches what buildLegacyBookUid produced.
  static const String _kLegacyUidPrefix = 'reader_ttu/hoshi://book/';

  /// VERBATIM copy of `sanitizeTtuFilename` from
  /// hibiki/lib/src/sync/ttu_filename.dart. hibiki_core cannot depend on the
  /// app package, so the body is inlined here. Both MUST stay byte-identical:
  /// the migrated bookKey has to equal the key sync/folder code derives from
  /// the same title, or cross-device identity drifts. A source guard
  /// (book_key_guard_test) locks the two bodies together.
  static String _sanitizeBookKey(String title) {
    String result = title;
    if (result.endsWith(' ')) {
      result = '${result.substring(0, result.length - 1)}~ttu-spc~';
    }
    if (result.endsWith('.')) {
      result = '${result.substring(0, result.length - 1)}~ttu-dend~';
    }
    result = result.replaceAll('*', '~ttu-star~');
    result = result.replaceAllMapped(
      RegExp(r'[/?\<>\\:|%"]'),
      (match) => match[0]!
          .codeUnits
          .map((c) => '%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}')
          .join(),
    );
    return result;
  }

  /// Re-keys every book + all reading data from the autoincrement int id to
  /// bookKey = sanitizeTtuFilename(title). Lossless: builds an id→key map (with
  /// dedup), then rebuilds each table by JOINing through that map.
  ///
  /// Atomicity is the iron rule here — this rewrites user data. drift does NOT
  /// wrap onUpgrade in a transaction by default, so the whole migration body
  /// runs inside an EXPLICIT `transaction()`: it either fully commits or fully
  /// rolls back, leaving user_version at 15 for a safe retry on next launch.
  /// `PRAGMA foreign_keys` is a no-op inside a transaction (SQLite rule), so the
  /// OFF/ON toggles sit OUTSIDE `transaction()`, per drift's "migrations and
  /// foreign keys" guidance. A `foreign_key_check` at the end aborts (rolls
  /// back) the whole migration if any FK relation was left dangling.
  Future<void> _migrateBookKeyV16(Migrator m) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        await _runBookKeyMigrationBodyV16();
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// The full v16 re-key work, run inside the explicit transaction opened by
  /// [_migrateBookKeyV16]. Extracted so the transaction boundary and the
  /// foreign_keys OFF/ON toggles (which must stay outside any transaction) read
  /// cleanly. Throwing anywhere here rolls back the entire migration.
  Future<void> _runBookKeyMigrationBodyV16() async {
    {
      // Guard: only run the re-key when epub_books still carries the legacy
      // autoincrement `id` column. A DB reaching this step with epub_books
      // already created fresh under the v16 generated schema (its PK is
      // `book_key`, no `id`) — e.g. a pre-v5 DB whose from<5 ladder step ran
      // m.createTable(epubBooks) — is already on the target shape, so the whole
      // re-key is a no-op. This also covers synthetic/partial seeds with no
      // epub_books at all (_columnExists implies the table exists). A genuine
      // pre-v16 DB has the int `id` column, so real upgrades still migrate.
      if (!await _columnExists('epub_books', 'id')) {
        return;
      }

      // 1. Read (id, title); compute key + dedup collisions deterministically.
      final List<QueryRow> books =
          await customSelect('SELECT id, title FROM epub_books ORDER BY id')
              .get();
      final Map<int, String> idToKey = <int, String>{};
      final Set<String> used = <String>{};
      for (final QueryRow r in books) {
        final int id = r.read<int>('id');
        String key = _sanitizeBookKey(r.read<String>('title'));
        if (used.contains(key)) {
          for (int i = 2;; i++) {
            final String candidate = '$key ($i)';
            if (!used.contains(candidate)) {
              key = candidate;
              break;
            }
          }
        }
        used.add(key);
        idToKey[id] = key;
      }

      // 2. Temp map table (old_id -> book_key).
      await customStatement('DROP TABLE IF EXISTS _id_key_map');
      await customStatement(
          'CREATE TABLE _id_key_map (old_id INTEGER PRIMARY KEY, book_key TEXT NOT NULL)');
      for (final MapEntry<int, String> e in idToKey.entries) {
        await customStatement(
            'INSERT INTO _id_key_map (old_id, book_key) VALUES (?, ?)',
            <Object?>[e.key, e.value]);
      }

      // 3. epub_books: id PK -> book_key PK.
      await customStatement('''
        CREATE TABLE epub_books_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          cover_path TEXT,
          epub_path TEXT NOT NULL,
          extract_dir TEXT NOT NULL,
          chapter_count INTEGER NOT NULL,
          chapters_json TEXT NOT NULL,
          toc_json TEXT,
          source_metadata TEXT,
          imported_at INTEGER NOT NULL)''');
      await customStatement('''
        INSERT INTO epub_books_new
        SELECT m.book_key, b.title, b.author, b.cover_path, b.epub_path,
               b.extract_dir, b.chapter_count, b.chapters_json, b.toc_json,
               b.source_metadata, b.imported_at
        FROM epub_books b JOIN _id_key_map m ON m.old_id = b.id''');
      await customStatement('DROP TABLE epub_books');
      await customStatement('ALTER TABLE epub_books_new RENAME TO epub_books');

      // Each relation table is rebuilt ONLY if it still carries its legacy
      // int/uid column. A DB that reached this step with a table already
      // created fresh under the current v16 generated schema (e.g. a pre-v11 DB
      // whose from<11 ladder step ran m.createTable) already has `book_key` and
      // must be left untouched — rebuilding it would JOIN on a non-existent
      // legacy column. Synthetic/partial seeds that lack the table entirely are
      // likewise skipped (column check implies table check).

      // 4. reader_positions: ttu_book_id INT UNIQUE -> book_key TEXT UNIQUE.
      if (await _columnExists('reader_positions', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE reader_positions_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          ttu_char_offset INTEGER NOT NULL DEFAULT -1,
          updated_at INTEGER NOT NULL)''');
        await customStatement('''
        INSERT INTO reader_positions_new
          (book_key, section_index, norm_char_offset, ttu_char_offset, updated_at)
        SELECT m.book_key, rp.section_index, rp.norm_char_offset,
               rp.ttu_char_offset, rp.updated_at
        FROM reader_positions rp JOIN _id_key_map m ON m.old_id = rp.ttu_book_id''');
        await customStatement('DROP TABLE reader_positions');
        await customStatement(
            'ALTER TABLE reader_positions_new RENAME TO reader_positions');
      }

      // 5. bookmarks: ttu_book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('bookmarks', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE bookmarks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          label TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          book_title TEXT,
          page_in_chapter INTEGER,
          total_pages_in_chapter INTEGER)''');
        await customStatement('''
        INSERT INTO bookmarks_new
          (id, book_key, section_index, norm_char_offset, label, created_at,
           book_title, page_in_chapter, total_pages_in_chapter)
        SELECT bm.id, m.book_key, bm.section_index, bm.norm_char_offset,
               bm.label, bm.created_at, bm.book_title, bm.page_in_chapter,
               bm.total_pages_in_chapter
        FROM bookmarks bm JOIN _id_key_map m ON m.old_id = bm.ttu_book_id''');
        await customStatement('DROP TABLE bookmarks');
        await customStatement('ALTER TABLE bookmarks_new RENAME TO bookmarks');
      }

      // 6. book_tag_mappings: book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('book_tag_mappings', 'book_id')) {
        await customStatement('''
        CREATE TABLE book_tag_mappings_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
          UNIQUE (book_key, tag_id))''');
        await customStatement('''
        INSERT INTO book_tag_mappings_new (id, book_key, tag_id)
        SELECT btm.id, m.book_key, btm.tag_id
        FROM book_tag_mappings btm JOIN _id_key_map m ON m.old_id = btm.book_id''');
        await customStatement('DROP TABLE book_tag_mappings');
        await customStatement(
            'ALTER TABLE book_tag_mappings_new RENAME TO book_tag_mappings');
      }

      // 7. srt_books: ttu_book_id INT (0 = standalone) -> book_key TEXT ('').
      //    LEFT JOIN so standalone rows (no mapped epub) keep '' sentinel.
      if (await _columnExists('srt_books', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE srt_books_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          uid TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          author TEXT,
          audio_root TEXT,
          audio_paths_json TEXT,
          srt_path TEXT NOT NULL,
          cover_path TEXT,
          imported_at INTEGER NOT NULL,
          book_key TEXT NOT NULL DEFAULT '')''');
        await customStatement('''
        INSERT INTO srt_books_new
          (id, uid, title, author, audio_root, audio_paths_json, srt_path,
           cover_path, imported_at, book_key)
        SELECT sb.id, sb.uid, sb.title, sb.author, sb.audio_root,
               sb.audio_paths_json, sb.srt_path, sb.cover_path, sb.imported_at,
               COALESCE(m.book_key, '')
        FROM srt_books sb LEFT JOIN _id_key_map m ON m.old_id = sb.ttu_book_id''');
        await customStatement('DROP TABLE srt_books');
        await customStatement('ALTER TABLE srt_books_new RENAME TO srt_books');
      }

      // 8. audiobooks: book_uid 'reader_ttu/hoshi://book/<id>' -> book_key.
      //    Extract <id>, JOIN map. Rows whose uid doesn't map are dropped
      //    (orphan audiobooks — their epub is gone; v12 already pruned cues).
      if (await _columnExists('audiobooks', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audiobooks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          audio_root TEXT,
          audio_paths_json TEXT,
          alignment_format TEXT NOT NULL,
          alignment_path TEXT NOT NULL,
          health_kind_raw TEXT,
          match_rate_pct INTEGER,
          health_measured_at INTEGER,
          health_reason TEXT,
          follow_audio INTEGER)''');
        await customStatement('''
        INSERT INTO audiobooks_new
          (id, book_key, audio_root, audio_paths_json, alignment_format,
           alignment_path, health_kind_raw, match_rate_pct, health_measured_at,
           health_reason, follow_audio)
        SELECT ab.id, m.book_key, ab.audio_root, ab.audio_paths_json,
               ab.alignment_format, ab.alignment_path, ab.health_kind_raw,
               ab.match_rate_pct, ab.health_measured_at, ab.health_reason,
               ab.follow_audio
        FROM audiobooks ab
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ab.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ab.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audiobooks');
        await customStatement(
            'ALTER TABLE audiobooks_new RENAME TO audiobooks');
      }

      // 9. audio_cues: book_uid owns EITHER an audiobook uid OR an srt_books.uid.
      //    Rename column to book_key; translate ONLY the audiobook-uid rows
      //    ('reader_ttu/hoshi://book/<id>'), leaving srt uids untouched. Drop
      //    audiobook-uid cues whose id no longer maps (orphans).
      if (await _columnExists('audio_cues', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audio_cues_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL,
          chapter_href TEXT NOT NULL,
          sentence_index INTEGER NOT NULL,
          text_fragment_id TEXT NOT NULL,
          cue_text TEXT NOT NULL,
          start_ms INTEGER NOT NULL,
          end_ms INTEGER NOT NULL,
          audio_file_index INTEGER NOT NULL)''');
        // 9a. non-audiobook-uid cues (srt-owned) carried over verbatim.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, ac.book_uid, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        WHERE ac.book_uid NOT LIKE '$_kLegacyUidPrefix%' ''');
        // 9b. audiobook-uid cues translated through the map.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, m.book_key, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ac.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ac.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audio_cues');
        await customStatement(
            'ALTER TABLE audio_cues_new RENAME TO audio_cues');
      }

      // 10. book_profiles: book_uid PK 'reader_ttu/hoshi://book/<id>' -> book_key.
      if (await _columnExists('book_profiles', 'book_uid')) {
        await customStatement('''
        CREATE TABLE book_profiles_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE)''');
        await customStatement('''
        INSERT INTO book_profiles_new (book_key, profile_id)
        SELECT m.book_key, bp.profile_id
        FROM book_profiles bp
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(bp.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE bp.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE book_profiles');
        await customStatement(
            'ALTER TABLE book_profiles_new RENAME TO book_profiles');
      }

      // 11. media_items identifier/unique_key: hoshi://book/<id> -> /<key>.
      // media_items is a v1 baseline table (created only in onCreate), so a
      // synthetic/partial legacy seed that starts mid-ladder may lack it.
      const String kIdentPrefix = 'hoshi://book/';
      final List<QueryRow> items = await _tableExists('media_items')
          ? await customSelect(
              "SELECT id, media_identifier, unique_key FROM media_items "
              "WHERE media_identifier LIKE 'hoshi://book/%'",
            ).get()
          : const <QueryRow>[];
      for (final QueryRow it in items) {
        final String mid = it.read<String>('media_identifier');
        final int? oldId = int.tryParse(mid.substring(kIdentPrefix.length));
        final String? key = oldId == null ? null : idToKey[oldId];
        if (key == null) continue;
        await customStatement(
          'UPDATE media_items SET media_identifier = ?, unique_key = ? '
          'WHERE id = ?',
          <Object?>[
            '$kIdentPrefix$key',
            '$kIdentPrefix$key',
            it.read<int>('id'),
          ],
        );
      }

      // 12. preferences re-key (two audiobook_pos key spaces merge to one).
      await _migrateBookKeyPrefsV16(idToKey);

      // 13. reading_statistics: align bare title -> sanitized key, merging
      //     rows that collapse to the same (title, date_key).
      await _migrateReadingStatsTitlesV16();

      // 14. Recreate indexes under the new book_key column names.
      await _ensureIndexes();

      await customStatement('DROP TABLE _id_key_map');

      // 15. Integrity gate: any dangling FK relation means the re-key was
      //     lossy/wrong. Throw to roll back the whole transaction (FK checks
      //     are deferred while foreign_keys=OFF, so this runs them explicitly).
      final List<QueryRow> violations =
          await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError(
            'book-key migration left FK violations: ${violations.length}');
      }
    }
  }

  /// Re-keys all per-book preferences from int id / legacy uid to bookKey.
  /// The two audiobook_pos_ key spaces (int-style from SyncRepository and
  /// uid-style from AudiobookRepository's realtime writes) merge; on conflict
  /// the uid-style value wins (it is the live player write).
  Future<void> _migrateBookKeyPrefsV16(Map<int, String> idToKey) async {
    if (!await _tableExists('preferences')) return;
    final List<QueryRow> rows =
        await customSelect('SELECT key, value FROM preferences').get();

    // Resolved new key -> value, with a priority flag so uid-style audiobook_pos
    // wins over int-style on collision.
    final Map<String, String> resolved = <String, String>{};
    final Set<String> uidWonPos = <String>{};
    final Set<String> oldKeysToDelete = <String>{};

    // Prefixes whose suffix is the legacy uid string (reader_ttu/hoshi://book/<id>).
    const List<String> uidPrefixes = <String>[
      'audiobook_pos_',
      'audiobook_follow_',
      'audiobook_delay_',
      'audiobook_speed_',
      'audiobook_volume_',
      'audiobook_image_pause_',
      'audiobook_health_overlay_',
    ];

    String? mapUidSuffix(String suffix) {
      if (!suffix.startsWith(_kLegacyUidPrefix)) return null;
      final int? oldId =
          int.tryParse(suffix.substring(_kLegacyUidPrefix.length));
      if (oldId == null) return null;
      return idToKey[oldId];
    }

    for (final QueryRow r in rows) {
      final String key = r.read<String>('key');
      final String value = r.read<String>('value');

      // audiobook_pos_ has TWO suffix shapes: bare int (SyncRepository) or the
      // legacy uid (AudiobookRepository). Handle it explicitly so both merge.
      if (key.startsWith('audiobook_pos_')) {
        final String suffix = key.substring('audiobook_pos_'.length);
        String? newKeyKey;
        bool isUid = false;
        if (suffix.startsWith(_kLegacyUidPrefix)) {
          final String? bk = mapUidSuffix(suffix);
          if (bk != null) {
            newKeyKey = 'audiobook_pos_$bk';
            isUid = true;
          }
        } else {
          final int? oldId = int.tryParse(suffix);
          final String? bk = oldId == null ? null : idToKey[oldId];
          if (bk != null) newKeyKey = 'audiobook_pos_$bk';
        }
        if (newKeyKey != null) {
          oldKeysToDelete.add(key);
          if (isUid) {
            resolved[newKeyKey] = value;
            uidWonPos.add(newKeyKey);
          } else if (!uidWonPos.contains(newKeyKey)) {
            resolved[newKeyKey] = value;
          }
        }
        continue;
      }

      // bookmarks_<int> (BookmarkRepository / migrateLegacyBookmarkPreferences
      // normally consumes these into the table, but re-key any leftover).
      if (key.startsWith('bookmarks_')) {
        final String suffix = key.substring('bookmarks_'.length);
        final int? oldId = int.tryParse(suffix);
        final String? bk = oldId == null ? null : idToKey[oldId];
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['bookmarks_$bk'] = value;
        }
        continue;
      }

      // Remaining uid-suffix prefixes.
      for (final String prefix in uidPrefixes) {
        if (prefix == 'audiobook_pos_') continue; // handled above
        if (!key.startsWith(prefix)) continue;
        final String suffix = key.substring(prefix.length);
        final String? bk = mapUidSuffix(suffix);
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['$prefix$bk'] = value;
        }
        break;
      }
    }

    // Delete old keys first, then write resolved new keys (uid-priority applied).
    for (final String k in oldKeysToDelete) {
      await customStatement(
          'DELETE FROM preferences WHERE key = ?', <Object?>[k]);
    }
    for (final MapEntry<String, String> e in resolved.entries) {
      await customStatement(
        'INSERT INTO preferences (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        <Object?>[e.key, e.value],
      );
    }
  }

  /// Rewrites reading_statistics.title from the bare title to the sanitized
  /// bookKey domain so stats join the new identity. Rows that collapse to the
  /// same (sanitized title, date_key) are merged additively.
  ///
  /// CONTRACT / known follow-up: reading_statistics is keyed by `title`, not by
  /// a book id — same-title books have always shared a stats row, so merging
  /// here is a pre-existing property, not new behaviour introduced by this
  /// migration. After this step the stored title equals `_sanitizeBookKey(title)`
  /// (the bookKey domain), but runtime stats writes STILL use the bare title.
  /// Milestone 2 (the runtime-sweep pass) switches those writes to key by
  /// bookKey; until then a stale bare-title write would create a parallel row.
  /// That divergence is bounded and intentionally accepted for milestone 1 —
  /// milestone 2 aligns the two.
  Future<void> _migrateReadingStatsTitlesV16() async {
    if (!await _tableExists('reading_statistics')) return;
    final List<QueryRow> rows = await customSelect(
            'SELECT id, title, date_key, characters_read, reading_time_ms, '
            'last_statistic_modified FROM reading_statistics')
        .get();

    // Group target (sanitizedTitle, dateKey) -> accumulated values + the row id
    // we keep (smallest id) and the row ids we delete (merged away).
    final Map<String, _StatAccum> merged = <String, _StatAccum>{};
    for (final QueryRow r in rows) {
      final int id = r.read<int>('id');
      final String sanitized = _sanitizeBookKey(r.read<String>('title'));
      final String dateKey = r.read<String>('date_key');
      final String groupKey = '$sanitized $dateKey';
      final int chars = r.read<int>('characters_read');
      final int timeMs = r.read<int>('reading_time_ms');
      final int lastMod = r.read<int>('last_statistic_modified');
      final _StatAccum? acc = merged[groupKey];
      if (acc == null) {
        merged[groupKey] = _StatAccum(
          keepId: id,
          title: sanitized,
          chars: chars,
          timeMs: timeMs,
          lastMod: lastMod,
        );
      } else {
        acc.chars += chars;
        acc.timeMs += timeMs;
        if (lastMod > acc.lastMod) acc.lastMod = lastMod;
        acc.deleteIds.add(id);
      }
    }

    for (final _StatAccum acc in merged.values) {
      for (final int delId in acc.deleteIds) {
        await customStatement(
            'DELETE FROM reading_statistics WHERE id = ?', <Object?>[delId]);
      }
      await customStatement(
        'UPDATE reading_statistics SET title = ?, characters_read = ?, '
        'reading_time_ms = ?, last_statistic_modified = ? WHERE id = ?',
        <Object?>[
          acc.title,
          acc.chars,
          acc.timeMs,
          acc.lastMod,
          acc.keepId,
        ],
      );
    }
  }
}

/// Mutable accumulator for reading_statistics merge during v16 migration.
class _StatAccum {
  _StatAccum({
    required this.keepId,
    required this.title,
    required this.chars,
    required this.timeMs,
    required this.lastMod,
  });

  final int keepId;
  final String title;
  int chars;
  int timeMs;
  int lastMod;
  final List<int> deleteIds = <int>[];
}
