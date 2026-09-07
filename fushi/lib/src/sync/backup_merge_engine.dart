import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi/src/media/override_title_key.dart';
import 'package:fushi/src/sync/aggregate_merge_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart' show FavoriteSentence;
import 'package:fushi_core/fushi_core.dart';

/// ATTACH-then-upsert merge engine for backup "merge" import (TODO-888).
///
/// The current device DB is the live target; a backup DB (already migrated to
/// the current schema and ATTACHed as [_srcAlias]) is the source. Every table
/// is merged row-by-row by its BUSINESS key, never by autoincrement `id` (two
/// DBs' ids collide and carry no cross-device meaning). The whole run executes
/// inside ONE [FushiDatabase.transaction] so a mid-merge failure rolls the
/// target back to byte-for-byte its pre-merge state (the caller also keeps a
/// `pre-merge.bak` copy as a belt-and-braces net).
///
/// Conflict resolution mirrors the existing sync semantics:
/// - content lists (books / videos / dictionaries / audio) -> push-only UNION.
/// - progress (reader positions) -> LWW by `updatedAt` (larger wins).
/// - statistics (reading / video / hourly / mining / lookup+mine counters) ->
///   per-bucket MAX-union, so re-importing the same backup is idempotent and
///   never double-counts.
/// - favorites / mined sentences / activity events -> dedupe-UNION (both kept,
///   duplicates dropped). galgame_sessions deliberately do NOT merge (their
///   `galgames` hosts are machine-local and never travel; see merge()).
/// - favorite SENTENCES (a `favorite_sentences` preference JSON blob, NOT a
///   table) -> content dedupe-UNION, delegated to [AggregateMergeService] (the
///   ATTACH SQL cannot merge a JSON blob, so this used to be dropped entirely).
/// - tags / profiles -> UNION by name with cross-DB id REMAPPING for every child
///   row referencing the autoincrement id.
///
/// The aggregate MAX-union / dedupe-union families are the relational
/// projection of the pure folds defined in [AggregateMergeService]; that class
/// is the single source of truth for those semantics and is what online sync
/// (TODO-1056 phase B/C) calls directly on materialised snapshots. The
/// favorite-sentence pref blob is merged here by literally calling that pure
/// service, so its logic lives in exactly one place.
///
/// Device-local rows are deliberately skipped: `media_sources` (device-local
/// scan paths), `sync_baselines` (would corrupt later incremental sync fork
/// detection), the five durable video-download tables (backend fingerprints,
/// local paths and schedule leases), and device-local sync prefs
/// ([SyncRepository.deviceLocalPrefKeys]).
class BackupMergeEngine {
  BackupMergeEngine(
    this._db, {
    String srcAlias = 'mergesrc',
    Set<String> carriedVideoSourcePaths = const <String>{},
    Set<String>? enabledCategoryNames,
    bool adoptSourcePreferences = false,
  })  : _srcAlias = srcAlias,
        _carriedVideoSourcePaths = carriedVideoSourcePaths,
        _enabledCategoryNames = enabledCategoryNames,
        _adoptSourcePreferences = adoptSourcePreferences;

  final FushiDatabase _db;
  final String _srcAlias;

  /// 是否把源库的 `preferences` 整体接管过来（**只有同机换包名的迁移**该开）。
  ///
  /// 平时关着是对的：备份 merge 的语义是「把**另一台**设备的内容并进来，不动
  /// 本机设置」。但迁移不是那个场景——它是同一台机器、同一个用户、只换了包名，
  /// 用户期望「一切原样搬过来」。关着的后果是实测过的：11.4GB 库迁移成功后
  /// `preferences` 只剩 21 行，且没有一条是用户设置（阅读器、视频、Anki、
  /// 快捷键、界面、互联、同步后端全丢），因为下面那四处点名的 pref 合并
  /// （收藏句 / 有声书位置 / 音频来源 / 书名 override）就是 merge 对
  /// `preferences` 的全部处理，
  /// 而迁移声明的 `BackupCategory.settings` 在这条路径上从来没有消费方。
  final bool _adoptSourcePreferences;

  /// Per-category merge gate (the `BackupCategory.name`s the user kept ticked in
  /// the import dialog); null = merge every category (legacy full merge). Only
  /// the user-facing content categories are gated here — favorites / tags /
  /// profiles / history rows have no dialog toggle and always merge.
  final Set<String>? _enabledCategoryNames;

  /// Whether category [name] (a `BackupCategory.name`) should be merged.
  bool _wants(String name) =>
      _enabledCategoryNames == null || _enabledCategoryNames.contains(name);

  /// Source-device absolute video paths whose file actually travelled inside the
  /// backup (= `BackupMeta.videoFiles.keys`). A merged `video_books` row is only
  /// materialised when it is REACHABLE on this device: either a streaming book
  /// (its `video_path` is an `http(s)` URL, self-contained — re-opens by URL) or
  /// a local-file book whose file is in this set (so `_copyTreeIfAbsent` lands it
  /// and `_rebaseVideoPaths` re-points it). A local video whose file never
  /// travelled would otherwise import as a dead "empty video" shell that can
  /// never play (TODO-1261). The preview counter applies the SAME predicate so
  /// the confirm dialog's "will add N" matches what the merge actually inserts.
  final Set<String> _carriedVideoSourcePaths;

  /// SQL fragment (on the src alias `s`) selecting only REACHABLE video rows —
  /// streaming URLs plus local files carried by the backup. Empty carried set →
  /// streaming only. Callers append this to the row's own NOT EXISTS guard.
  String get _reachableVideoPredicate {
    final StringBuffer buf = StringBuffer(
      "(s.video_path LIKE 'http://%' OR s.video_path LIKE 'https://%'",
    );
    if (_carriedVideoSourcePaths.isNotEmpty) {
      final String placeholders =
          List<String>.filled(_carriedVideoSourcePaths.length, '?').join(', ');
      buf.write(' OR s.video_path IN ($placeholders)');
    }
    buf.write(')');
    return buf.toString();
  }

  /// Positional args matching the `?` placeholders in [_reachableVideoPredicate]
  /// (the carried local-file paths, in a stable order). Same order as the set is
  /// iterated when the predicate's placeholders are built.
  List<String> get _reachableVideoArgs => _carriedVideoSourcePaths.toList();

  /// Preference key holding the favorite-sentence JSON list. Mirrors
  /// `FavoriteSentenceRepository._key`; kept in sync behaviourally by
  /// `favorite_sentence_merge_import_test.dart`.
  static const String _favoriteSentencesPrefKey = 'favorite_sentences';

  /// Content-config preference keys carrying the local-audio registry (their
  /// referenced `.db` files travel in the backup), merged by
  /// [_mergeAudioSourcePrefs] instead of being dropped as device settings.
  static const List<String> _audioSourcePrefKeys = <String>[
    'local_audio_dbs',
    'audio_source_configs',
  ];

