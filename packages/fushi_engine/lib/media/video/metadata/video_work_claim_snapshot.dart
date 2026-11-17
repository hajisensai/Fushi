/// 视频作品「认领」（刮削确认选候选 / 手动指定身份 / `video identify`）的执行前快照与
/// 撤销（AI 写操作必须可回滚，`fushi/CLAUDE.md` §13；设计稿
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §6 第 4 点）。
///
/// ## 一次认领写了什么（沿 `VideoSourceScrapeCoordinator` → `VideoMetadataDatabaseStore.apply`
/// → `_writeSidecars` → `_writeLegacyImages` → `onWorkScraped` 的真实路径）
///
/// 数据库（本快照整块抓、整块恢复）：
/// 1. `video_metadata_works` 作品行（upsert；合集单元还会删掉成员自己拥有的单集作品行，
///    拆分时协调器会删合集级作品行）及级联子树：`video_metadata_seasons` /
///    `video_metadata_episodes`（含分集 ↔ 文件绑定、AniDB 集身份）/
///    `video_metadata_provider_identities`（作品 / 季 / 集的各 provider 身份，`is_primary`
///    即作品身份）/ `video_metadata_raw_snapshots` / `video_metadata_work_terms` /
///    `video_metadata_credits` / `video_metadata_images`（含落盘后的 `local_path`）/
///    `video_metadata_extras`；
/// 2. 共享字典 `video_metadata_people` / `video_metadata_characters` / `video_metadata_terms`
///    （新增或按新资料更新）；
/// 3. 别的作品里绑到本单元成员文件的分集行（`_clearReassignedEpisodeBooks` 把它们的
///    `book_uid` 清空）；
/// 4. 旧投影：`video_scrape_meta`（成员 / 单条目）、`collection_scrape_meta`（合集）、
///    `video_books.title`（分集名投影到导入时的文件名标题）；
/// 5. 封面：`video_books.cover_path` / `media_collections.cover_path` 指向生成的海报，
///    `media_images` 里 `source_url` 非空的刮削投影图整组替换；
/// 6. sidecar 所有权账本 `video_sidecar_artifacts`（NFO / 海报 / 背景图，按作品 / 季 / 集
///    挂 owner）。
///
/// 磁盘文件：
/// 7. sidecar 文件本体（NFO、海报等，写在视频旁）。执行前把本单元账本里已有的生成物
///    复制到 [captureVideoWorkClaimSnapshot] 的备份目录；撤销时这次新写的生成物删掉、
///    被覆盖的拷回旧内容（文件被用户改过 → superseded，不动）。
///
/// 不在本快照里、撤销**不还原**的（都不构成作品身份，见回报）：
/// - 刮削运行记录 `video_source_scrape_runs`（审计）、AniDB 文件哈希身份缓存（与认领
///   无关，同一文件下次识别照用）、补刮账本；
/// - 刮削后自动补的在线字幕（`onWorkScraped` → 字幕补齐；用户可能已经在用，且
///   `video.subtitle.fetch` 有自己的撤销）、人物头像缓存文件（`_downloadStaffImages`，
///   孤儿缓存无害）；
/// - 字幕 AI 校对专名表 `video_subtitle_glossaries`（认领不写它，校对时才按作品资料生成）；
/// - 共享字典里**已有**人物 / 角色名下由合并写入的身份与图片（只恢复字典行本身的列）。
///
/// 待确认队列不是一张表：判据是「作品单元没有规范身份」（`video_library_scrape_sweep.dart`），
/// 所以认领前没有作品行的单元，撤销删掉作品行后自然回到待确认队列；认领前已有身份的，
/// 恢复成旧身份、不进队列。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 快照里一行（列名 → 值，SQLite 原样：int / double / String / null；blob 编成
/// `{'$b64': …}`，见 [_encodeValue]）。
typedef VideoClaimSqlRow = Map<String, Object?>;

/// 快照覆盖的作品子树表（按插入顺序：先父后子）。
const List<String> _kWorkTreeTables = <String>[
  'video_metadata_works',
  'video_metadata_seasons',
  'video_metadata_episodes',
  'video_metadata_provider_identities',
  'video_metadata_raw_snapshots',
  'video_metadata_work_terms',
  'video_metadata_credits',
  'video_metadata_images',
  'video_metadata_extras',
];

/// 共享字典表 → 主键列。
const Map<String, String> _kDictionaryKeys = <String, String>{
  'video_metadata_people': 'person_key',
  'video_metadata_characters': 'character_key',
  'video_metadata_terms': 'term_key',
};

/// 撤销时受影响、需要通知 drift 监听者刷新的表。
const List<String> _kTouchedTables = <String>[
  ..._kWorkTreeTables,
  'video_metadata_people',
  'video_metadata_characters',
  'video_metadata_terms',
  'video_scrape_meta',
  'collection_scrape_meta',
  'video_books',
  'media_collections',
  'media_images',
  'video_sidecar_artifacts',
];

/// 一个作品单元（`book:<uid>` / `collection:<id>`，与刮削计划器的 `stableKey` 同一把键）
/// 认领前的完整状态。整块进撤销载荷（`ai_agent_actions.undoPayloadJson`）。
class VideoWorkClaimSnapshot {
  const VideoWorkClaimSnapshot({
    required this.unitKey,
    required this.bookUids,
    required this.collectionIds,
    required this.tables,
    required this.foreignEpisodeBooks,
    required this.books,
    required this.collectionCovers,
    required this.fileBackups,
    required this.primaryIdentities,
    required this.lockedFieldNames,
  });

  /// 作品单元键。
  final String unitKey;

  /// 单元涉及的视频书（合集单元 = 成员；单条目 = 自己）。
  final List<String> bookUids;

  /// 单元涉及的合集（合集单元 = 自己；单条目 = 包含它的合集——拆分会删合集级作品行）。
  final List<int> collectionIds;