  /// Runs the whole merge inside a single transaction. The backup DB must
  /// already be ATTACHed as [_srcAlias] on [_db]'s connection by the caller.
  Future<void> merge() async {
    await _db.transaction(() async {
      // Content categories are gated by the import dialog's per-category
      // selection (merge mode). Rows with no dialog toggle (favorites / tags /
      // profiles / history / collections) always merge — they carry no bulk
      // content and their FK/EXISTS guards no-op harmlessly when their owners
      // were skipped.
      if (_wants('books')) {
        await _insertMissingEpubBooks();
        // srt_books dedups on `uid` but must honour the deleted book's tombstone
        // via its own `book_key` — else deleting a book then merging an old
        // backup resurrects an orphan srt row (no epub) = an "empty book".
        await _insertMissing('srt_books', 'uid',
            skipBookTombstones: true, tombstoneKeyColumn: 'book_key');
      }
      if (_wants('videos')) await _insertMissingVideoBooks();
      if (_wants('dictionary')) {
        await _insertMissing('dictionary_metadata', 'name');
      }
      if (_wants('audiobooks')) {
        await _insertMissing('audiobooks', 'book_key',
            skipBookTombstones: true);
        await _insertAudioCues();
      }
      // Media collections (unified-collections Phase 5) have no dialog toggle:
      // always merge the grouping itself; orphan members are kept and folded in
      // the UI. Self-guards against missing src tables (pre-migration backups).
      await _mergeMediaCollections();
      if (_wants('progress')) await _mergeReaderPositions();
      if (_wants('statistics')) {
        await _mergeReadingStatistics();
        await _mergeVideoWatchStatistics();
        // 阅读时段表 v67 起多一维 format（备份 DB 在 ATTACH 前已迁到当前
        // schema，两侧必有此列）；视频时段表仍是 {dateKey, hour} 两维。
        await _mergeHourlyLogs('reading_hourly_logs', 'reading_time_ms',
            keyColumns: const <String>['date_key', 'hour', 'format']);
        await _mergeHourlyLogs('video_hourly_logs', 'watch_time_ms',
            keyColumns: const <String>['date_key', 'hour']);
        await _mergeMiningStatistics();
        await _mergeLookupMiningCounters();
        await _mergeFavoriteWords();
        await _mergeMinedSentences();
        await _mergeActivityEvents();
        // v92：学习事实段按 uid LWW + 按身份墓碑（与 legacy 统计家族并行、互不触碰）。
        await _mergeStudySegments();
        // galgame_sessions 刻意不合并（成文决策，不是遗漏）：游戏是本机局域
        // 身份，galgames 行本身就不搬运（见 tables.dart 的 GalgameTagMappings
        // 注释——整套游戏数据不进 live-sync 也不进备份合并导入，全量备份恢复
        // 走整库文件拷贝原样还原），src 会话行的 game_id 在目标库没有宿主，
        // 并进来只会造出悬空引用。唯一例外是游戏标签：它经刮削身份二跳落到
        // 目标库自己的游戏行上（[_mergeTagsAndMappings] 的 v79 二跳）。
      }
      await _mergeFavoriteSentencePrefs();
      await _mergeTagsAndMappings();
      await _mergeCollectionTags();
      await _mergeProfilesAndChildren();
      // v80：media_items → media_open_history，PK 是 (media_source, media_id)
      // 双列，_insertMissing 的单键形装不下，展开写。
      await _db.customStatement(
        'INSERT INTO media_open_history '
        '(media_type, media_source, media_id, opened_at, position, duration, '
        'snapshot_json) '
        'SELECT media_type, media_source, media_id, opened_at, position, '
        'duration, snapshot_json FROM $_srcAlias.media_open_history AS s '
        'WHERE NOT EXISTS (SELECT 1 FROM media_open_history AS t '
        'WHERE t.media_source = s.media_source AND t.media_id = s.media_id)',
      );
      await _insertMissing('search_history_items', 'unique_key');
      await _insertMissing('anki_mappings', 'label');
      if (_wants('progress')) {
        await _mergeBookmarks();
        await _mergeAudiobookPositionPrefs();
      }
      // v82：书自定义 CSS / 图片揭开状态（uid 键 LWW）。无 dialog toggle——
      // 存在性 guard 让「书没随备份来」时自然 no-op（与 collections/tags 同规）。
      await _mergeBookCustomCss();
      await _mergeRevealedImages();
      // BUG-1488：用户给书改的名字（override_title pref）是内容，跟着书走。
      await _mergeOverrideTitlePrefs();
      if (_wants('localAudio')) await _mergeAudioSourcePrefs();
      // 迁移专用，放在全部点名 pref 合并之后：那几处是「按内容语义合并」（可能
      // 覆盖/取较新），这里只补它们没管的 key，不能反过来盖掉它们的结果。
      if (_adoptSourcePreferences) await _adoptMissingPreferences();
    });
  }

  /// 把源库里**本机还没有**的 `preferences` 行补进来（insert-if-absent）。
  ///
  /// 只补不覆盖是刻意的，而且是这个操作能安全存在的前提：目标库是刚建的新包，
  /// 已经写入了属于**它自己**的标记（`prefs_version`、`first_time_setup`、
  /// `active_profile_id`、各种 `*_migrated`）。这些描述的是「本库处于什么状态」，
  /// 拿老包的值去盖会让新库自称成另一个 schema 状态，是真正会毁库的一步。
  /// `NOT EXISTS` 守卫天然把它们挡在外面，同时放行老包独有的用户设置。
  Future<void> _adoptMissingPreferences() async {
    await _db.customStatement(
      'INSERT INTO preferences ("key", "value") '
      'SELECT s."key", s."value" FROM $_srcAlias.preferences AS s '
      'WHERE NOT EXISTS '
      '(SELECT 1 FROM preferences AS t WHERE t."key" = s."key")',
    );
  }

  /// Read-only estimate of what [merge] would change, for the import confirm
  /// dialog (TODO-1195 part B). Runs no mutations and opens no transaction, so
  /// the caller may ATTACH the backup DB to the LIVE connection and call this
  /// before deciding to import. Counts the user-meaningful deltas: books that
  /// would newly appear (epub + video + audiobook, excluding tombstoned keys)
  /// and reading positions that would be inserted or advanced by LWW.
  Future<BackupMergePreview> preview() async {
    final int epub =
        await _countMissing('epub_books', 'book_key', skipBookTombstones: true);
    final int video = await _countMissingVideoBooks();
    final int audio =
        await _countMissing('audiobooks', 'book_key', skipBookTombstones: true);
    final int positions = await _countReaderPositionChanges();
    return BackupMergePreview(
      newEpubBooks: epub,
      newVideoBooks: video,
      newAudiobooks: audio,
      updatedReaderPositions: positions,
    );
  }