  /// 表名 → 行：作品子树、字典、旧投影、`media_images`（刮削投影部分）、sidecar 账本。
  final Map<String, List<VideoClaimSqlRow>> tables;

  /// 别的作品里绑到本单元成员文件的分集：分集行 id → book uid。
  final Map<int, String> foreignEpisodeBooks;

  /// book uid → `{title, coverPath}`。
  final Map<String, Map<String, Object?>> books;

  /// 合集 id → 封面路径（null = 没有封面）。
  final Map<int, String?> collectionCovers;

  /// sidecar 文件路径 → 执行前内容的备份路径。
  final Map<String, String> fileBackups;

  /// 认领前单元内作品的主身份（`provider:externalId`）。
  final List<String> primaryIdentities;

  /// 认领前单元内作品的字段锁名并集。
  final List<String> lockedFieldNames;

  Map<String, Object?> toJson() => <String, Object?>{
    'unitKey': unitKey,
    'bookUids': bookUids,
    'collectionIds': collectionIds,
    'tables': <String, Object?>{
      for (final MapEntry<String, List<VideoClaimSqlRow>> e in tables.entries)
        e.key: <Object?>[
          for (final VideoClaimSqlRow row in e.value)
            <String, Object?>{
              for (final MapEntry<String, Object?> c in row.entries)
                c.key: _encodeValue(c.value),
            },
        ],
    },
    'foreignEpisodeBooks': <String, Object?>{
      for (final MapEntry<int, String> e in foreignEpisodeBooks.entries)
        '${e.key}': e.value,
    },
    'books': books,
    'collectionCovers': <String, Object?>{
      for (final MapEntry<int, String?> e in collectionCovers.entries)
        '${e.key}': e.value,
    },
    'fileBackups': fileBackups,
    'primaryIdentities': primaryIdentities,
    'lockedFieldNames': lockedFieldNames,
  };

  /// 从撤销载荷还原（JSON 往返后类型会松）。形态不对抛 [FormatException]。
  static VideoWorkClaimSnapshot fromJson(Object? json) {
    if (json is! Map) throw const FormatException('claim snapshot');
    final Object? unitKey = json['unitKey'];
    if (unitKey is! String) throw const FormatException('claim snapshot key');
    Map<String, Object?> map(Object? raw) => <String, Object?>{
      if (raw is Map)
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
    };
    List<String> strings(Object? raw) => <String>[
      if (raw is List)
        for (final Object? v in raw)
          if (v != null) '$v',
    ];
    return VideoWorkClaimSnapshot(
      unitKey: unitKey,
      bookUids: strings(json['bookUids']),
      collectionIds: <int>[
        for (final String v in strings(json['collectionIds'])) ?int.tryParse(v),
      ],
      tables: <String, List<VideoClaimSqlRow>>{
        for (final MapEntry<String, Object?> e in map(json['tables']).entries)
          e.key: <VideoClaimSqlRow>[
            if (e.value case final List<Object?> rows)
              for (final Object? row in rows)
                <String, Object?>{
                  for (final MapEntry<String, Object?> c in map(row).entries)
                    c.key: _decodeValue(c.value),
                },
          ],
      },
      foreignEpisodeBooks: <int, String>{
        for (final MapEntry<String, Object?> e in map(
          json['foreignEpisodeBooks'],
        ).entries)
          if (int.tryParse(e.key) case final int id) id: '${e.value}',
      },
      books: <String, Map<String, Object?>>{
        for (final MapEntry<String, Object?> e in map(json['books']).entries)
          e.key: map(e.value),
      },
      collectionCovers: <int, String?>{
        for (final MapEntry<String, Object?> e in map(
          json['collectionCovers'],
        ).entries)
          if (int.tryParse(e.key) case final int id)
            id: e.value is String ? e.value! as String : null,
      },
      fileBackups: <String, String>{
        for (final MapEntry<String, Object?> e in map(
          json['fileBackups'],
        ).entries)
          e.key: '${e.value}',
      },
      primaryIdentities: strings(json['primaryIdentities']),
      lockedFieldNames: strings(json['lockedFieldNames']),
    );
  }
}

/// 撤销结论。
enum VideoWorkClaimRevertStatus {
  /// 已恢复到认领前。
  restored,

  /// 认领没落库（批次失败 / 跳过），什么也没动。
  nothingToRevert,

  /// 认领后又被改过（身份、字段锁、标题、封面、sidecar 文件），不覆盖。
  superseded,

  /// 恢复失败或现在不能恢复（刮削批次进行中、备份丢失、写库出错）；状态不变。
  failed,
}

class VideoWorkClaimRevertResult {
  const VideoWorkClaimRevertResult(this.status, [this.message]);

  final VideoWorkClaimRevertStatus status;
  final String? message;
}

// ─────────────────────────────────────────────────────────────────────────
// 抓快照
// ─────────────────────────────────────────────────────────────────────────

/// 执行认领**前**抓 [unitKey] 单元的完整状态；本单元已有的 sidecar 生成物复制进
/// [backupDirectory]（30 天后由 [pruneVideoWorkClaimBackups] 清理）。
Future<VideoWorkClaimSnapshot> captureVideoWorkClaimSnapshot(
  FushiDatabase db,
  String unitKey, {
  required Directory backupDirectory,
}) async {
  final _UnitScope scope = await _unitScope(db, unitKey);
  final _TreeIds ids = await _treeIds(db, scope);
  final Map<String, List<VideoClaimSqlRow>> tables = await _readTree(db, ids);
  tables.addAll(await _readDictionaries(db, tables));
  tables['video_scrape_meta'] = await _select(
    db,
    'video_scrape_meta',
    'book_uid',
    scope.bookUids,
  );
  tables['collection_scrape_meta'] = await _select(
    db,
    'collection_scrape_meta',
    'collection_id',
    scope.collectionIds,
  );
  tables['media_images'] = await _scrapedMediaImages(db, scope);
  final List<VideoClaimSqlRow> ledger = await _ledgerRows(db, ids);
  tables['video_sidecar_artifacts'] = ledger;

  final Map<int, String> foreign = <int, String>{};
  for (final VideoClaimSqlRow row in await _select(
    db,
    'video_metadata_episodes',
    'book_uid',
    scope.bookUids,
  )) {
    if (ids.seasons.contains(row['season_id'])) continue;
    foreign[row['id']! as int] = row['book_uid']! as String;
  }

  final Map<String, Map<String, Object?>> books =
      <String, Map<String, Object?>>{
        for (final VideoClaimSqlRow row in await _select(
          db,
          'video_books',
          'book_uid',
          scope.bookUids,
        ))
          row['book_uid']! as String: <String, Object?>{
            'title': row['title'],
            'coverPath': row['cover_path'],
          },
      };
  final Map<int, String?> covers = <int, String?>{
    for (final VideoClaimSqlRow row in await _select(
      db,
      'media_collections',
      'id',
      scope.collectionIds,
    ))
      row['id']! as int: row['cover_path'] as String?,
  };

  final Map<String, String> backups = <String, String>{};
  if (ledger.isNotEmpty) {
    await backupDirectory.create(recursive: true);
    await pruneVideoWorkClaimBackups(backupDirectory);
    final int stamp = DateTime.now().microsecondsSinceEpoch;
    int index = 0;
    for (final VideoClaimSqlRow row in ledger) {
      final String path = row['path']! as String;
      final File file = File(path);
      if (!file.existsSync()) continue;
      final String backup = p.join(
        backupDirectory.path,
        '${stamp}_${index++}${p.extension(path)}',
      );
      await file.copy(backup);
      // 复制会带上原文件的修改时间；清理按修改时间判年龄，所以钉成现在。
      await File(backup).setLastModified(DateTime.now());
      backups[path] = backup;
    }
  }

  return VideoWorkClaimSnapshot(
    unitKey: unitKey,
    bookUids: scope.bookUids,
    collectionIds: scope.collectionIds,
    tables: tables,
    foreignEpisodeBooks: foreign,
    books: books,
    collectionCovers: covers,
    fileBackups: backups,
    primaryIdentities: _primaryIdentities(tables),
    lockedFieldNames: _lockNames(tables['video_metadata_works']!),
  );
}

/// 撤销备份保留期（与书封面撤销备份同一口径）。
const Duration kVideoWorkClaimBackupRetention = Duration(days: 30);

/// 清掉 [directory] 里超过保留期的备份。
Future<void> pruneVideoWorkClaimBackups(Directory directory) async {
  if (!directory.existsSync()) return;
  final DateTime cutoff = DateTime.now().subtract(
    kVideoWorkClaimBackupRetention,
  );
  await for (final FileSystemEntity entity in directory.list()) {
    if (entity is! File) continue;
    if ((await entity.lastModified()).isBefore(cutoff)) {
      await entity.delete();
    }
  }
}