  /// Counts src rows whose [keyColumn] is absent from the target (and, when
  /// [skipBookTombstones], not tombstoned) — mirrors [_insertMissing]'s WHERE.
  Future<int> _countMissing(
    String table,
    String keyColumn, {
    bool skipBookTombstones = false,
  }) async {
    final String tombstoneGuard = skipBookTombstones
        ? 'AND s.$keyColumn NOT IN (SELECT book_key FROM book_tombstones) '
        : '';
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.$table AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
          'WHERE t.$keyColumn = s.$keyColumn) $tombstoneGuard',
        )
        .getSingle();
    return row.data['c'] as int;
  }

  /// Counts `video_books` rows the merge would ADD: absent from the target AND
  /// REACHABLE ([_reachableVideoPredicate]) — streaming books or local files the
  /// backup carried. Mirrors [_insertMissingVideoBooks]'s WHERE exactly so the
  /// preview's "will add N" equals what the merge actually inserts (TODO-1261).
  Future<int> _countMissingVideoBooks() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.video_books AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM video_books AS t '
          'WHERE t.book_uid = s.book_uid) '
          'AND $_reachableVideoPredicate',
          variables: _reachableVideoArgs
              .map((String p) => Variable<String>(p))
              .toList(),
        )
        .getSingle();
    return row.data['c'] as int;
  }

  /// v82 双侧 JOIN 换键：src 子表行的 book_uid（源库随机 uid）经
  /// src.epub_books（uid→book_key）→ 本库 epub_books（book_key→uid）换成本库
  /// uid。JOIN 不上（SRT 等非 epub 域，两库键同为派生串仍可比；或书还没插进
  /// 来）COALESCE 回落原值。表达式内的 `s` 是调用方 SQL 里的 src 行别名。
  String get _srcBookUidRekey =>
      "COALESCE((SELECT tb.uid FROM epub_books AS tb WHERE tb.uid != '' "
      'AND tb.book_key = (SELECT sb.book_key FROM $_srcAlias.epub_books AS sb '
      'WHERE sb.uid = s.book_uid)), s.book_uid)';

  /// 墓碑 guard 键仍冻结在 book_key：src 行的 uid 反查 src 库 book_key，
  /// 非 epub 域回落键值本身。
  String get _srcBookKeyForTombstone =>
      'COALESCE((SELECT sb.book_key FROM $_srcAlias.epub_books AS sb '
      'WHERE sb.uid = s.book_uid), s.book_uid)';

  /// Counts reader positions the merge would touch: a src book the target lacks
  /// (new) or a src position strictly newer than the target's (LWW update).
  /// 与 [_mergeReaderPositions] 逐字镜像（含换键表达式）。
  Future<int> _countReaderPositionChanges() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.reader_positions AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM reader_positions AS t '
          'WHERE t.book_uid = $_srcBookUidRekey) '
          'OR EXISTS (SELECT 1 FROM reader_positions AS t '
          'WHERE t.book_uid = $_srcBookUidRekey '
          'AND s.updated_at > t.updated_at)',
        )
        .getSingle();
    return row.data['c'] as int;
  }

  /// Column names of [table] excluding autoincrement `id` (so INSERT...SELECT
  /// lets SQLite assign fresh ids). Both DBs are at the current schema so the
  /// target's column set matches src.
  Future<List<String>> _columnsExceptId(String table) async {
    final rows = await _db.customSelect('PRAGMA table_info($table)').get();
    return rows
        .map((r) => r.data['name'] as String)
        .where((String c) => c != 'id')
        // Quote identifiers so SQL reserved words (order / key / value / ...)
        // used as column names don't break the generated statements.
        .map((String c) => '"$c"')
        .toList();
  }

  /// UNION push-only: insert every src row whose [keyColumn] value is not
  /// already present in the target. Explicit column list (minus `id`) so SQLite
  /// assigns fresh autoincrement ids and never reuses the src id.
  ///
  /// [skipBookTombstones] additionally excludes any src row whose book key is
  /// tombstoned in the target — i.e. the user deleted that book on this device,
  /// so an old backup must never resurrect it (TODO-1195 part B). The tombstoned
  /// column is [keyColumn] by default, but a table that dedups on a non-book-key
  /// column (e.g. `srt_books` dedups on `uid` yet carries its own `book_key`)
  /// passes [tombstoneKeyColumn] so the guard still matches `book_tombstones`.
  /// Overwrite import does not go through here.
  Future<void> _insertMissing(
    String table,
    String keyColumn, {
    bool skipBookTombstones = false,
    String? tombstoneKeyColumn,
  }) async {
    final List<String> cols = await _columnsExceptId(table);
    final String colList = cols.join(', ');
    final String tombCol = tombstoneKeyColumn ?? keyColumn;
    final String tombstoneGuard = skipBookTombstones
        ? 'AND s.$tombCol NOT IN (SELECT book_key FROM book_tombstones) '
        : '';
    await _db.customStatement(
      'INSERT INTO $table ($colList) '
      'SELECT $colList FROM $_srcAlias.$table AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
      'WHERE t.$keyColumn = s.$keyColumn) $tombstoneGuard',
    );
  }

  /// epub_books 专用 insert-missing（v82）：uid 列不能直搬——两库各自生成的
  /// `book_<rowid>_<epoch>` 形 uid 可能撞本库 partial 唯一索引，撞上会炸掉整个
  /// merge 事务。撞时按同命名空间重生成（src rowid + 当前 epoch + `_m` 后缀，
  /// 批内唯一；万一再撞由唯一索引大声失败，绝不静默错配）。
  Future<void> _insertMissingEpubBooks() async {
    final List<String> cols = await _columnsExceptId('epub_books');
    final String colList = cols.join(', ');
    final String selList = cols.map((String c) {
      if (c != '"uid"') return 's.$c';
      return "CASE WHEN s.uid != '' AND EXISTS "
          '(SELECT 1 FROM epub_books AS e WHERE e.uid = s.uid) '
          "THEN 'book_' || s.rowid || '_' || strftime('%s','now') || '_m' "
          'ELSE s.uid END';
    }).join(', ');
    await _db.customStatement(
      'INSERT INTO epub_books ($colList) '
      'SELECT $selList FROM $_srcAlias.epub_books AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM epub_books AS t '
      'WHERE t.book_key = s.book_key) '
      'AND s.book_key NOT IN (SELECT book_key FROM book_tombstones)',
    );
  }

  /// Inserts every backup `video_books` row the target lacks, but ONLY when it
  /// is REACHABLE on this device ([_reachableVideoPredicate]): a streaming book
  /// (self-contained http(s) URL) or a local file the backup actually carried.
  /// A local-file video whose file never travelled is skipped so it never lands
  /// as a dead "empty video" shell that can't play (TODO-1261). `video_books`
  /// has no autoincrement id (PK is `book_uid`), so every column travels.
  Future<void> _insertMissingVideoBooks() async {
    final List<String> cols = await _columnsExceptId('video_books');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO video_books ($colList) '
      'SELECT $colList FROM $_srcAlias.video_books AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM video_books AS t '
      'WHERE t.book_uid = s.book_uid) '
      'AND $_reachableVideoPredicate',
      _reachableVideoArgs,
    );
  }

  /// media_collections + media_collection_items 合并（统一合集 Phase 5）。合集主键是
  /// 自增 `id`，跨库必冲突，故不能像其它表那样 INSERT...SELECT 直搬——按自然键
  /// (name, collection_type) 幂等对齐：src 合集若目标已有同名同类型则复用其 id，否则
  /// 新插得新 id；再把 src 成员的 collection_id 经 src→target id 映射改写后
  /// INSERT OR IGNORE（成员复合主键 {collection_id, media_type, entry_key} 天然去重）。
  ///
  /// 尊重本地成员/合集墓碑（多端库联合视图 §2.3 任务7，同书墓碑 [_insertMissing]
  /// `skipBookTombstones` 一律「旧备份不复活已删」）：本地 `collection_member_tombstones`
  /// 是「用户在本设备移出某成员 / 删除某合集」的证据。备份是（通常更旧的）快照且
  /// **不带成员的时间证据**（成员行无 addedAt），故本地墓碑直接生效——
  /// - 命中成员移出墓碑（同自然键 + media_type + entry_key）的 src 成员：跳过不插入
  ///   （否则并入会复活用户已移出的成员，与在线合集同步的移出墓碑防复活同一律）；
  /// - 命中合集级删除墓碑（空哨兵行，同自然键）的整个 src 合集：跳过——不新建目标
  ///   合集、不映射其 id、不插入其任何成员（否则复活用户已删的合集）。
  /// 用户日后可手动重加成员 / 重建合集（[FushiDatabase.addToCollection] /
  /// [FushiDatabase.createMediaCollection] 会清对应墓碑），撤销「不复活」。
  ///
  /// 说明：备份 DB 已在 ATTACH 前迁到当前 schema，故其 series/playlist 已经过 v38
  /// 迁移落进 media_collections，这里搬的就是「合集分组」本身。孤儿成员引用（其条目文件
  /// 未随备份到达、未插入 target）保留不删——UI 折叠时按实际条目跳过孤儿，日后条目补回
  /// 即自动归位（保留用户分组意图）。
  Future<void> _mergeMediaCollections() async {
    if (!await _srcTableExists('media_collections') ||
        !await _srcTableExists('media_collection_items')) {
      return; // 迁移前的旧备份无合集表：无可合并。
    }
    final List<QueryRow> srcCols = await _db
        .customSelect(
          'SELECT id, name, collection_type, cover_source, sort_order, '
          'created_at FROM $_srcAlias.media_collections',
        )
        .get();
    if (srcCols.isEmpty) return;

    // v83：成员表 epub 域 entry_key = 各库自己的 epub_books.uid（本地书）或对端
    // bookKey（透传行）。uid 是每库随机生成的本机局域串，跨库直搬必错——照
    // Stage 1b 的 [_srcBookUidRekey] 双侧换键，但本函数是 Dart 逐行循环，改用两
    // 张查表 map。本 map 在 [_insertMissingEpubBooks] **之后**构建（merge() 顺序
    // 保证）：src 书刚插进本库（含 uid 撞库重生成 `_m` 后缀的）也在映射里，成员
    // 自动 remap 到重生成后的 uid。仅 mediaType=='epub' 门控——srt/video/game
    // 键天然稳定，误换算即数据损坏。
    final Map<String, String> srcBookKeyByUid = <String, String>{};
    if (await _srcTableExists('epub_books')) {
      for (final QueryRow r in await _db
          .customSelect('SELECT uid, book_key FROM $_srcAlias.epub_books')
          .get()) {
        final String uid = r.read<String>('uid');
        if (uid.isNotEmpty) srcBookKeyByUid[uid] = r.read<String>('book_key');
      }
    }
    final Map<String, String> localUidByBookKey = <String, String>{};
    for (final QueryRow r in await _db
        .customSelect("SELECT uid, book_key FROM epub_books WHERE uid != ''")
        .get()) {
      localUidByBookKey[r.read<String>('book_key')] = r.read<String>('uid');
    }
    // epub 键归一到 bookKey 域（墓碑匹配用——本地成员墓碑冻结在 bookKey 域）：
    // src uid → src bookKey；查不上 = entry_key 本就在 bookKey 域（src 的透传行）
    // 或 src 书已删的游离 uid，照抄。uid 值域 `book_<rowid>_<epoch>[_m]` 与
    // bookKey 值域 sanitize(title) 仅在病态标题恰为 `book_<n>_<n>` 形时碰撞
    // （§7.4 已记：概率忽略）。
    String normalizeEpubToBookKey(String entryKey) =>
        srcBookKeyByUid[entryKey] ?? entryKey;
    // epub 三级回落换键（落库用）：本库有书 → 本库 uid；本库无书 → 回落
    // bookKey 域（保持 wire 可续接，日后 sync/下载落地自动收敛）；src 也无书行
    // → 照抄原值。无需 uid 撞库防线追加：成员表无 uid 唯一索引（复合 PK
    // INSERT OR IGNORE 天然去重），epub_books 的 uid 重生成防线 Stage 1b 已做。
    String rekeyEpubEntryKey(String entryKey) {
      final String bookKey = normalizeEpubToBookKey(entryKey);
      return localUidByBookKey[bookKey] ?? bookKey;
    }

    // 本地墓碑（防复活，任务7）：合集级删除哨兵按自然键 (name, type)、成员移出墓碑按
    // (name, type, mediaType, entryKey)。用 record 集合（结构相等），避免拼接分隔符歧义。
    // 备份 DB 早于该表 schema 时无此表（防 SELECT 崩溃）——空集即无墓碑约束。
    final Set<(String, String)> deletedCollectionKeys = <(String, String)>{};
    final Set<(String, String, String, String)> removedMemberKeys =
        <(String, String, String, String)>{};
    if (await _tableExists('collection_member_tombstones')) {
      final List<QueryRow> tombs = await _db
          .customSelect(
            'SELECT collection_name, collection_type, media_type, entry_key '
            'FROM collection_member_tombstones',
          )
          .get();
      for (final QueryRow t in tombs) {
        final String name = t.read<String>('collection_name');
        final String type = t.read<String>('collection_type');
        final String mediaType = t.read<String>('media_type');
        final String entryKey = t.read<String>('entry_key');
        // 空哨兵 (media_type=='' && entry_key=='') = 合集级删除墓碑。
        if (mediaType.isEmpty && entryKey.isEmpty) {
          deletedCollectionKeys.add((name, type));
        } else {
          removedMemberKeys.add((name, type, mediaType, entryKey));
        }
      }
    }

    // 目标现有 (name, collection_type) → id，用于幂等对齐。
    final List<QueryRow> tgtCols = await _db
        .customSelect('SELECT id, name, collection_type FROM media_collections')
        .get();
    final Map<String, int> targetIdByKey = <String, int>{
      for (final QueryRow r in tgtCols)
        _collectionKey(
          r.read<String>('name'),
          r.read<String>('collection_type'),
        ): r.read<int>('id'),
    };
    int nextSort = await _nextTargetCollectionSortOrder();

    // src.id → target.id 映射（复用或新插）。命中合集级删除墓碑的 src 合集直接跳过：
    // 不建目标合集、不映射 id（下面成员循环因 srcToTargetId 缺键连带跳过其全部成员）。
    final Map<int, int> srcToTargetId = <int, int>{};
    // src.id → 合集自然键 (name, type)，成员循环查成员墓碑用（record，避免拼接歧义）。
    final Map<int, (String, String)> srcIdToNatural = <int, (String, String)>{};
    for (final QueryRow c in srcCols) {
      final int srcId = c.read<int>('id');
      final String name = c.read<String>('name');
      final String type = c.read<String>('collection_type');
      srcIdToNatural[srcId] = (name, type);
      if (deletedCollectionKeys.contains((name, type))) {
        continue; // 合集级删除墓碑命中：整个合集跳过（防复活已删合集）。
      }
      final String key = _collectionKey(name, type);
      final int? existing = targetIdByKey[key];
      if (existing != null) {
        srcToTargetId[srcId] = existing;
        continue;
      }
      // v83：cover_source='<mediaType>|<entryKey>' 是隐藏 entryKey 载体（合集借
      // 成员封面，tables.dart:841）。epub 借用键与成员行同律换键，否则借用断链、
      // 封面静默回退占位（§7 风险5）。非 epub 前缀（video|/srt|/game|、NULL）
      // 原样直搬。目标已有同名合集时不走此分支，保留目标自己的 cover_source。
      final String? srcCover = c.read<String?>('cover_source');
      final String epubCoverPrefix = '${MediaKind.epub.dbValue}|';
      final String? coverForInsert =
          (srcCover != null && srcCover.startsWith(epubCoverPrefix))
              ? epubCoverPrefix +
                  rekeyEpubEntryKey(srcCover.substring(epubCoverPrefix.length))
              : srcCover;
      final int newId = await _db.customInsert(
        'INSERT INTO media_collections '
        '(name, collection_type, cover_source, sort_order, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: <Variable<Object>>[
          Variable<String>(name),
          Variable<String>(type),
          // cover_source 可空：Variable<String> 接受 null 值 → 落 SQL NULL。
          Variable<String>(coverForInsert),
          Variable<int>(nextSort++),
          Variable<int>(c.read<int>('created_at')),
        ],
      );
      srcToTargetId[srcId] = newId;
      targetIdByKey[key] = newId;
    }

    // 成员：collection_id 经映射改写后 INSERT OR IGNORE（复合主键去重）。命中本地成员
    // 移出墓碑（同自然键 + 成员键）的成员跳过——防旧备份复活用户已移出的成员（任务7）。
    final List<QueryRow> srcItems = await _db
        .customSelect(
          'SELECT collection_id, media_type, entry_key, sort_index '
          'FROM $_srcAlias.media_collection_items',
        )
        .get();
    for (final QueryRow it in srcItems) {
      final int srcCollectionId = it.read<int>('collection_id');
      final int? tgt = srcToTargetId[srcCollectionId];
      if (tgt == null) continue; // 合集被删除墓碑跳过或未映射：连带跳过成员。
      final String mediaType = it.read<String>('media_type');
      final String entryKey = it.read<String>('entry_key');
      final bool isEpub = mediaType == MediaKind.epub.dbValue;
      // 墓碑匹配在 bookKey 域：本地成员墓碑 entry_key 冻结在 bookKey 域（§4），
      // src epub 成员先归一再比；非 epub 键值自身即稳定键，直比。
      final String tombstoneKey =
          isEpub ? normalizeEpubToBookKey(entryKey) : entryKey;
      final (String, String)? natural = srcIdToNatural[srcCollectionId];
      if (natural != null &&
          removedMemberKeys
              .contains((natural.$1, natural.$2, mediaType, tombstoneKey))) {
        continue; // 成员移出墓碑命中：跳过（防复活已移出成员）。
      }
      // 落库键：epub 三级回落换到本库键域；同书的 uid 行与透传 bookKey 行换键后
      // 可能收敛为同一键——复合 PK 上的 INSERT OR IGNORE 顺带去重。
      await _db.customStatement(
        'INSERT OR IGNORE INTO media_collection_items '
        '(collection_id, media_type, entry_key, sort_index) '
        'VALUES (?, ?, ?, ?)',
        <Object?>[
          tgt,
          mediaType,
          isEpub ? rekeyEpubEntryKey(entryKey) : entryKey,
          it.read<int>('sort_index'),
        ],
      );
    }
  }

  /// 目标（当前设备）DB 是否有名为 [table] 的表。与 [_srcTableExists] 对称，但查
  /// 目标库 `sqlite_master`（合集墓碑表 collection_member_tombstones 是本地防复活证据；
  /// merge 前两库都已迁到当前 schema，正常必有此表——防御性判存，与 src 侧同纪律）。
  Future<bool> _tableExists(String table) async {
    final QueryRow? row = await _db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: <Variable<Object>>[Variable<String>(table)],
    ).getSingleOrNull();
    return row != null;
  }

  /// 自然键：name 与 collection_type 以 NUL 分隔（两者都不含 NUL），避免拼接歧义。
  static String _collectionKey(String name, String type) => '$name\u0000$type';

  /// 目标 media_collections 的下一个 sort_order（现有最大 +1，空表 0）。
  Future<int> _nextTargetCollectionSortOrder() async {
    final QueryRow row = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS m FROM media_collections',
        )
        .getSingle();
    return row.read<int>('m') + 1;
  }

  /// src(备份)库是否有名为 [table] 的表（防旧备份缺合集表时 SELECT 崩溃）。
  Future<bool> _srcTableExists(String table) async {
    final QueryRow? row = await _db.customSelect(
      'SELECT 1 FROM $_srcAlias.sqlite_master '
      "WHERE type = 'table' AND name = ?",
      variables: <Variable<Object>>[Variable<String>(table)],
    ).getSingleOrNull();
    return row != null;
  }

  /// AudioCues: import only cues for book_keys with no existing cues in the
  /// target (idempotent, no duplicate streams).
  Future<void> _insertAudioCues() async {
    final List<String> cols = await _columnsExceptId('audio_cues');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO audio_cues ($colList) '
      'SELECT $colList FROM $_srcAlias.audio_cues AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM audio_cues AS t '
      'WHERE t.book_key = s.book_key) '
      // TODO-1195 part B: never bring back a deleted book's cues.
      'AND s.book_key NOT IN (SELECT book_key FROM book_tombstones)',
    );
  }

  /// Reader positions LWW: a src row wins only when the target lacks a row for
  /// that book(uid), or the src `updated_at` is strictly greater. v82 起
  /// book_uid 经 [_srcBookUidRekey] 双侧换键（两库随机 uid 不可直比）。
  Future<void> _mergeReaderPositions() async {
    final List<String> cols = await _columnsExceptId('reader_positions');
    final String colList = cols.join(', ');
    final String selList = cols
        .map((String c) => c == '"book_uid"' ? _srcBookUidRekey : 's.$c')
        .join(', ');
    await _db.customStatement(
      'INSERT INTO reader_positions ($colList) '
      'SELECT $selList FROM $_srcAlias.reader_positions AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM reader_positions AS t '
      'WHERE t.book_uid = $_srcBookUidRekey) '
      // TODO-1195 part B: never re-add a deleted book's reading position.
      'AND $_srcBookKeyForTombstone NOT IN '
      '(SELECT book_key FROM book_tombstones)',
    );
    final String setClause = cols
        .where((String c) => c != '"book_uid"')
        .map((String c) => '$c = ('
            'SELECT s.$c FROM $_srcAlias.reader_positions AS s '
            'WHERE $_srcBookUidRekey = reader_positions.book_uid)')
        .join(', ');
    await _db.customStatement(
      'UPDATE reader_positions SET $setClause '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.reader_positions AS s '
      'WHERE $_srcBookUidRekey = reader_positions.book_uid '
      'AND s.updated_at > reader_positions.updated_at)',
    );
  }

  /// ReadingStatistics MAX-union per {title, dateKey} bucket. Grouping is by
  /// {title, date_key} so a dateKey with many titles is never folded into one.
  Future<void> _mergeReadingStatistics() async {
    await _db.customStatement(
      'INSERT INTO reading_statistics '
      '(title, date_key, characters_read, reading_time_ms, '
      'last_statistic_modified) '
      'SELECT title, date_key, characters_read, reading_time_ms, '
      'last_statistic_modified FROM $_srcAlias.reading_statistics AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM reading_statistics AS t '
      'WHERE t.title = s.title AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该书统计（book 墓碑）→ 旧备份不得复活它。
      'AND s.title NOT IN (SELECT title FROM statistics_tombstones '
      "WHERE source_type = 'book')",
    );
    await _db.customStatement(
      'UPDATE reading_statistics SET '
      'characters_read = MAX(characters_read, ('
      'SELECT s.characters_read FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)), '
      'reading_time_ms = MAX(reading_time_ms, ('
      'SELECT s.reading_time_ms FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)), '
      'last_statistic_modified = MAX(last_statistic_modified, ('
      'SELECT s.last_statistic_modified FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)',
    );
  }

  /// VideoWatchStatistics MAX-union。v39 合并键 = (mergeKey, dateKey)，其中
  /// mergeKey = book_uid（新行）/ 'title:'+title（迁移遗留 NULL-uid 行回退）——
  /// 同名不同视频各行独立合并，不再按裸 (title,dateKey) 互相吞并。备份源可能是
  /// v39 前导出（无 book_uid 列值 → NULL → 回退 title 键，与旧行为一致）。
  /// 'title:' 前缀防 NULL 回退键与真实 uid 空间相撞（uid 形如 'video/...'）。
  static const String _watchKeyT = "COALESCE(t.book_uid, 'title:' || t.title)";
  static const String _watchKeyS = "COALESCE(s.book_uid, 'title:' || s.title)";

  Future<void> _mergeVideoWatchStatistics() async {
    await _db.customStatement(
      'INSERT INTO video_watch_statistics '
      '(title, book_uid, date_key, subtitle_chars, watch_time_ms, '
      'last_modified) '
      'SELECT title, book_uid, date_key, subtitle_chars, watch_time_ms, '
      'last_modified '
      'FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM video_watch_statistics AS t '
      'WHERE $_watchKeyT = $_watchKeyS AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该视频统计（video 墓碑）→ 旧备份不得复活它。
      'AND s.title NOT IN (SELECT title FROM statistics_tombstones '
      "WHERE source_type = 'video')",
    );
    await _db.customStatement(
      'UPDATE video_watch_statistics AS t SET '
      'subtitle_chars = MAX(t.subtitle_chars, ('
      'SELECT s.subtitle_chars FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE $_watchKeyS = $_watchKeyT '
      'AND s.date_key = t.date_key)), '
      'watch_time_ms = MAX(t.watch_time_ms, ('
      'SELECT s.watch_time_ms FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE $_watchKeyS = $_watchKeyT '
      'AND s.date_key = t.date_key)), '
      'last_modified = MAX(t.last_modified, ('
      'SELECT s.last_modified FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE $_watchKeyS = $_watchKeyT '
      'AND s.date_key = t.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE $_watchKeyS = $_watchKeyT '
      'AND s.date_key = t.date_key)',
    );
  }

  /// Hourly logs MAX-union per [keyColumns]（阅读表 {date_key, hour, format}，
  /// 视频表 {date_key, hour}）。[valueColumn] is the single duration column
  /// (reading_time_ms / watch_time_ms).
  Future<void> _mergeHourlyLogs(
    String table,
    String valueColumn, {
    required List<String> keyColumns,
  }) async {
    final String keyList = keyColumns.join(', ');
    final String tEqS =
        keyColumns.map((String c) => 't.$c = s.$c').join(' AND ');
    final String sEqTable =
        keyColumns.map((String c) => 's.$c = $table.$c').join(' AND ');
    await _db.customStatement(
      'INSERT INTO $table ($keyList, $valueColumn) '
      'SELECT $keyList, $valueColumn FROM $_srcAlias.$table AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
      'WHERE $tEqS)',
    );
    await _db.customStatement(
      'UPDATE $table SET '
      '$valueColumn = MAX($valueColumn, ('
      'SELECT s.$valueColumn FROM $_srcAlias.$table AS s '
      'WHERE $sEqTable)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.$table AS s '
      'WHERE $sEqTable)',
    );
  }

  /// MiningStatistics MAX-union per {sourceType, dateKey} -- MAX, never SUM, so
  /// a re-import of the same backup stays idempotent (mirrors setMiningCount).
  Future<void> _mergeMiningStatistics() async {
    await _db.customStatement(
      'INSERT INTO mining_statistics (source_type, date_key, "count") '
      'SELECT source_type, date_key, "count" FROM $_srcAlias.mining_statistics '
      'AS s WHERE NOT EXISTS (SELECT 1 FROM mining_statistics AS t '
      'WHERE t.source_type = s.source_type AND t.date_key = s.date_key)',
    );
    await _db.customStatement(
      'UPDATE mining_statistics SET "count" = MAX("count", ('
      'SELECT s."count" FROM $_srcAlias.mining_statistics AS s '
      'WHERE s.source_type = mining_statistics.source_type '
      'AND s.date_key = mining_statistics.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.mining_statistics AS s '
      'WHERE s.source_type = mining_statistics.source_type '
      'AND s.date_key = mining_statistics.date_key)',
    );
  }

  /// LookupMiningCounters MAX-union（TODO-1204；v76 起身份感知）。
  ///
  /// v76 把 book_key 收进唯一键 {book_key, title, source_type, date_key} 后，
  /// 同 title 可以有多行（per-uid 行 + '' 无身份行），旧的三列键合并会双向出错：
  /// src 身份行被 NOT EXISTS 静默丢弃；UPDATE 把同 title 每一行抬到标量子查询值
  /// → 计数膨胀且不确定。修法与 [_mergeVideoWatchStatistics] 的 v39 身份感知
  /// **完全同律**：桶身份 = 表唯一键（'' 无身份桶就是普通桶，只与对侧的 '' 桶
  /// MAX 合并，绝不跨桶比较/塌缩）——INSERT 缺失桶、逐列 MAX 既有桶，重导幂等。
  /// src 侧在 ATTACH 前已迁到当前 schema（book_key 已 NOT NULL），COALESCE 仅
  /// 防御性归一。
  ///
  /// 迁移边界的已知精度限制（与 v39 watch 合并同款、同理由）：同一段活动在两侧
  /// 落在不同桶里（一侧迁移回填出身份、另一侧仍是 '' 桶）时按两个桶各自并入，
  /// 汇总可能偏高——桶间归属不可判，宁可保留全部数据也不瞎塌；展示层的身份分组
  /// 会把歧义 '' 桶按 unique-title 判据归并或单列。
  ///
  /// This has NO book_tombstones guard (per-title activity, not per-book_key
  /// content), but DOES honour statistics_tombstones (TODO-1204 后续): once the
  /// user explicitly deleted a book/video's stats in the stats page, an old
  /// backup must not resurrect its lookup/mine counters. The INSERT below skips
  /// tombstoned (title, source_type); the UPDATE only touches buckets the
  /// target already has (deleted buckets are gone), so it needs no guard.
  Future<void> _mergeLookupMiningCounters() async {
    const String srcKey = "COALESCE(s.book_key, '')";
    await _db.customStatement(
      'INSERT INTO lookup_mining_counters '
      '(book_key, title, source_type, date_key, lookup_count, mine_count) '
      'SELECT $srcKey, title, source_type, date_key, '
      'lookup_count, mine_count '
      'FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM lookup_mining_counters AS t '
      'WHERE t.book_key = $srcKey AND t.title = s.title '
      'AND t.source_type = s.source_type AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该 (title, sourceType) 统计 → 旧备份不得复活其计数。
      'AND NOT EXISTS (SELECT 1 FROM statistics_tombstones st '
      'WHERE st.title = s.title AND st.source_type = s.source_type)',
    );
    await _db.customStatement(
      'UPDATE lookup_mining_counters SET '
      'lookup_count = MAX(lookup_count, ('
      'SELECT s.lookup_count FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE $srcKey = lookup_mining_counters.book_key '
      'AND s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)), '
      'mine_count = MAX(mine_count, ('
      'SELECT s.mine_count FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE $srcKey = lookup_mining_counters.book_key '
      'AND s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE $srcKey = lookup_mining_counters.book_key '
      'AND s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)',
    );
  }

  /// FavoriteWords dedupe-UNION by {expression, reading, sourceType} (declared
  /// unique key -> the duplicate is dropped, the earlier createdAt kept).
  Future<void> _mergeFavoriteWords() async {
    final List<String> cols = await _columnsExceptId('favorite_words');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO favorite_words ($colList) '
      'SELECT $colList FROM $_srcAlias.favorite_words AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM favorite_words AS t '
      'WHERE t.expression = s.expression AND t.reading = s.reading '
      'AND t.source_type = s.source_type)',
    );
  }

  /// MinedSentences have NO unique constraint, so INSERT OR IGNORE would never
  /// dedupe. Dedupe by content fingerprint {source, date_key, expression,
  /// reading, created_at} via NOT EXISTS (select-then-insert at SQL scope).
  Future<void> _mergeMinedSentences() async {
    final List<String> cols = await _columnsExceptId('mined_sentences');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO mined_sentences ($colList) '
      'SELECT $colList FROM $_srcAlias.mined_sentences AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM mined_sentences AS t '
      'WHERE t.source = s.source AND t.date_key = s.date_key '
      'AND t.expression = s.expression AND t.reading = s.reading '
      'AND t.created_at = s.created_at)',
    );
  }

  /// ActivityEvents dedupe-UNION（session 粒度事实流，与 [_mergeMinedSentences]
  /// 同形：无唯一约束，按内容指纹 NOT EXISTS 去重插入）。
  ///
  /// 自然键 = {event_type, media_type, title, timestamp_ms}：timestamp_ms 是
  /// session 落库的精确毫秒时刻，同型、同媒体、同题、同毫秒即同一事件——重导
  /// 同一备份幂等，两台设备各自的真实 session 几乎不可能四元全撞。media_key
  /// 刻意不进键：它是 nullable 的打开锚点（书=bookKey、视频=bookUid），跨库/
  /// 跨版本身份空间可能不同，进键会把同一事件在两侧判成两条。行本身原样搬运
  /// （含 media_key），dateKey 与 timestamp_ms 同行同源，无需重算。
  ///
  /// 不产投影：activity 行只是时间线事实，投影表（reading_statistics 等）由
  /// 上面各自的 MAX-union 独立合并，绝不从这里派生（防双计）。
  ///
  /// 无 statistics_tombstones 守卫：activity 删除对称性是尚未拍板的独立任务
  /// （P4 B2——本地删除路径 deleteActivityEventsForTitle 目前零生产调用方），
  /// 本地都不删，合并侧守卫没有语义可对齐；B2 落地时同步补。
  ///
  /// 代价：target 无 {event_type, ...} 复合索引，NOT EXISTS 对每条 src 行走
  /// 全表扫描（O(src×target)）。activity 是 session 粒度（每天几行~几十行），
  /// 年级数据也在万行内，SQLite 毫秒级，不值得为 merge 加索引。
  /// v92 学习事实段（`study_segments`）+ 按身份墓碑（`study_segment_tombstones`）。
  ///
  /// 语义与在线同步 [AggregateMergeService.mergeStudySegments] /
  /// [AggregateMergeService.arbitrateStudySegments] 完全一致，只是写成 SQL：
  ///  ① 墓碑并集取 max deletedAt（碑戳只增不减，永不退场）；
  ///  ② 段按 uid：目标没有 → 插；两边都有且 src.updated_at 严格更新 → 整行覆盖
  ///     （LWW，同值重放 no-op）；
  ///  ③ 删掉目标里被（合并后）墓碑压制的段（`start_at < deleted_at`，
  ///     BUG-2214 / BUG-2220：删除之前开始的段出局，之后开始的存活）。
  /// 游戏段 / 碑（BUG-2221）不从备份搬入——与 galgame_sessions 同律，src 的
  /// game_id 在目标库没有宿主。
  /// 旧备份（v92 前）没有这两张表：ATTACH 前已迁到当前 schema，两侧必有表。
  Future<void> _mergeStudySegments() async {
    await _db.customStatement(
      'INSERT INTO study_segment_tombstones (media_kind, media_key, deleted_at) '
      'SELECT media_kind, media_key, deleted_at '
      'FROM $_srcAlias.study_segment_tombstones AS s '
      'WHERE s.media_kind <> ? '
      'AND NOT EXISTS (SELECT 1 FROM study_segment_tombstones AS t '
      'WHERE t.media_kind = s.media_kind AND t.media_key = s.media_key)',
      <Object>[kActivityMediaGame],
    );
    await _db.customStatement(
      'UPDATE study_segment_tombstones SET deleted_at = ('
      'SELECT s.deleted_at FROM $_srcAlias.study_segment_tombstones AS s '
      'WHERE s.media_kind = study_segment_tombstones.media_kind '
      'AND s.media_key = study_segment_tombstones.media_key) '
      'WHERE study_segment_tombstones.media_kind <> ? '
      'AND EXISTS (SELECT 1 FROM $_srcAlias.study_segment_tombstones AS s '
      'WHERE s.media_kind = study_segment_tombstones.media_kind '
      'AND s.media_key = study_segment_tombstones.media_key '
      'AND s.deleted_at > study_segment_tombstones.deleted_at)',
      <Object>[kActivityMediaGame],
    );
    final List<String> cols = <String>[
      'uid',
      'device_id',
      'media_kind',
      'media_key',
      'format',
      'title',
      'start_at',
      'end_at',
      'date_key',
      'hour',
      'duration_ms',
      'chars',
      'pages',
      'updated_at',
    ];
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO study_segments ($colList) '
      'SELECT $colList FROM $_srcAlias.study_segments AS s '
      'WHERE s.media_kind <> ? '
      'AND NOT EXISTS (SELECT 1 FROM study_segments AS t WHERE t.uid = s.uid)',
      <Object>[kActivityMediaGame],
    );
    final String setClause = cols
        .where((String c) => c != 'uid')
        .map((String c) =>
            '$c = (SELECT s.$c FROM $_srcAlias.study_segments AS s '
            'WHERE s.uid = study_segments.uid)')
        .join(', ');
    await _db.customStatement(
      'UPDATE study_segments SET $setClause '
      'WHERE study_segments.media_kind <> ? '
      'AND EXISTS (SELECT 1 FROM $_srcAlias.study_segments AS s '
      'WHERE s.uid = study_segments.uid '
      'AND s.updated_at > study_segments.updated_at)',
      <Object>[kActivityMediaGame],
    );
    await _db.customStatement(
      'DELETE FROM study_segments WHERE EXISTS ('
      'SELECT 1 FROM study_segment_tombstones AS t '
      'WHERE t.media_kind = study_segments.media_kind '
      'AND t.media_key = study_segments.media_key '
      'AND t.deleted_at > study_segments.start_at)',
    );
  }

  Future<void> _mergeActivityEvents() async {
    final List<String> cols = await _columnsExceptId('activity_events');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO activity_events ($colList) '
      'SELECT $colList FROM $_srcAlias.activity_events AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM activity_events AS t '
      'WHERE t.event_type = s.event_type AND t.media_type = s.media_type '
      'AND t.title = s.title AND t.timestamp_ms = s.timestamp_ms)',
    );
  }

  /// Favorite SENTENCES dedupe-UNION. Unlike favorite words / mined sentences
  /// these are NOT a table but a JSON list stored in the target's and src's
  /// `preferences` row `favorite_sentences`, so the ATTACH SQL merge cannot
  /// touch them -- before this the backup's favorite sentences were silently
  /// dropped. Read both blobs, delegate the union+dedupe to the pure
  /// [AggregateMergeService.mergeFavoriteSentences] (single source of truth for
  /// this semantic, shared with online sync), and write the merged blob back.
  ///
  /// A missing/empty src blob is a no-op; a missing target blob just adopts the
  /// merged src set. Runs inside the merge transaction, so a failure here rolls
  /// the whole merge back with everything else.
  Future<void> _mergeFavoriteSentencePrefs() async {
    final String? targetRaw = await _readPref(isSrc: false);
    final String? srcRaw = await _readPref(isSrc: true);
    // Nothing to merge in from the backup: leave the device's blob untouched.
    if (srcRaw == null || srcRaw.isEmpty) return;

    final List<FavoriteSentence> localList =
        _decodeFavoriteSentences(targetRaw);
    final List<FavoriteSentence> remoteList = _decodeFavoriteSentences(srcRaw);
    final List<FavoriteSentence> merged =
        AggregateMergeService.mergeFavoriteSentences(localList, remoteList);

    final String mergedJson =
        jsonEncode(merged.map((FavoriteSentence s) => s.toJson()).toList());
    // Upsert the target preference row (INSERT OR REPLACE on the key PK).
    await _db.customStatement(
      'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
      <Object?>[_favoriteSentencesPrefKey, mergedJson],
    );
  }

  /// Reads the `favorite_sentences` preference value from either the target
  /// ([isSrc] false) or the ATTACHed src ([isSrc] true). Returns null when the
  /// row is absent.
  Future<String?> _readPref({required bool isSrc}) async {
    final String table = isSrc ? '$_srcAlias.preferences' : 'preferences';
    final rows = await _db.customSelect(
      'SELECT "value" FROM $table WHERE "key" = ?',
      variables: <Variable<Object>>[
        Variable<String>(_favoriteSentencesPrefKey)
      ],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['value'] as String?;
  }

  /// Decodes a `favorite_sentences` JSON blob into models, tolerating a
  /// null/empty/malformed value (returns an empty list) so a corrupt pref on
  /// either side never aborts the whole merge.
  static List<FavoriteSentence> _decodeFavoriteSentences(String? raw) {
    if (raw == null || raw.isEmpty) return const <FavoriteSentence>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <FavoriteSentence>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(FavoriteSentence.fromJson)
          .toList();
    } catch (_) {
      return const <FavoriteSentence>[];
    }
  }

  /// BookTags UNION by name (device keeps its own tag row + id on a name clash),
  /// then the unified tag_assignments with the src tagId REMAPPED to the target
  /// id resolved by tag name. Owner rows must already be merged.
  ///
  /// v79（五表合一 + 用户令全 kind 合并）：src 在 ATTACH 前已迁到当前 schema，
  /// 五张旧映射表已并成 tag_assignments——这里按 kind 分三路：
  ///  - epub/srt/video/**game 直键**：entry_key 本身跨库可比（bookKey / srt uid /
  ///    bookUid / game id），宿主存在性逐 kind 校验后直插。game 的 id 是本机
  ///    局域身份且 galgames 行不参与备份合并——直键只在 target 恰好有同 id 游戏
  ///    （同机恢复 / 整库迁移后补合并）时命中；
  ///  - **game 二跳**（用户令跨机也要并）：直键不命中的游戏标签行，经
  ///    「src 该游戏的刮削身份 (source, external_id) → target 拥有同刮削身份的
  ///    游戏」二跳落地——bgm/vndb 条目 id 是游戏唯一的跨机稳定身份（两机各自
  ///    刮削同一部游戏得到同一个 subject id）。两侧任一没刮削/未命中 → 仍丢
  ///    （按名/按路径猜会把标签打到别的游戏头上，宁缺毋错）；
  ///  - collection：src 本地 id 无跨库意义，经 media_collections
  ///    (name, collection_type) 自然键映射到 target id（JOIN 不命中——被删除
  ///    墓碑跳过、target 无同名合集——天然不插入）。
  /// added_at 随行携带（缺失桶落 src 时钟；已存在桶保 target 时钟，additive
  /// union 语义同旧版）。
  Future<void> _mergeTagsAndMappings() async {
    await _db.customStatement(
      'INSERT INTO book_tags (name, color_value, sort_order, created_at) '
      'SELECT name, color_value, sort_order, created_at '
      'FROM $_srcAlias.book_tags AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM book_tags AS t WHERE t.name = s.name)',
    );
    await _db.customStatement(
      'INSERT INTO tag_assignments (media_kind, entry_key, tag_id, added_at) '
      'SELECT sm.media_kind, sm.entry_key, tt.id, sm.added_at '
      'FROM $_srcAlias.tag_assignments AS sm '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      'WHERE ('
      "(sm.media_kind = 'epub' AND EXISTS "
      '(SELECT 1 FROM epub_books AS b WHERE b.book_key = sm.entry_key)) '
      "OR (sm.media_kind = 'srt' AND EXISTS "
      '(SELECT 1 FROM srt_books AS sb WHERE sb.uid = sm.entry_key)) '
      "OR (sm.media_kind = 'video' AND EXISTS "
      '(SELECT 1 FROM video_books AS v WHERE v.book_uid = sm.entry_key)) '
      "OR (sm.media_kind = 'game' AND EXISTS "
      '(SELECT 1 FROM galgames AS g WHERE g.id = sm.entry_key))'
      ') '
      'AND NOT EXISTS (SELECT 1 FROM tag_assignments AS m '
      'WHERE m.media_kind = sm.media_kind AND m.entry_key = sm.entry_key '
      'AND m.tag_id = tt.id)',
    );
    // game 二跳：直键不命中（target 无同 id 游戏 = 跨机场景）的游戏标签行，
    // 按刮削身份重定位到 target 的对应游戏。DISTINCT 防同一 (game, tag) 经
    // bgm+vndb 双源命中同一 target 游戏时重复；同一 externalId 在 target 命中
    // 多个游戏（用户重复添加同一部）时每个都打上——标签是并集语义，多打不为错。
    await _db.customStatement(
      'INSERT INTO tag_assignments (media_kind, entry_key, tag_id, added_at) '
      "SELECT DISTINCT 'game', ts.game_id, tt.id, sm.added_at "
      'FROM $_srcAlias.tag_assignments AS sm '
      'JOIN $_srcAlias.galgame_sources AS ss '
      'ON ss.game_id = sm.entry_key '
      "AND ss.external_id IS NOT NULL AND ss.external_id != '' "
      'JOIN galgame_sources AS ts '
      'ON ts.source = ss.source AND ts.external_id = ss.external_id '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      "WHERE sm.media_kind = 'game' "
      'AND NOT EXISTS (SELECT 1 FROM galgames AS g WHERE g.id = sm.entry_key) '
      'AND NOT EXISTS (SELECT 1 FROM tag_assignments AS m '
      "WHERE m.media_kind = 'game' AND m.entry_key = ts.game_id "
      'AND m.tag_id = tt.id)',
    );
  }

  /// 合集标签映射 UNION by (合集自然键 + 标签名)——v77 起读统一表的
  /// collection kind（详见 [_mergeTagsAndMappings] doc）。owner 合集与
  /// book_tags 须已合并（本方法在 [_mergeMediaCollections] 与
  /// [_mergeTagsAndMappings] 之后调用）。
  Future<void> _mergeCollectionTags() async {
    await _db.customStatement(
      'INSERT INTO tag_assignments (media_kind, entry_key, tag_id, added_at) '
      "SELECT 'collection', CAST(tc.id AS TEXT), tt.id, sm.added_at "
      'FROM $_srcAlias.tag_assignments AS sm '
      'JOIN $_srcAlias.media_collections AS sc '
      'ON CAST(sc.id AS TEXT) = sm.entry_key '
      'JOIN media_collections AS tc '
      'ON tc.name = sc.name AND tc.collection_type = sc.collection_type '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      "WHERE sm.media_kind = 'collection' "
      'AND NOT EXISTS (SELECT 1 FROM tag_assignments AS m '
      "WHERE m.media_kind = 'collection' "
      'AND m.entry_key = CAST(tc.id AS TEXT) AND m.tag_id = tt.id)',
    );
  }

  /// Profiles UNION by name (device keeps its own profile + id on a name clash),
  /// then the three child tables with src profile_id REMAPPED to the target id
  /// resolved by profile name (necessary because Profiles.id is autoincrement --
  /// FK children would otherwise dangle / cross).
  Future<void> _mergeProfilesAndChildren() async {
    await _db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) '
      'SELECT name, created_at, updated_at FROM $_srcAlias.profiles AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM profiles AS t WHERE t.name = s.name)',
    );
    await _db.customStatement(
      'INSERT INTO profile_settings (profile_id, category, "key", "value") '
      'SELECT tp.id, sps.category, sps."key", sps."value" '
      'FROM $_srcAlias.profile_settings AS sps '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = sps.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM profile_settings AS m '
      'WHERE m.profile_id = tp.id AND m.category = sps.category '
      'AND m."key" = sps."key")',
    );
    await _db.customStatement(
      'INSERT INTO media_type_profiles (media_type, profile_id) '
      'SELECT smtp.media_type, tp.id '
      'FROM $_srcAlias.media_type_profiles AS smtp '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = smtp.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM media_type_profiles AS m '
      'WHERE m.media_type = smtp.media_type)',
    );
    await _db.customStatement(
      'INSERT INTO book_profiles (book_key, profile_id) '
      'SELECT sbp.book_key, tp.id '
      'FROM $_srcAlias.book_profiles AS sbp '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = sbp.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM book_profiles AS m '
      'WHERE m.book_key = sbp.book_key)',
    );
  }

  /// Bookmarks dedupe-union by {book_uid, section_index, norm_char_offset,
  /// created_at}, existence-guarded on epub_books(uid) so a bookmark for a book
  /// the backup omitted is skipped（v82 换键后 guard 语义不变）.
  Future<void> _mergeBookmarks() async {
    final List<String> cols = await _columnsExceptId('bookmarks');
    final String colList = cols.join(', ');
    final String selList = cols
        .map((String c) => c == '"book_uid"' ? _srcBookUidRekey : 's.$c')
        .join(', ');
    await _db.customStatement(
      'INSERT INTO bookmarks ($colList) '
      'SELECT $selList FROM $_srcAlias.bookmarks AS s '
      'WHERE EXISTS '
      '(SELECT 1 FROM epub_books AS b WHERE b.uid = $_srcBookUidRekey) '
      'AND NOT EXISTS (SELECT 1 FROM bookmarks AS t '
      'WHERE t.book_uid = $_srcBookUidRekey '
      'AND t.section_index = s.section_index '
      'AND t.norm_char_offset = s.norm_char_offset '
      'AND t.created_at = s.created_at)',
    );
  }

  /// v82：书自定义 CSS LWW 合并（per {book_uid, relative_path}，updatedAt 取
  /// 较新；重置墓碑 deleted 行同样传播）。此前该表不进 merge（src 静默丢弃）。
  Future<void> _mergeBookCustomCss() async {
    if (!await _srcTableExists('book_custom_css')) return;
    await _db.customStatement(
      'INSERT INTO book_custom_css '
      '(book_uid, relative_path, content, deleted, updated_at) '
      'SELECT $_srcBookUidRekey, s.relative_path, s.content, s.deleted, '
      's.updated_at FROM $_srcAlias.book_custom_css AS s '
      'WHERE EXISTS '
      '(SELECT 1 FROM epub_books AS b WHERE b.uid = $_srcBookUidRekey) '
      'AND NOT EXISTS (SELECT 1 FROM book_custom_css AS t '
      'WHERE t.book_uid = $_srcBookUidRekey '
      'AND t.relative_path = s.relative_path)',
    );
    await _db.customStatement(
      'UPDATE book_custom_css SET '
      'content = (SELECT s.content FROM $_srcAlias.book_custom_css AS s '
      'WHERE $_srcBookUidRekey = book_custom_css.book_uid '
      'AND s.relative_path = book_custom_css.relative_path), '
      'deleted = (SELECT s.deleted FROM $_srcAlias.book_custom_css AS s '
      'WHERE $_srcBookUidRekey = book_custom_css.book_uid '
      'AND s.relative_path = book_custom_css.relative_path), '
      'updated_at = (SELECT s.updated_at FROM $_srcAlias.book_custom_css AS s '
      'WHERE $_srcBookUidRekey = book_custom_css.book_uid '
      'AND s.relative_path = book_custom_css.relative_path) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.book_custom_css AS s '
      'WHERE $_srcBookUidRekey = book_custom_css.book_uid '
      'AND s.relative_path = book_custom_css.relative_path '
      'AND s.updated_at > book_custom_css.updated_at)',
    );
  }

  /// v82：图片揭开状态合并（per {book_uid, image_key}，revealedAt 取较新；
  /// 语义上「任一端揭开即揭开」，union + LWW 刷新时刻）。此前不进 merge。
  Future<void> _mergeRevealedImages() async {
    if (!await _srcTableExists('revealed_images')) return;
    await _db.customStatement(
      'INSERT INTO revealed_images (book_uid, image_key, revealed_at) '
      'SELECT $_srcBookUidRekey, s.image_key, s.revealed_at '
      'FROM $_srcAlias.revealed_images AS s '
      'WHERE EXISTS '
      '(SELECT 1 FROM epub_books AS b WHERE b.uid = $_srcBookUidRekey) '
      'AND NOT EXISTS (SELECT 1 FROM revealed_images AS t '
      'WHERE t.book_uid = $_srcBookUidRekey AND t.image_key = s.image_key)',
    );
    await _db.customStatement(
      'UPDATE revealed_images SET '
      'revealed_at = (SELECT s.revealed_at '
      'FROM $_srcAlias.revealed_images AS s '
      'WHERE $_srcBookUidRekey = revealed_images.book_uid '
      'AND s.image_key = revealed_images.image_key) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.revealed_images AS s '
      'WHERE $_srcBookUidRekey = revealed_images.book_uid '
      'AND s.image_key = revealed_images.image_key '
      'AND s.revealed_at > revealed_images.revealed_at)',
    );
  }

  /// Preferences are device settings -> kept (non-merge by default). The single
  /// exception is audiobook positions (per-book content): UNION push-only so the
  /// backup positions for books the device lacks are added, without clobbering
  /// the device's existing positions.
  Future<void> _mergeAudiobookPositionPrefs() async {
    await _db.customStatement(
      'INSERT INTO preferences ("key", "value") '
      'SELECT "key", "value" FROM $_srcAlias.preferences AS s '
      "WHERE s.\"key\" LIKE 'audiobook_pos_%' "
      'AND NOT EXISTS (SELECT 1 FROM preferences AS t WHERE t."key" = s."key")',
    );
  }

  /// 用户给书改的名字（BUG-1488）。
  ///
  /// 改名不写 `epub_books.title`（那一列派生主键 `bookKey`，改列 = 换身份），而是
  /// 往 `preferences` 写一行 `…override_title://fushi://book/<bookKey>` 覆盖。
  /// 于是它撞上了本引擎「preferences 是设备设置 → 不合并」的默认律：母设备改过名
  /// 的书合并到子设备后，子设备显示的仍是导入时的原始书名。它和 `audiobook_pos_%`
  /// 一样是**内容**（跟着书走，不是这台设备的偏好），必须合并。
  ///
  /// 裁决 last-write-wins（BUG-1502），与 [_mergeReaderPositions] /
  /// [_mergeRevealedImages] 同形：insert-missing + update-strictly-newer 两条语句。
  /// 比较键是 v84 新增的 `preferences.updated_at`。
  ///
  /// 平局（`>` 不成立）保留本机。旧备份的行经 merge 前的 schema 迁移拿到
  /// `updated_at = 0`（备份库先被开一次升到当前 schema，见
  /// `BackupRestoreService.mergeRestoreBackup` 的第 2 步），于是与本机存量行平局 →
  /// 行为逐字等于本轮之前的 insert-if-absent，零回归；而任一侧真正改过一次名
  /// （戳 > 0）之后立刻胜出，母设备的第二次改名终于能并进来。
  Future<void> _mergeOverrideTitlePrefs() async {
    await _db.customStatement(
      'INSERT INTO preferences ("key", "value", "updated_at") '
      'SELECT s."key", s."value", s."updated_at" '
      'FROM $_srcAlias.preferences AS s '
      "WHERE instr(s.\"key\", '$kOverrideTitleKeyMarker') > 0 "
      'AND NOT EXISTS (SELECT 1 FROM preferences AS t WHERE t."key" = s."key")',
    );
    await _db.customStatement(
      'UPDATE preferences SET '
      '"value" = (SELECT s."value" FROM $_srcAlias.preferences AS s '
      'WHERE s."key" = preferences."key"), '
      '"updated_at" = (SELECT s."updated_at" FROM $_srcAlias.preferences AS s '
      'WHERE s."key" = preferences."key") '
      "WHERE instr(preferences.\"key\", '$kOverrideTitleKeyMarker') > 0 "
      'AND EXISTS (SELECT 1 FROM $_srcAlias.preferences AS s '
      'WHERE s."key" = preferences."key" '
      'AND s."updated_at" > preferences."updated_at")',
    );
  }

  /// The audio-source registry prefs are CONTENT config, not device settings:
  /// the local-audio `.db` files they reference DO travel in the backup (packed
  /// under `localAudio/` and copied by [BackupRestoreService.mergeRestoreBackup]),
  /// so their config must travel too — otherwise the restored files are orphaned
  /// and "音频来源" is silently lost on a merge (the pref-non-merge default
  /// dropped them). Adopt the backup's value when the device has none/an empty
  /// list (a fresh app writes an empty `[]` placeholder, so a bare NOT-EXISTS on
  /// the key is not enough); keep the device's own list otherwise (merge never
  /// clobbers local). The raw value is copied verbatim so its typed prefix is
  /// preserved; [BackupService] re-homes the embedded paths onto this device's
  /// support dir afterwards.
  Future<void> _mergeAudioSourcePrefs() async {
    for (final String key in _audioSourcePrefKeys) {
      final String? src = await _readPrefValue(key, isSrc: true);
      if (_isEmptyListPref(src)) continue; // backup carries no audio sources
      final String? local = await _readPrefValue(key, isSrc: false);
      if (!_isEmptyListPref(local)) continue; // keep the device's own list
      await _db.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>[key, src],
      );
    }
  }

  /// Reads an arbitrary preference [key] value from the target ([isSrc] false)
  /// or the ATTACHed src ([isSrc] true); null when the row is absent.
  Future<String?> _readPrefValue(String key, {required bool isSrc}) async {
    final String table = isSrc ? '$_srcAlias.preferences' : 'preferences';
    final rows = await _db.customSelect(
      'SELECT "value" FROM $table WHERE "key" = ?',
      variables: <Variable<Object>>[Variable<String>(key)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['value'] as String?;
  }

  /// Whether a typed list-pref value is absent or an empty list. Tolerates the
  /// typed prefix (`s:`/`j:`) by parsing from the first `[`; a value we cannot
  /// parse as a non-empty list counts as empty (never worth clobbering with).
  static bool _isEmptyListPref(String? raw) {
    if (raw == null || raw.isEmpty) return true;
    final int i = raw.indexOf('[');
    if (i < 0) return true;
    try {
      final dynamic decoded = jsonDecode(raw.substring(i));
      return decoded is! List || decoded.isEmpty;
    } catch (_) {
      return true;
    }
  }
}

/// Preference keys that must never travel between devices on a merge import.
/// Re-exported for the caller / tests; the engine itself only touches audiobook
/// positions, so device-local sync prefs are inherently never merged.
List<String> mergeSkippedDeviceLocalPrefKeys() =>
    List<String>.unmodifiable(SyncRepository.deviceLocalPrefKeys);

/// Tables that a merge import must never copy from its attached backup DB.
///
/// [BackupMergeEngine.merge] is an explicit allowlist of content operations;
/// this catalog makes the negative contract reviewable and lets tests guard a
/// future generic-table merge from accidentally admitting device-bound work.
List<String> mergeSkippedDeviceLocalTableNames() =>
    List<String>.unmodifiable(const <String>[
      'fushi_paired_peers',
      'sync_baselines',
      'manga_extension_stores',
      'manga_extensions',
      'manga_online_sources',
      'manga_source_preferences',
      'manga_trusted_signers',
      'video_download_jobs',
      'video_download_job_files',
      'video_download_job_subtitles',
      'video_download_subscriptions',
      'video_download_subscription_items',
      'web_mine_queue',
      // v95：ffprobe 规格探测缓存。键是本机绝对路径、内容是本机文件的实测结果，
      // 换台设备既命不中也可能与对端的同名文件规格不同——必须现探，不能合并进来。
      'video_file_specs',
    ]);

/// Read-only summary of what a backup MERGE import would change on this device
/// (TODO-1195 part B), shown in the import confirm dialog. Produced by
/// [BackupMergeEngine.preview]; counts only the user-meaningful deltas.
class BackupMergePreview {
  const BackupMergePreview({
    required this.newEpubBooks,
    required this.newVideoBooks,
    required this.newAudiobooks,
    required this.updatedReaderPositions,
  });

  /// EPUB books present in the backup but not on this device (and not
  /// tombstoned), that the merge would add.
  final int newEpubBooks;

  /// Video books the merge would add.
  final int newVideoBooks;

  /// Audiobooks the merge would add (their EPUB shell is counted in
  /// [newEpubBooks]; this is the audio-alignment rows).
  final int newAudiobooks;

  /// Reading positions the merge would insert or advance (LWW).
  final int updatedReaderPositions;

  /// Total books that would newly appear on the shelf (EPUB + video).
  int get newBooks => newEpubBooks + newVideoBooks;
}