/// 认领用掉了（或作废了）的备份：删掉。
Future<void> discardVideoWorkClaimBackups(
  VideoWorkClaimSnapshot snapshot,
) async {
  for (final String backup in snapshot.fileBackups.values) {
    final File file = File(backup);
    if (file.existsSync()) await file.delete();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 撤销
// ─────────────────────────────────────────────────────────────────────────

/// 把 [snapshot] 的单元恢复到认领前。[claimedIdentity] 是这次认领选定的身份
/// （`provider:externalId`）；null = 这次什么也没认领（跳过）。
///
/// 判据（全部在写之前查完，任何一条不过就不动）：
/// - 刮削批次进行中（[isScrapeBusy] 或库里有 running 的运行记录）→ failed；
/// - 单元主身份里没有 [claimedIdentity]：与认领前相同 = 认领没落库 → nothingToRevert；
///   否则是之后被改过 → superseded；
/// - 出现认领前没有的字段锁（用户手动改过资料）→ superseded；
/// - 成员标题既不是认领前的、也不是刮削投影的；封面既不是认领前的、也不是未被改动的
///   生成物；本单元 sidecar 生成物被改过 → superseded；
/// - 备份文件丢了 → failed。
///
/// 写入在一个事务里完成，sidecar 文件操作带回滚日志：任何一步失败，库与文件都回到
/// 撤销前（要么全恢复，要么报失败且状态不变）。
Future<VideoWorkClaimRevertResult> revertVideoWorkClaim(
  FushiDatabase db,
  VideoWorkClaimSnapshot snapshot, {
  required String? claimedIdentity,
  required Directory stagingParent,
  bool isScrapeBusy = false,
}) async {
  if (claimedIdentity == null) {
    return const VideoWorkClaimRevertResult(
      VideoWorkClaimRevertStatus.nothingToRevert,
    );
  }
  if (isScrapeBusy || await db.hasRunningVideoSourceScrapeRun()) {
    return const VideoWorkClaimRevertResult(
      VideoWorkClaimRevertStatus.failed,
      '刮削批次进行中，等它结束再撤销',
    );
  }
  final _UnitScope now = await _unitScope(db, snapshot.unitKey);
  final _UnitScope scope = _UnitScope(
    bookUids: <String>{...snapshot.bookUids, ...now.bookUids}.toList(),
    collectionIds: <int>{
      ...snapshot.collectionIds,
      ...now.collectionIds,
    }.toList(),
  );
  final _TreeIds current = await _treeIds(db, scope);
  final Map<String, List<VideoClaimSqlRow>> currentTree = await _readTree(
    db,
    current,
  );

  // ── 判据 ──
  final List<String> currentPrimaries = _primaryIdentities(currentTree);
  if (!currentPrimaries.contains(claimedIdentity)) {
    final bool unchanged =
        (currentPrimaries.toSet()..removeAll(snapshot.primaryIdentities))
            .isEmpty &&
        (snapshot.primaryIdentities.toSet()..removeAll(currentPrimaries))
            .isEmpty;
    return unchanged
        ? const VideoWorkClaimRevertResult(
            VideoWorkClaimRevertStatus.nothingToRevert,
          )
        : const VideoWorkClaimRevertResult(
            VideoWorkClaimRevertStatus.superseded,
            '作品身份在认领后又被改过',
          );
  }
  final Set<String> newLocks = _lockNames(
    currentTree['video_metadata_works']!,
  ).toSet()..removeAll(snapshot.lockedFieldNames);
  if (newLocks.isNotEmpty) {
    return VideoWorkClaimRevertResult(
      VideoWorkClaimRevertStatus.superseded,
      '认领后手动改过资料（${newLocks.join(', ')}）',
    );
  }
  final List<VideoClaimSqlRow> currentLedger = await _ledgerRows(db, current);
  final Map<String, VideoClaimSqlRow> ledgerByPath = <String, VideoClaimSqlRow>{
    for (final VideoClaimSqlRow row in currentLedger)
      row['path']! as String: row,
  };
  for (final VideoClaimSqlRow row in currentLedger) {
    final File file = File(row['path']! as String);
    if (file.existsSync() && await _sha256(file) != row['sha256']) {
      return VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '认领后改过 sidecar 文件：${file.path}',
      );
    }
  }
  Future<bool> isGenerated(String? path) async {
    if (path == null) return false;
    final VideoClaimSqlRow? row =
        ledgerByPath[p.normalize(p.absolute(path))] ?? ledgerByPath[path];
    if (row == null) return false;
    final File file = File(row['path']! as String);
    return file.existsSync() && await _sha256(file) == row['sha256'];
  }

  final Map<String, String> scrapedTitles = <String, String>{
    for (final VideoClaimSqlRow row in await _select(
      db,
      'video_scrape_meta',
      'book_uid',
      snapshot.bookUids,
    ))
      row['book_uid']! as String: row['title']! as String,
  };
  for (final MapEntry<String, Map<String, Object?>> e
      in snapshot.books.entries) {
    final List<VideoClaimSqlRow> rows = await _select(
      db,
      'video_books',
      'book_uid',
      <String>[e.key],
    );
    if (rows.isEmpty) {
      return VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '视频已不在库里：${e.key}',
      );
    }
    final String? title = rows.single['title'] as String?;
    if (title != e.value['title'] && title != scrapedTitles[e.key]) {
      return VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '认领后手动改过标题：$title',
      );
    }
    final String? cover = rows.single['cover_path'] as String?;
    if (cover != e.value['coverPath'] && !await isGenerated(cover)) {
      return const VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '认领后手动换过封面',
      );
    }
  }
  for (final MapEntry<int, String?> e in snapshot.collectionCovers.entries) {
    final List<VideoClaimSqlRow> rows = await _select(
      db,
      'media_collections',
      'id',
      <int>[e.key],
    );
    if (rows.isEmpty) {
      return const VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '合集已删除',
      );
    }
    final String? cover = rows.single['cover_path'] as String?;
    if (cover != e.value && !await isGenerated(cover)) {
      return const VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.superseded,
        '认领后手动换过合集封面',
      );
    }
  }
  for (final String backup in snapshot.fileBackups.values) {
    if (!File(backup).existsSync()) {
      return VideoWorkClaimRevertResult(
        VideoWorkClaimRevertStatus.failed,
        'sidecar 备份已不在（超过 ${kVideoWorkClaimBackupRetention.inDays} 天会被清理）',
      );
    }
  }

  // ── 写 ──
  final Set<String> createdDictionaryKeys = <String>{
    for (final VideoClaimSqlRow row in <VideoClaimSqlRow>[
      ...currentTree['video_metadata_credits']!,
      ...currentTree['video_metadata_work_terms']!,
    ])
      for (final String column in const <String>[
        'person_key',
        'character_key',
        'term_key',
      ])
        if (row[column] case final String key) '$column\u0000$key',
  };
  final _FileJournal journal = _FileJournal(
    Directory(
      p.join(
        stagingParent.path,
        'claim_staging_${DateTime.now().microsecondsSinceEpoch}',
      ),
    ),
  );
  try {
    await db.transaction(() async {
      if (await db.hasRunningVideoSourceScrapeRun()) {
        throw const VideoScrapeRecordsBusyException();
      }
      await _restoreDatabase(
        db,
        snapshot,
        scope: scope,
        current: current,
        currentLedger: currentLedger,
        createdDictionaryKeys: createdDictionaryKeys,
      );
      await _restoreFiles(journal, snapshot, currentLedger);
    });
  } on VideoScrapeRecordsBusyException {
    await journal.rollback();
    return const VideoWorkClaimRevertResult(
      VideoWorkClaimRevertStatus.failed,
      '刮削批次进行中，等它结束再撤销',
    );
  } on Object catch (error) {
    await journal.rollback();
    return VideoWorkClaimRevertResult(
      VideoWorkClaimRevertStatus.failed,
      '恢复失败，状态未变：$error',
    );
  }
  await journal.commit();
  await discardVideoWorkClaimBackups(snapshot);
  db.notifyUpdates(<TableUpdate>{
    for (final String table in _kTouchedTables) TableUpdate(table),
  });
  return const VideoWorkClaimRevertResult(VideoWorkClaimRevertStatus.restored);
}

Future<void> _restoreDatabase(
  FushiDatabase db,
  VideoWorkClaimSnapshot snapshot, {
  required _UnitScope scope,
  required _TreeIds current,
  required List<VideoClaimSqlRow> currentLedger,
  required Set<String> createdDictionaryKeys,
}) async {
  final int nowMs = DateTime.now().millisecondsSinceEpoch;
  final List<int> oldWorkIds = <int>[
    for (final VideoClaimSqlRow row
        in snapshot.tables['video_metadata_works'] ??
            const <VideoClaimSqlRow>[])
      row['id']! as int,
  ];
  // 1. 删掉当前单元（与认领前快照里）的作品子树。子表逐张显式删、先子后父，不靠
  //    FK 级联：级联依赖连接上的 `PRAGMA foreign_keys`，显式删在任何连接上都一样。
  List<int> ids(String table) => <int>[
    for (final VideoClaimSqlRow row
        in snapshot.tables[table] ?? const <VideoClaimSqlRow>[])
      row['id']! as int,
  ];
  final List<int> works = <int>{...current.works, ...oldWorkIds}.toList();
  final List<int> seasons = <int>{
    ...current.seasons,
    ...ids('video_metadata_seasons'),
  }.toList();
  final List<int> episodes = <int>{
    ...current.episodes,
    ...ids('video_metadata_episodes'),
  }.toList();
  final List<(String, List<Object>)> owners = <(String, List<Object>)>[
    ('work_id', works),
    ('season_id', seasons),
    ('episode_id', episodes),
  ];
  final List<Object> identityKeys = <Object>{
    for (final VideoClaimSqlRow row in await _selectWhere(
      db,
      'video_metadata_provider_identities',
      owners,
    ))
      row['identity_key']!,
    for (final VideoClaimSqlRow row
        in snapshot.tables['video_metadata_provider_identities'] ??
            const <VideoClaimSqlRow>[])
      row['identity_key']!,
  }.toList();
  await _delete(
    db,
    'video_metadata_raw_snapshots',
    'identity_key',
    identityKeys,
  );
  for (final String table in const <String>[
    'video_metadata_provider_identities',
    'video_metadata_credits',
    'video_metadata_images',
  ]) {
    for (final (String column, List<Object> values) in owners) {
      await _delete(db, table, column, values);
    }
  }
  await _delete(db, 'video_metadata_work_terms', 'work_id', works);
  await _delete(db, 'video_metadata_extras', 'work_id', works);
  await _delete(db, 'video_metadata_episodes', 'id', episodes);
  await _delete(db, 'video_metadata_episodes', 'season_id', seasons);
  await _delete(db, 'video_metadata_seasons', 'id', seasons);
  await _delete(db, 'video_metadata_seasons', 'work_id', works);
  await _delete(db, 'video_metadata_works', 'id', works);

  // 2. 字典：认领前的行写回（已有的按列 UPDATE，不用 REPLACE——REPLACE 会先删行、
  //    级联掉别的作品挂在它名下的身份与图片）。
  for (final MapEntry<String, String> dict in _kDictionaryKeys.entries) {
    for (final VideoClaimSqlRow row
        in snapshot.tables[dict.key] ?? const <VideoClaimSqlRow>[]) {
      final List<VideoClaimSqlRow> existing = await _select(
        db,
        dict.key,
        dict.value,
        <Object>[row[dict.value]!],
      );
      if (existing.isEmpty) {
        await _insert(db, dict.key, row);
      } else {
        await _update(db, dict.key, dict.value, row);
      }
    }
  }

  // 3. 作品子树原样插回（行 id 不变：AUTOINCREMENT 不复用 id，认领新建的行已随
  //    第 1 步删掉）。
  for (final String table in _kWorkTreeTables) {
    for (final VideoClaimSqlRow row
        in snapshot.tables[table] ?? const <VideoClaimSqlRow>[]) {
      await _insert(db, table, row);
    }
  }
  // 恢复出来的作品行盖上现在的时间戳：互联客户端按 updatedAt 增量拉，旧戳会被
  // 当成「已经见过」而拉不到撤销后的状态。
  if (oldWorkIds.isNotEmpty) {
    await db.customStatement(
      'UPDATE video_metadata_works SET updated_at = ? '
      'WHERE id IN (${_marks(oldWorkIds.length)})',
      <Object?>[nowMs, ...oldWorkIds],
    );
  }

  // 4. 认领顺带清掉的别的作品分集绑定。
  for (final MapEntry<int, String> e in snapshot.foreignEpisodeBooks.entries) {
    await db.customStatement(
      'UPDATE video_metadata_episodes SET book_uid = ? '
      'WHERE id = ? AND book_uid IS NULL',
      <Object?>[e.value, e.key],
    );
  }

  // 5. 认领新建、现在已没人引用的字典行（认领前就有的不动）。
  final Set<String> before = <String>{
    for (final MapEntry<String, String> dict in _kDictionaryKeys.entries)
      for (final VideoClaimSqlRow row
          in snapshot.tables[dict.key] ?? const <VideoClaimSqlRow>[])
        '${dict.value}\u0000${row[dict.value]}',
  };
  for (final String entry in createdDictionaryKeys.difference(before)) {
    final List<String> parts = entry.split('\u0000');
    final String column = parts.first;
    final String key = parts.last;
    final (String table, String usage) = switch (column) {
      'person_key' => (
        'video_metadata_people',
        'SELECT 1 FROM video_metadata_credits WHERE person_key = ? LIMIT 1',
      ),
      'character_key' => (
        'video_metadata_characters',
        'SELECT 1 FROM video_metadata_credits WHERE character_key = ? LIMIT 1',
      ),
      _ => (
        'video_metadata_terms',
        'SELECT 1 FROM video_metadata_work_terms WHERE term_key = ? LIMIT 1',
      ),
    };
    final List<QueryRow> used = await db
        .customSelect(
          usage,
          variables: <Variable<Object>>[Variable<Object>(key)],
        )
        .get();
    if (used.isEmpty) await _delete(db, table, column, <Object>[key]);
  }

  // 6. 旧投影。
  await _delete(db, 'video_scrape_meta', 'book_uid', scope.bookUids);
  for (final VideoClaimSqlRow row
      in snapshot.tables['video_scrape_meta'] ?? const <VideoClaimSqlRow>[]) {
    await _insert(db, 'video_scrape_meta', row);
  }
  await _delete(
    db,
    'collection_scrape_meta',
    'collection_id',
    scope.collectionIds,
  );
  for (final VideoClaimSqlRow row
      in snapshot.tables['collection_scrape_meta'] ??
          const <VideoClaimSqlRow>[]) {
    await _insert(db, 'collection_scrape_meta', row);
  }

  // 7. 标题 / 封面 / 刮削投影图。
  for (final MapEntry<String, Map<String, Object?>> e
      in snapshot.books.entries) {
    await db.customStatement(
      'UPDATE video_books SET title = ?, cover_path = ? WHERE book_uid = ?',
      <Object?>[e.value['title'], e.value['coverPath'], e.key],
    );
  }
  for (final MapEntry<int, String?> e in snapshot.collectionCovers.entries) {
    await db.customStatement(
      'UPDATE media_collections SET cover_path = ? WHERE id = ?',
      <Object?>[e.value, e.key],
    );
  }
  final (String imageWhere, List<Object?> imageArgs) = _scrapedImagesWhere(
    scope,
  );
  await db.customStatement(
    'DELETE FROM media_images WHERE $imageWhere',
    imageArgs,
  );
  for (final VideoClaimSqlRow row
      in snapshot.tables['media_images'] ?? const <VideoClaimSqlRow>[]) {
    await _insert(db, 'media_images', row);
  }

  // 8. sidecar 账本：这次写的与认领前的路径一并按路径删，再插回认领前的行（owner /
  //    run / source 已不在的置空，与 FK 的 SET NULL 语义一致）。
  final List<VideoClaimSqlRow> oldLedger =
      snapshot.tables['video_sidecar_artifacts'] ?? const <VideoClaimSqlRow>[];
  await _delete(
    db,
    'video_sidecar_artifacts',
    'path',
    <String>{
      for (final VideoClaimSqlRow row in currentLedger) row['path']! as String,
      for (final VideoClaimSqlRow row in oldLedger) row['path']! as String,
    }.toList(),
  );
  for (final VideoClaimSqlRow row in oldLedger) {
    final VideoClaimSqlRow fixed = <String, Object?>{...row};
    for (final (String column, String table) in const <(String, String)>[
      ('run_id', 'video_source_scrape_runs'),
      ('source_id', 'media_sources'),
      ('work_id', 'video_metadata_works'),
      ('season_id', 'video_metadata_seasons'),
      ('episode_id', 'video_metadata_episodes'),
    ]) {
      final Object? id = fixed[column];
      if (id == null) continue;
      if ((await _select(db, table, 'id', <Object>[id])).isEmpty) {
        fixed[column] = null;
      }
    }
    await _insert(db, 'video_sidecar_artifacts', fixed);
  }
}

/// 文件：这次新写的生成物删掉，被覆盖的拷回认领前内容，被删掉的补回。
Future<void> _restoreFiles(
  _FileJournal journal,
  VideoWorkClaimSnapshot snapshot,
  List<VideoClaimSqlRow> currentLedger,
) async {
  final Set<String> handled = <String>{};
  for (final VideoClaimSqlRow row in currentLedger) {
    final String path = row['path']! as String;
    handled.add(path);
    final String? backup = snapshot.fileBackups[path];
    if (backup != null) {
      await journal.replace(path, backup);
    } else {
      await journal.delete(path);
    }
  }
  for (final MapEntry<String, String> e in snapshot.fileBackups.entries) {
    if (handled.contains(e.key) || File(e.key).existsSync()) continue;
    await journal.replace(e.key, e.value);
  }
}

/// 文件操作的回滚日志：改动前把原文件挪进暂存目录，失败时逐个还原。
class _FileJournal {
  _FileJournal(this.staging);

  final Directory staging;
  final List<(String target, String? staged)> _entries = <(String, String?)>[];
  int _next = 0;

  Future<String?> _stage(String target) async {
    final File file = File(target);
    if (!file.existsSync()) return null;
    await staging.create(recursive: true);
    final String staged = p.join(staging.path, '${_next++}');
    await file.copy(staged);
    return staged;
  }

  Future<void> replace(String target, String source) async {
    final String? staged = await _stage(target);
    _entries.add((target, staged));
    await File(target).parent.create(recursive: true);
    await File(source).copy(target);
  }

  Future<void> delete(String target) async {
    final String? staged = await _stage(target);
    if (staged == null) return;
    _entries.add((target, staged));
    await File(target).delete();
  }

  Future<void> rollback() async {
    for (final (String target, String? staged) in _entries.reversed) {
      if (staged != null) {
        await File(staged).copy(target);
      } else if (File(target).existsSync()) {
        await File(target).delete();
      }
    }
    _entries.clear();
    await commit();
  }

  Future<void> commit() async {
    if (staging.existsSync()) await staging.delete(recursive: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 读
// ─────────────────────────────────────────────────────────────────────────

class _UnitScope {
  const _UnitScope({required this.bookUids, required this.collectionIds});

  final List<String> bookUids;
  final List<int> collectionIds;
}

class _TreeIds {
  const _TreeIds({
    required this.works,
    required this.seasons,
    required this.episodes,
  });

  final List<int> works;
  final Set<int> seasons;
  final List<int> episodes;
}

/// 单元键 → 涉及的书与合集。格式不对抛 [FormatException]。
Future<_UnitScope> _unitScope(FushiDatabase db, String unitKey) async {
  if (unitKey.startsWith('collection:')) {
    final int? id = int.tryParse(unitKey.substring('collection:'.length));
    if (id == null) throw FormatException('作品键无效：$unitKey');
    final List<QueryRow> members = await db
        .customSelect(
          'SELECT entry_key FROM media_collection_items '
          "WHERE collection_id = ? AND media_type = 'video'",
          variables: <Variable<Object>>[Variable<Object>(id)],
        )
        .get();
    return _UnitScope(
      bookUids: <String>[
        for (final QueryRow row in members) row.read<String>('entry_key'),
      ],
      collectionIds: <int>[id],
    );
  }
  if (unitKey.startsWith('book:')) {
    final String uid = unitKey.substring('book:'.length);
    if (uid.isEmpty) throw FormatException('作品键无效：$unitKey');
    final List<QueryRow> owners = await db
        .customSelect(
          'SELECT collection_id FROM media_collection_items '
          "WHERE entry_key = ? AND media_type = 'video'",
          variables: <Variable<Object>>[Variable<Object>(uid)],
        )
        .get();
    return _UnitScope(
      bookUids: <String>[uid],
      collectionIds: <int>[
        for (final QueryRow row in owners) row.read<int>('collection_id'),
      ],
    );
  }
  throw FormatException('作品键无效：$unitKey');
}

Future<_TreeIds> _treeIds(FushiDatabase db, _UnitScope scope) async {
  final List<Object?> args = <Object?>[];
  final List<String> where = <String>[];
  if (scope.collectionIds.isNotEmpty) {
    where.add('collection_id IN (${_marks(scope.collectionIds.length)})');
    args.addAll(scope.collectionIds);
  }
  if (scope.bookUids.isNotEmpty) {
    where.add('book_uid IN (${_marks(scope.bookUids.length)})');
    args.addAll(scope.bookUids);
  }
  if (where.isEmpty) {
    return const _TreeIds(works: <int>[], seasons: <int>{}, episodes: <int>[]);
  }
  final List<int> works = <int>[
    for (final QueryRow row
        in await db
            .customSelect(
              'SELECT id FROM video_metadata_works WHERE ${where.join(' OR ')} '
              'ORDER BY id',
              variables: _vars(args),
            )
            .get())
      row.read<int>('id'),
  ];
  final Set<int> seasons = <int>{
    for (final VideoClaimSqlRow row in await _select(
      db,
      'video_metadata_seasons',
      'work_id',
      works,
    ))
      row['id']! as int,
  };
  final List<int> episodes = <int>[
    for (final VideoClaimSqlRow row in await _select(
      db,
      'video_metadata_episodes',
      'season_id',
      seasons.toList(),
    ))
      row['id']! as int,
  ];
  return _TreeIds(works: works, seasons: seasons, episodes: episodes);
}

/// 作品子树全部行（按 [_kWorkTreeTables]）。
Future<Map<String, List<VideoClaimSqlRow>>> _readTree(
  FushiDatabase db,
  _TreeIds ids,
) async {
  final List<int> seasons = ids.seasons.toList()..sort();
  Future<List<VideoClaimSqlRow>> owned(String table) =>
      _selectWhere(db, table, <(String, List<Object>)>[
        ('work_id', ids.works),
        ('season_id', seasons),
        ('episode_id', ids.episodes),
      ]);
  final List<VideoClaimSqlRow> identities = await owned(
    'video_metadata_provider_identities',
  );
  return <String, List<VideoClaimSqlRow>>{
    'video_metadata_works': await _select(
      db,
      'video_metadata_works',
      'id',
      ids.works,
    ),
    'video_metadata_seasons': await _select(
      db,
      'video_metadata_seasons',
      'id',
      seasons,
    ),
    'video_metadata_episodes': await _select(
      db,
      'video_metadata_episodes',
      'id',
      ids.episodes,
    ),
    'video_metadata_provider_identities': identities,
    'video_metadata_raw_snapshots': await _select(
      db,
      'video_metadata_raw_snapshots',
      'identity_key',
      <Object>[
        for (final VideoClaimSqlRow row in identities) row['identity_key']!,
      ],
    ),
    'video_metadata_work_terms': await _select(
      db,
      'video_metadata_work_terms',
      'work_id',
      ids.works,
    ),
    'video_metadata_credits': await owned('video_metadata_credits'),
    'video_metadata_images': await owned('video_metadata_images'),
    'video_metadata_extras': await _select(
      db,
      'video_metadata_extras',
      'work_id',
      ids.works,
    ),
  };
}

/// 子树引用到的字典行。
Future<Map<String, List<VideoClaimSqlRow>>> _readDictionaries(
  FushiDatabase db,
  Map<String, List<VideoClaimSqlRow>> tree,
) async {
  Set<Object> keys(String column, List<String> tables) => <Object>{
    for (final String table in tables)
      for (final VideoClaimSqlRow row in tree[table]!) ?row[column],
  };
  return <String, List<VideoClaimSqlRow>>{
    'video_metadata_people': await _select(
      db,
      'video_metadata_people',
      'person_key',
      keys('person_key', const <String>[
        'video_metadata_credits',
        'video_metadata_images',
      ]).toList(),
    ),
    'video_metadata_characters': await _select(
      db,
      'video_metadata_characters',
      'character_key',
      keys('character_key', const <String>[
        'video_metadata_credits',
        'video_metadata_images',
      ]).toList(),
    ),
    'video_metadata_terms': await _select(
      db,
      'video_metadata_terms',
      'term_key',
      keys('term_key', const <String>['video_metadata_work_terms']).toList(),
    ),
  };
}

Future<List<VideoClaimSqlRow>> _ledgerRows(FushiDatabase db, _TreeIds ids) =>
    _selectWhere(db, 'video_sidecar_artifacts', <(String, List<Object>)>[
      ('work_id', ids.works),
      ('season_id', ids.seasons.toList()..sort()),
      ('episode_id', ids.episodes),
    ]);

(String, List<Object?>) _scrapedImagesWhere(_UnitScope scope) {
  final List<String> owners = <String>[
    if (scope.collectionIds.isNotEmpty)
      'collection_id IN (${_marks(scope.collectionIds.length)})',
    if (scope.bookUids.isNotEmpty)
      'book_uid IN (${_marks(scope.bookUids.length)})',
  ];
  if (owners.isEmpty) return ('0', const <Object?>[]);
  return (
    '(${owners.join(' OR ')}) AND source_url IS NOT NULL',
    <Object?>[...scope.collectionIds, ...scope.bookUids],
  );
}

Future<List<VideoClaimSqlRow>> _scrapedMediaImages(
  FushiDatabase db,
  _UnitScope scope,
) async {
  final (String where, List<Object?> args) = _scrapedImagesWhere(scope);
  return <VideoClaimSqlRow>[
    for (final QueryRow row
        in await db
            .customSelect(
              'SELECT * FROM media_images WHERE $where ORDER BY id',
              variables: _vars(args),
            )
            .get())
      Map<String, Object?>.of(row.data),
  ];
}

List<String> _primaryIdentities(Map<String, List<VideoClaimSqlRow>> tree) {
  final Set<Object?> workIds = <Object?>{
    for (final VideoClaimSqlRow row in tree['video_metadata_works']!) row['id'],
  };
  return <String>[
    for (final VideoClaimSqlRow row
        in tree['video_metadata_provider_identities']!)
      if (workIds.contains(row['work_id']) &&
          (row['is_primary'] == 1 || row['is_primary'] == true))
        '${row['provider']}:${row['external_id']}',
  ]..sort();
}

List<String> _lockNames(List<VideoClaimSqlRow> works) => <String>{
  for (final VideoClaimSqlRow row in works)
    for (final String part in ('${row['locked_fields'] ?? ''}').split(','))
      if (part.trim().isNotEmpty) part.trim(),
}.toList()..sort();

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString().toLowerCase();

// ─────────────────────────────────────────────────────────────────────────
// SQL 小工具（按列名原样搬行：表加列后旧载荷照样能插回，新列取默认值）
// ─────────────────────────────────────────────────────────────────────────

/// SQLite 绑定变量上限保守取 400 一批（与 `clearAllVideoScrapeRecords` 同口径）。
const int _kBatch = 400;

String _marks(int n) => List<String>.filled(n, '?').join(', ');

List<Variable<Object>> _vars(List<Object?> args) => <Variable<Object>>[
  for (final Object? a in args) Variable<Object>(a),
];

Future<List<VideoClaimSqlRow>> _select(
  FushiDatabase db,
  String table,
  String column,
  List<Object> values,
) => _selectWhere(db, table, <(String, List<Object>)>[(column, values)]);

/// `column IN (…) OR …`，逐列分批，按 rowid 去重排序。
Future<List<VideoClaimSqlRow>> _selectWhere(
  FushiDatabase db,
  String table,
  List<(String, List<Object>)> predicates,
) async {
  final Map<int, VideoClaimSqlRow> rows = <int, VideoClaimSqlRow>{};
  for (final (String column, List<Object> values) in predicates) {
    for (int i = 0; i < values.length; i += _kBatch) {
      final List<Object> chunk = values.sublist(
        i,
        i + _kBatch < values.length ? i + _kBatch : values.length,
      );
      for (final QueryRow row
          in await db
              .customSelect(
                'SELECT rowid AS "__rowid", * FROM $table '
                'WHERE "$column" IN (${_marks(chunk.length)})',
                variables: _vars(chunk),
              )
              .get()) {
        final Map<String, Object?> data = Map<String, Object?>.of(row.data);
        final int rowid = data.remove('__rowid')! as int;
        rows[rowid] = data;
      }
    }
  }
  final List<int> order = rows.keys.toList()..sort();
  return <VideoClaimSqlRow>[for (final int id in order) rows[id]!];
}

Future<void> _delete(
  FushiDatabase db,
  String table,
  String column,
  List<Object> values,
) async {
  for (int i = 0; i < values.length; i += _kBatch) {
    final List<Object> chunk = values.sublist(
      i,
      i + _kBatch < values.length ? i + _kBatch : values.length,
    );
    await db.customStatement(
      'DELETE FROM $table WHERE "$column" IN (${_marks(chunk.length)})',
      chunk,
    );
  }
}

Future<void> _insert(FushiDatabase db, String table, VideoClaimSqlRow row) {
  final List<String> columns = row.keys.toList();
  return db.customStatement(
    'INSERT INTO $table (${columns.map((String c) => '"$c"').join(', ')}) '
    'VALUES (${_marks(columns.length)})',
    <Object?>[for (final String c in columns) row[c]],
  );
}

Future<void> _update(
  FushiDatabase db,
  String table,
  String keyColumn,
  VideoClaimSqlRow row,
) {
  final List<String> columns = <String>[
    for (final String c in row.keys)
      if (c != keyColumn) c,
  ];
  if (columns.isEmpty) return Future<void>.value();
  return db.customStatement(
    'UPDATE $table SET ${columns.map((String c) => '"$c" = ?').join(', ')} '
    'WHERE "$keyColumn" = ?',
    <Object?>[for (final String c in columns) row[c], row[keyColumn]],
  );
}

Object? _encodeValue(Object? value) => value is Uint8List
    ? <String, Object?>{r'$b64': base64Encode(value)}
    : value;

Object? _decodeValue(Object? value) => value is Map && value[r'$b64'] is String
    ? base64Decode(value[r'$b64']! as String)
    : value;
