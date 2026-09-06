part of '../backup_service.dart';

/// 备份的恢复 / 合并 / 预览 / 崩溃恢复 / 读包摘要（B1 从 [BackupService] 分家）。
///
/// 全部 static：恢复侧不需要导出侧的实例状态（库目录等都是参数）。共用的常量与
/// 纯 helper 在主文件顶层，`_rebase*` 族在 path_rebase.part.dart。
class BackupRestoreService {
  BackupRestoreService._();

  /// Predicate for the keep-THIS-device-settings restore ([_reapplySettingsLayer],
  /// the `importSettings=false` overwrite path). Restores from bak every pref row
  /// EXCEPT the ones that are CONTENT and must follow the imported backup:
  ///   - `audiobook_pos_*`      -> reading progress (the `progress` category)
  ///   - `favorite_sentences`   -> favorites content (travels)
  ///   - `local_audio_dbs` / `audio_source_configs` -> audio-source registry that
  ///     points at the imported local-audio `.db` files (BUG-780: the old
  ///     `NOT LIKE 'audiobook_pos_%'` restored these from THIS device, wiping the
  ///     backup's registration so the `.db` files landed but no source was
  ///     registered → imported local audio silently stopped working).
  ///   - font catalog + legacy font prefs -> font registry (the `fonts` category)
  ///   - `*override_title://*`  -> 用户给书改的名字是内容，跟着导入的备份走
  ///     （BUG-1488；与 [settingsPrefPredicate] 的内容/设置切分保持对称）
  /// UNLIKE [settingsPrefPredicate] this KEEPS `sync_*` restored from bak: the
  /// keep-settings path writes no `{'mode':'prefs'}` sidecar and never calls
  /// [_applyPreservedConfig], so this wholesale restore is the ONLY place the
  /// device's own (never-exported) sync config is preserved — excluding `sync_*`
  /// here would drop it. Same content-vs-settings split as the export strip and
  /// [_reapplyExcludedSettingsLayers], so the two restore paths stay symmetric.
  static final String _keepDeviceSettingsPrefPredicate =
      _buildKeepDeviceSettingsPrefPredicate();

  static String _buildKeepDeviceSettingsPrefPredicate() {
    final List<String> contentRegistryKeys = <String>[
      _favoriteSentencesPrefKey,
      _localAudioDbsPrefKey,
      _audioSourceConfigsPrefKey,
      _fontCatalogPrefKey,
      ..._legacyFontPrefKeys,
    ];
    final String notIn = contentRegistryKeys
        .map((String k) => "'${k.replaceAll("'", "''")}'")
        .join(', ');
    return "key NOT LIKE 'audiobook_pos_%' AND key NOT IN ($notIn) "
        'AND $_notOverrideTitleSql';
  }

  /// Sidecar file holding this device's sync config across an import. Written
  /// BEFORE the destructive DB overwrite so a crash mid-import is recoverable
  /// (a startup sweep re-applies it). Deleted once the import completes.
  static const String _preserveSidecar = '$_dbName.sync-preserve.json';

  /// Item counts per file-tree category present in a backup's [archiveFileNames]
  /// (posix or windows separators). Pure over the name list + [meta] so it is
  /// trivially unit-testable and never opens the archive body / DB (TODO-1358).
  ///
  /// Counting unit per category: dictionaries / books / audiobooks = distinct
  /// first path segment under the prefix (one directory each); fonts = font
  /// files; videos = packed video files ([BackupMeta.videoFiles], else leaf
  /// files); localAudio = `local_audio_<n>.db` files (the `-wal`/`-shm` siblings
  /// are not separate databases).
  static BackupContentSummary summarizeBackupEntries(
    Iterable<String> archiveFileNames,
    BackupMeta? meta, {
    int? dbVideoBookCount,
    int? dbAudiobookCount,
  }) {
    final Set<String> dictDirs = <String>{};
    final Set<String> bookDirs = <String>{};
    final Set<String> audioDirs = <String>{};
    int fontFiles = 0;
    int videoFiles = 0;
    int localAudioDbs = 0;
    for (final String raw in archiveFileNames) {
      final String name = raw.replaceAll(r'\', '/');
      final String? dictSeg =
          _firstSegmentUnder(name, _dictionaryResourcesPrefix);
      if (dictSeg != null) {
        dictDirs.add(dictSeg);
        continue;
      }
      final String? bookSeg = _firstSegmentUnder(name, _booksPrefix) ??
          _firstSegmentUnder(name, _legacyBooksPrefix);
      if (bookSeg != null) {
        bookDirs.add(bookSeg);
        continue;
      }
      final String? audioSeg = _firstSegmentUnder(name, _audiobooksPrefix);
      if (audioSeg != null) {
        audioDirs.add(audioSeg);
        continue;
      }
      if (name.startsWith('$_fontsPrefix/')) {
        if (name.length > _fontsPrefix.length + 1) fontFiles++;
        continue;
      }
      if (name.startsWith('$_videosPrefix/')) {
        if (name.length > _videosPrefix.length + 1) videoFiles++;
        continue;
      }
      if (name.startsWith('$_localAudioPrefix/')) {
        final String base = name.substring(_localAudioPrefix.length + 1);
        if (_localAudioDbOnly.hasMatch(base)) localAudioDbs++;
      }
    }
    // Video presence is decided by DB rows, NOT packed files: videos live in the
    // overwrite DB blob and restore wholesale, so a files-only count would hide a
    // streaming-video (no file) or old-backup video and import it uninvited
    // (BUG-779). Priority: meta.videoBookCount (authoritative row count, new
    // backups) → dbVideoBookCount (a DB-blob peek for old backups lacking the
    // field) → packed-file fallback (legacy).
    final int videoCount = meta?.videoBookCount ??
        dbVideoBookCount ??
        (meta != null && meta.videoFiles.isNotEmpty
            ? meta.videoFiles.length
            : videoFiles);
    // Audiobooks decided by DB rows too (BUG-781), same priority chain: the
    // audiobooks table rides the overwrite blob, so a files-only count would hide
    // a row-only / old backup and import ghost audiobooks un-skippably.
    final int audiobookCount =
        meta?.audiobookCount ?? dbAudiobookCount ?? audioDirs.length;
    final Map<BackupCategory, int> counts = <BackupCategory, int>{
      if (dictDirs.isNotEmpty) BackupCategory.dictionary: dictDirs.length,
      if (bookDirs.isNotEmpty) BackupCategory.books: bookDirs.length,
      if (audiobookCount > 0) BackupCategory.audiobooks: audiobookCount,
      if (fontFiles > 0) BackupCategory.fonts: fontFiles,
      if (videoCount > 0) BackupCategory.videos: videoCount,
      if (localAudioDbs > 0) BackupCategory.localAudio: localAudioDbs,
    };
    return BackupContentSummary(counts: counts, present: counts.keys.toSet());
  }

  /// First path segment directly under `<prefix>/` in [posixName], or null when
  /// [posixName] is not under [prefix].
  static String? _firstSegmentUnder(String posixName, String prefix) {
    final String withSlash = '$prefix/';
    if (!posixName.startsWith(withSlash)) return null;
    final String rest = posixName.substring(withSlash.length);
    if (rest.isEmpty) return null;
    final int slash = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /// Reads a backup ZIP's central directory (never its file bodies) and returns
  /// the "what's inside" manifest for the import dialog (TODO-1358). Streams like
  /// [validateBackup]; returns an empty summary on any read error.
  static Future<BackupContentSummary> summarizeBackupFile(
      String zipPath) async {
    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final BackupMeta? meta = _readBackupMeta(archive);
      final List<String> names = archive.files
          .where((ArchiveFile f) => f.isFile)
          .map((ArchiveFile f) => f.name)
          .toList();
      // Old backups (no video/audiobook row count in meta) that packed NO video
      // or audiobook FILES would otherwise hide those categories even though the
      // DB blob carries their rows → they import uninvited & un-skippable
      // (BUG-779 video / BUG-781 audiobooks). Peek the DB blob for the row counts
      // so the dialog can still offer the toggles. New backups carry the counts
      // in meta, so the (one-time) peek is skipped for them.
      int? dbVideoBookCount;
      int? dbAudiobookCount;
      final ArchiveFile? dbEntry = _findDbEntry(archive);
      final bool needPeek =
          (meta?.videoBookCount == null || meta?.audiobookCount == null) &&
              dbEntry != null;
      if (needPeek) {
        final ({int videos, int audiobooks})? peek =
            await _peekContentRowCounts(zipPath, dbEntry.name);
        dbVideoBookCount = peek?.videos;
        dbAudiobookCount = peek?.audiobooks;
      }
      return summarizeBackupEntries(names, meta,
          dbVideoBookCount: dbVideoBookCount,
          dbAudiobookCount: dbAudiobookCount);
    } catch (e, st) {
      debugPrint(
          'BackupRestoreService.summarizeBackupFile failed for $zipPath: $e\n$st');
      return const BackupContentSummary();
    } finally {
      await input?.close();
    }
  }

  /// Streams the backup's main-DB blob (entry [dbEntryName]; the small metadata
  /// DB — media lives in separate zip entries) to a temp file and returns its
  /// `video_books` and `audiobooks` row counts, or null on any failure. Used by
  /// [summarizeBackupFile] to offer the video / audiobooks import toggles for
  /// OLD backups that predate [BackupMeta.videoBookCount] /
  /// [BackupMeta.audiobookCount] (BUG-779 / BUG-781). Reuses the isolate-backed
  /// [_extractEntriesStreaming] so a large metadata DB never materializes on
  /// the UI isolate.
  static Future<({int videos, int audiobooks})?> _peekContentRowCounts(
    String zipPath,
    String dbEntryName,
  ) async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('fushi_content_peek_');
    final String dbTmp = p.join(tmp.path, _dbName);
    try {
      await _extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(dbEntryName, dbTmp),
        ],
      );
      final sqlite.Database db =
          sqlite.sqlite3.open(dbTmp, mode: sqlite.OpenMode.readOnly);
      try {
        return (
          videos: _countTableIfPresent(db, 'video_books'),
          audiobooks: _countTableIfPresent(db, 'audiobooks'),
        );
      } finally {
        db.dispose();
      }
    } catch (e, st) {
      debugPrint('BackupRestoreService._peekContentRowCounts failed: $e\n$st');
      return null;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // Best-effort temp cleanup; a leftover temp dir is harmless.
      }
    }
  }

  /// `SELECT COUNT(*)` of [table] on an open read-only sqlite [db], or 0 when the
  /// table is absent (older-schema backup blob).
  static int _countTableIfPresent(sqlite.Database db, String table) {
    final sqlite.ResultSet has = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    if (has.isEmpty) return 0;
    return db.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;
  }

  /// Restores [_deviceLocalTables] from [bakPath] (this device's pre-import
  /// snapshot) into the freshly-overwritten DB in [dbDirectory] (BUG-816). The
  /// backup carries these tables EMPTY by design (`_stripCredentials`), so
  /// without this the overwrite would wipe this device's LAN pairings and sync
  /// baselines. Runs inline during import while both DBs are at the current
  /// schema (bak is a copy of the live DB), so `SELECT *` columns align. No-op
  /// (logged) if bak is gone.
  static Future<bool> _reapplyDeviceLocalTablesFromBak(
    String dbDirectory,
    String bakPath,
  ) async {
    if (!File(bakPath).existsSync()) {
      debugPrint('BackupRestoreService._reapplyDeviceLocalTablesFromBak: '
          'pre-restore.bak missing — local pairing/baselines could not be '
          'preserved on import.');
      return false;
    }
    late final bool hasSqliteHeader;
    try {
      hasSqliteHeader = await _hasSqliteHeader(bakPath);
    } catch (e, st) {
      debugPrint('BackupRestoreService._reapplyDeviceLocalTablesFromBak: '
          'pre-restore.bak could not be inspected: $e\n$st');
      return false;
    }
    if (!hasSqliteHeader) {
      // A few low-level restore callers intentionally swap opaque fixture
      // bytes rather than a Hibiki database. Such a snapshot cannot contain
      // device-local rows, so there is nothing to retry or retain.
      debugPrint('BackupRestoreService._reapplyDeviceLocalTablesFromBak: '
          'pre-restore.bak is not a SQLite database; no local tables to '
          'preserve.');
      return true;
    }
    FushiDatabase? db;
    try {
      db = FushiDatabase(dbDirectory);
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS devbak");
      await db.transaction(() async {
        for (final String t in _deviceLocalTables) {
          await db!.customStatement('DELETE FROM $t');
        }
        for (final String t in _deviceLocalTablesParentFirst) {
          await _insertDeviceLocalTableFromBak(db!, t);
        }
      });
      await db.customStatement('DETACH DATABASE devbak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      return true;
    } catch (e, st) {
      // Best-effort preservation: a corrupt/unreadable imported DB must not
      // abort the whole restore (the primary overwrite already landed).
      debugPrint('BackupRestoreService._reapplyDeviceLocalTablesFromBak failed: '
          '$e\n$st');
      return false;
    } finally {
      try {
        await db?.close();
      } catch (_) {/* db may have failed to open */}
    }
  }

  static Future<bool> _hasSqliteHeader(String path) async {
    const List<int> expected = <int>[
      0x53,
      0x51,
      0x4c,
      0x69,
      0x74,
      0x65,
      0x20,
      0x66,
      0x6f,
      0x72,
      0x6d,
      0x61,
      0x74,
      0x20,
      0x33,
      0x00,
    ];
    final RandomAccessFile file = await File(path).open();
    try {
      if (await file.length() < expected.length) return false;
      final List<int> actual = await file.read(expected.length);
      for (int index = 0; index < expected.length; index++) {
        if (actual[index] != expected[index]) return false;
      }
      return true;
    } finally {
      await file.close();
    }
  }

  static Future<void> _insertDeviceLocalTableFromBak(
    FushiDatabase db,
    String table,
  ) async {
    switch (table) {
      case 'video_download_jobs':
        await _insertVideoDownloadJobsFromBak(db);
      case 'video_download_subscriptions':
        await _insertVideoDownloadSubscriptionsFromBak(db);
      default:
        await db.customStatement(
          'INSERT INTO $table SELECT * FROM devbak.$table',
        );
    }
  }

  /// Rebind a local job only when the imported DB still has the same semantic
  /// source/collection. Numeric ids are device-local autoincrements and may
  /// collide with an unrelated row from the backup device, so id existence by
  /// itself is not sufficient. A missing target is nulled and the job becomes
  /// actionable instead of aborting the whole FK-checked restore.
  static Future<void> _insertVideoDownloadJobsFromBak(
    FushiDatabase db,
  ) async {
    final List<String> columns = await _tableColumns(db, 'video_download_jobs');
    const String sourceLookup =
        'SELECT current_source.id FROM media_sources AS current_source '
        'JOIN devbak.media_sources AS old_source '
        'ON current_source.media_kind = old_source.media_kind '
        'AND current_source.transport = old_source.transport '
        'AND current_source.root_path = old_source.root_path '
        'WHERE old_source.id = j.target_source_id '
        'ORDER BY current_source.id LIMIT 1';
    const String collectionLookup = 'SELECT current_collection.id '
        'FROM media_collections AS current_collection '
        'JOIN devbak.media_collections AS old_collection '
        'ON current_collection.name = old_collection.name '
        'AND current_collection.collection_type = '
        'old_collection.collection_type '
        'WHERE old_collection.id = j.collection_id '
        'ORDER BY current_collection.id LIMIT 1';
    const String sourceMissing =
        'j.target_source_id IS NOT NULL AND NOT EXISTS ($sourceLookup)';
    const String collectionMissing =
        'j.collection_id IS NOT NULL AND NOT EXISTS ($collectionLookup)';
    const String referenceMissing =
        '(($sourceMissing) OR ($collectionMissing))';
    const String attentionMessage =
        'needsAttention: restored target source or collection is unavailable '
        'on this device';
    final List<String> selectExpressions = columns.map((String column) {
      switch (column) {
        case 'target_source_id':
          return 'CASE WHEN j.target_source_id IS NULL THEN NULL '
              'ELSE ($sourceLookup) END';
        case 'collection_id':
          return 'CASE WHEN j.collection_id IS NULL THEN NULL '
              'ELSE ($collectionLookup) END';
        case 'lifecycle':
          return "CASE WHEN $referenceMissing THEN 'needsAttention' "
              'ELSE j.lifecycle END';
        case 'claimed_by':
        case 'claim_expires_at':
          return 'NULL';
        case 'next_attempt_at':
          return 'CASE WHEN $referenceMissing THEN NULL '
              'ELSE j.next_attempt_at END';
        case 'last_error':
          return 'CASE WHEN $referenceMissing THEN CASE '
              'WHEN j.last_error IS NULL OR j.last_error = \'\' '
              "THEN '$attentionMessage' "
              "ELSE j.last_error || '; $attentionMessage' END "
              'ELSE j.last_error END';
        default:
          return 'j.${_quoteIdentifier(column)}';
      }
    }).toList(growable: false);
    await db.customStatement(
      'INSERT INTO video_download_jobs '
      '(${columns.map(_quoteIdentifier).join(', ')}) '
      'SELECT ${selectExpressions.join(', ')} '
      'FROM devbak.video_download_jobs AS j',
    );
  }

  /// Subscriptions have no lifecycle field. Missing local targets are surfaced
  /// by disabling the schedule, clearing its lease, and persisting the same
  /// `needsAttention:` marker consumed by the task UI.
  static Future<void> _insertVideoDownloadSubscriptionsFromBak(
    FushiDatabase db,
  ) async {
    final List<String> columns =
        await _tableColumns(db, 'video_download_subscriptions');
    const String sourceLookup =
        'SELECT current_source.id FROM media_sources AS current_source '
        'JOIN devbak.media_sources AS old_source '
        'ON current_source.media_kind = old_source.media_kind '
        'AND current_source.transport = old_source.transport '
        'AND current_source.root_path = old_source.root_path '
        'WHERE old_source.id = s.target_source_id '
        'ORDER BY current_source.id LIMIT 1';
    const String collectionLookup = 'SELECT current_collection.id '
        'FROM media_collections AS current_collection '
        'JOIN devbak.media_collections AS old_collection '
        'ON current_collection.name = old_collection.name '
        'AND current_collection.collection_type = '
        'old_collection.collection_type '
        'WHERE old_collection.id = s.collection_id '
        'ORDER BY current_collection.id LIMIT 1';
    const String sourceMissing =
        's.target_source_id IS NOT NULL AND NOT EXISTS ($sourceLookup)';
    const String collectionMissing =
        's.collection_id IS NOT NULL AND NOT EXISTS ($collectionLookup)';
    const String referenceMissing =
        '(($sourceMissing) OR ($collectionMissing))';
    const String attentionMessage =
        'needsAttention: restored target source or collection is unavailable '
        'on this device';
    final List<String> selectExpressions = columns.map((String column) {
      switch (column) {
        case 'target_source_id':
          return 'CASE WHEN s.target_source_id IS NULL THEN NULL '
              'ELSE ($sourceLookup) END';
        case 'collection_id':
          return 'CASE WHEN s.collection_id IS NULL THEN NULL '
              'ELSE ($collectionLookup) END';
        case 'enabled':
          return 'CASE WHEN $referenceMissing THEN 0 ELSE s.enabled END';
        case 'next_check_at':
          return 'CASE WHEN $referenceMissing THEN NULL '
              'ELSE s.next_check_at END';
        case 'claimed_by':
        case 'claim_expires_at':
          return 'NULL';
        case 'last_error':
          return 'CASE WHEN $referenceMissing THEN CASE '
              'WHEN s.last_error IS NULL OR s.last_error = \'\' '
              "THEN '$attentionMessage' "
              "ELSE s.last_error || '; $attentionMessage' END "
              'ELSE s.last_error END';
        default:
          return 's.${_quoteIdentifier(column)}';
      }
    }).toList(growable: false);
    await db.customStatement(
      'INSERT INTO video_download_subscriptions '
      '(${columns.map(_quoteIdentifier).join(', ')}) '
      'SELECT ${selectExpressions.join(', ')} '
      'FROM devbak.video_download_subscriptions AS s',
    );
  }

  static Future<List<String>> _tableColumns(
    FushiDatabase db,
    String table,
  ) async {
    final List<QueryRow> rows =
        await db.customSelect('PRAGMA table_info($table)').get();
    return rows
        .map((QueryRow row) => row.read<String>('name'))
        .toList(growable: false);
  }

  static String _quoteIdentifier(String value) =>
      '"${value.replaceAll('"', '""')}"';

  /// BUG-816: restores the content-registry preference rows from [bakPath] when
  /// the backup EXCLUDED their owning category, so an overwrite import of a
  /// books / fonts / localAudio-excluded backup never wipes this device's
  /// favorites / font registry / local-audio registry to empty. Mirror of
  /// [_stripExcludedContentRegistry]. `audio_source_configs` is restored whole
  /// from bak (the device keeps its own audio setup when localAudio was
  /// excluded), which subsumes the export-side B-filter. No-op (logged) if bak
  /// is gone.
  static Future<void> _reapplyExcludedContentRegistry(
    String dbDirectory,
    String bakPath, {
    required bool reapplyFavorites,
    required bool reapplyFonts,
    required bool reapplyLocalAudio,
  }) async {
    final List<String> keys = <String>[
      if (reapplyFavorites) _favoriteSentencesPrefKey,
      if (reapplyFonts) ...<String>[
        _fontCatalogPrefKey,
        ..._legacyFontPrefKeys
      ],
      if (reapplyLocalAudio) ...<String>[
        _localAudioDbsPrefKey,
        _audioSourceConfigsPrefKey,
      ],
    ];
    if (keys.isEmpty) return;
    if (!File(bakPath).existsSync()) {
      debugPrint('BackupRestoreService._reapplyExcludedContentRegistry: '
          'pre-restore.bak missing — local favorites/fonts/audio registry could '
          'not be preserved for a category-excluded backup.');
      return;
    }
    FushiDatabase? db;
    try {
      db = FushiDatabase(dbDirectory);
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      final String inList =
          keys.map((String k) => "'${k.replaceAll("'", "''")}'").join(', ');
      await db.customStatement("ATTACH DATABASE '$safeBak' AS crbak");
      await db.transaction(() async {
        await db!
            .customStatement('DELETE FROM preferences WHERE key IN ($inList)');
        await db.customStatement('INSERT INTO preferences '
            'SELECT * FROM crbak.preferences WHERE key IN ($inList)');
      });
      await db.customStatement('DETACH DATABASE crbak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e, st) {
      debugPrint('BackupRestoreService._reapplyExcludedContentRegistry failed: '
          '$e\n$st');
    } finally {
      try {
        await db?.close();
      } catch (_) {/* db may have failed to open */}
    }
  }

  /// 归档里主库条目的解析（读侧唯一入口）：新备份条目名是 [_dbName]（fushi.db），
  /// 老 Hibiki 时代的备份 / Android 迁移压缩包条目名是
  /// [legacyHibikiDatabaseFileName]（hibiki.db）。旧条目名属于「读旧数据的迁移
  /// 代码」豁免；写侧（导出/提取目标路径）永远只落新名。
  static ArchiveFile? _findDbEntry(Archive archive) =>
      archive.findFile(_dbName) ??
      archive.findFile(legacyHibikiDatabaseFileName);

  /// Validate a backup ZIP. Returns metadata if valid.
  ///
  /// Streams the central directory via [InputFileStream] instead of reading the
  /// whole archive into memory — a full-data backup can be many GB (book + audio
  /// trees), so there is no size cap and the whole file must never be buffered.
  /// Only the small `backup_meta.json` entry is decompressed; the db presence
  /// check is metadata-only.
  static Future<BackupMeta?> validateBackup(String zipPath) async {
    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeBuffer(input);
      final BackupMeta? meta = _readBackupMeta(archive);
      if (meta == null) return null;
      if (_findDbEntry(archive) == null) return null;
      return meta;
    } catch (e, st) {
      // A null result tells the UI "invalid backup". Surface the real reason
      // (corrupt zip / read error / OOM) so it is not silently indistinguishable
      // from a genuinely malformed archive (review W4).
      debugPrint('BackupRestoreService.validateBackup failed for $zipPath: $e\n$st');
      return null;
    } finally {
      await input?.close();
    }
  }

  /// Settings-layer tables restored from THIS device when [restoreBackup]
  /// runs with importSettings=false. Order matters: `profiles` first (FK target
  /// of the rest). `preferences` is handled separately (audiobook positions are
  /// content and follow the backup). No content table FKs into these, and
  /// `book_profiles.bookUid` is plain text, so a wholesale swap is FK-safe.
  static const List<String> _settingsLayerTables = <String>[
    'profiles',
    'profile_settings',
    'media_type_profiles',
    'book_profiles',
  ];

  /// Restore a backup (overwrite mode), replacing the current database files.
  /// 用户视角的「恢复备份」顶层入口；merge 模式见 [mergeRestoreBackup]，内部
  /// 子步骤一律 reapply* 动词（restore 保留给本顶层语义）。
  ///
  /// This is a static method because the database must already be closed
  /// before calling — the caller is responsible for closing the DB first.
  ///
  /// [importSettings] (default true = full restore):
  /// - true: everything comes from the backup, EXCEPT device-local sync config
  ///   ([SyncRepository.deviceLocalPrefKeys]) which is always preserved (the
  ///   backup has none — they're stripped on export — so a naive swap would log
  ///   you out). Re-applied immediately; crash-recoverable via the sidecar.
  /// - false: keep THIS device's settings layer (preferences + profiles +
  ///   bindings = fonts/appearance/reading/profiles); only CONTENT comes from
  ///   the backup. Done inline: opening the imported DB migrates it to the
  ///   current schema, then the settings layer is copied back from
  ///   pre-restore.bak (both at current schema → column-aligned, FK-safe). The
  ///   sidecar + bak written before the overwrite are a crash-recovery net so
  ///   [recoverPendingRestore] can finish the restore if this crashes mid-way.
  static Future<void> restoreBackup({
    required String dbDirectory,
    required String zipPath,
    bool importSettings = true,
    Set<BackupCategory>? categories,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
    String? fontsRootDirectory,
    String? videosRootDirectory,
    void Function(double progress)? onProgress,
  }) async {
    final dbPath = p.join(dbDirectory, _dbName);
    // Stream the central directory instead of buffering the whole (GB-scale)
    // archive in memory. Each entry's bytes are read lazily on `.content`; the
    // stream stays open until every read completes (closed in `finally`).
    final InputFileStream input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? dbFile = _findDbEntry(archive);
      if (dbFile == null) throw StateError('No $_dbName in backup archive');

      // TODO-1183: determinate progress across every streamed byte.
      final void Function(int deltaBytes) reportBytes =
          _archiveByteProgress(archive, onProgress);

      // Parse the source-device content roots so book/audio paths can be
      // rebased onto this device after the trees are restored.
      final BackupMeta? meta = _readBackupMeta(archive);
      // TODO-1193: a backup that unticked `settings` / `profiles` carries an
      // EMPTY settings / profiles layer BY CHOICE. On an overwrite import the DB
      // is replaced wholesale, so without a guard those empty layers would WIPE
      // this device's settings/profiles. Detect the choice from the meta and
      // preserve the LOCAL layer from bak below (mirrors BUG-454's dictionary
      // preserve-on-absent). importSettings=false already keeps the whole
      // settings layer from bak, so it is inherently safe.
      final bool backupSettingsExcluded =
          meta?.excludedCategories.contains(BackupCategory.settings.name) ??
              false;
      final bool backupProfilesExcluded =
          meta?.excludedCategories.contains(BackupCategory.profiles.name) ??
              false;
      // BUG-816: content-registry prefs (favorites / fonts / local-audio) travel
      // EMPTY when their owning category was unticked, so an overwrite import
      // must preserve THIS device's rows from bak instead of wiping them.
      final bool backupBooksExcluded =
          meta?.excludedCategories.contains(BackupCategory.books.name) ?? false;
      final bool backupFontsExcluded =
          meta?.excludedCategories.contains(BackupCategory.fonts.name) ?? false;
      final bool backupLocalAudioExcluded =
          meta?.excludedCategories.contains(BackupCategory.localAudio.name) ??
              false;

      final String? dictionaryReapplyDirectory = dictionaryResourceDirectory;
      List<MapEntry<ArchiveFile, String>>? dictionaryReapplyPlan;
      if (dictionaryReapplyDirectory != null) {
        dictionaryReapplyPlan = _buildDictionaryReapplyPlan(
          archive: archive,
          dictionaryResourceDirectory: dictionaryReapplyDirectory,
        );
      }
      // BUG-454: a backup exported WITHOUT the dictionary category carries no
      // `dictionaryResources/` files AND has its dictionary DB rows stripped on
      // export (`_stripDictionaryState`). Detecting "the backup has no
      // dictionary files" lets the overwrite import PRESERVE this device's
      // existing dictionaries (metadata rows + resource files) instead of
      // wiping them — the backup simply didn't include that category, the same
      // selective-preserve contract the device-local sync prefs already follow.
      final bool backupHasDictionaries = archive.files.any((ArchiveFile f) =>
          f.isFile &&
          f.name
              .replaceAll(r'\', '/')
              .startsWith('$_dictionaryResourcesPrefix/'));

      // TODO-1358: honour a per-category IMPORT selection (overwrite path only;
      // merge always combines everything). A null [categories] restores every
      // category the backup carries (legacy). Unticking a category on import:
      //  - dictionary -> treat as if the backup carries no dictionaries so the
      //    BUG-454 path preserves THIS device dictionaries (re-seated from bak).
      //  - audiobooks / fonts / videos / localAudio -> skip restoring those files
      //    (and skip rebasing their paths); the DB library index still restores.
      // Books / progress / statistics always restore (the core library index in
      // the overwrite DB blob); settings / profiles stay governed by
      // [importSettings].
      bool wants(BackupCategory c) =>
          categories == null || categories.contains(c);
      final bool effectiveHasDictionaries =
          backupHasDictionaries && wants(BackupCategory.dictionary);
      final String? effAudiobooksRoot =
          wants(BackupCategory.audiobooks) ? audiobooksRootDirectory : null;
      final String? effFontsRoot =
          wants(BackupCategory.fonts) ? fontsRootDirectory : null;
      final String? effVideosRoot =
          wants(BackupCategory.videos) ? videosRootDirectory : null;
      final String? effLocalAudioRoot =
          wants(BackupCategory.localAudio) ? dbDirectory : null;

      final sidecar = File(p.join(dbDirectory, _preserveSidecar));
      final String bakPath = '$dbPath.pre-restore.bak';
      final currentDb = File(dbPath);
      final bool haveCurrent = currentDb.existsSync();
      bool deviceLocalTablesReapplied = !haveCurrent;

      // 1) Snapshot the current DB (crash safety) + record what to preserve.
      //    Skipped on a fresh install (no current DB) → backup applied verbatim,
      //    so the toggle is moot there.
      Map<String, String> preservedSync = const <String, String>{};
      if (haveCurrent) {
        late final Map<String, dynamic> sidecarPayload;
        if (importSettings) {
          preservedSync = await _readDeviceLocalPrefs(dbDirectory);
          sidecarPayload = <String, dynamic>{
            'mode': 'prefs',
            'prefs': preservedSync,
            'preserveDeviceLocalTables': true,
            if (backupSettingsExcluded) 'preserveSettings': true,
            if (backupProfilesExcluded) 'preserveProfiles': true,
          };
        } else {
          sidecarPayload = <String, dynamic>{
            'mode': 'settings',
            'preserveDeviceLocalTables': true,
          };
        }
        // The v78 download graph is device-local even when there are no sync
        // preferences to preserve, so every destructive overwrite needs both
        // artifacts. Copy the database first: a sidecar must never advertise a
        // recoverable restore before its corresponding snapshot exists.
        await currentDb.copy(bakPath);
        await sidecar.writeAsString(
          jsonEncode(sidecarPayload),
          flush: true,
        );
      }

      // Must delete -wal/-shm AFTER reading prefs (step 1 opened+closed a WAL
      // connection) and BEFORE overwriting the main .db: leftover WAL frames
      // from the old DB would otherwise be replayed against the imported file
      // and corrupt it.
      final walFile = File('$dbPath-wal');
      if (walFile.existsSync()) await walFile.delete();
      final shmFile = File('$dbPath-shm');
      if (shmFile.existsSync()) await shmFile.delete();

      // 2) Overwrite with the backup DB bytes — streamed on a background
      //    isolate so a multi-GB DB never materializes in the heap (OOM,
      //    TODO-1183) and never blocks the UI isolate.
      await _extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(dbFile.name, dbPath),
        ],
        onBytes: reportBytes,
      );

      if (effectiveHasDictionaries &&
          dictionaryReapplyPlan != null &&
          dictionaryReapplyDirectory != null) {
        // Backup carries dictionaries → replace this device's resources with
        // the backup's (the DB overwrite already brought the matching rows).
        await _reapplyDictionaryResources(
          zipPath: zipPath,
          reapplyPlan: dictionaryReapplyPlan,
          dictionaryResourceDirectory: dictionaryReapplyDirectory,
          onBytes: reportBytes,
        );
      } else if (!effectiveHasDictionaries &&
          haveCurrent &&
          dictionaryReapplyDirectory != null) {
        // BUG-454: backup has NO dictionaries → keep this device's. The DB was
        // just overwritten with the backup's (dictionary tables empty), so
        // re-seat the local dictionary rows from pre-restore.bak. The resource
        // FILES on disk were never touched (we skipped the unconditional wipe
        // in _reapplyDictionaryResources), so rows + files stay consistent.
        // Gated on a managed dictionary dir: the live app always supplies it;
        // a null dir means the caller isn't managing dictionaries at all, so
        // there is nothing to preserve (and bak may not even be a real DB in
        // such minimal call sites).
        await _reapplyDictionaryTablesFromBak(dbDirectory, bakPath);
      }

      // 2b) Restore the book + audiobook content trees (full-data backup).
      //     PREPARE both (write to sibling `.import-tmp` dirs) BEFORE COMMITTING
      //     either (fast rename-swap), so a failure during the GB-scale write
      //     phase swaps nothing and leaves both existing trees intact — a user's
      //     whole library must never be half-destroyed. Only runs when the
      //     caller supplies the roots AND the backup carries that tree.
      final List<String> toCommit = <String>[];
      try {
        if (booksRootDirectory != null &&
            wants(BackupCategory.books) &&
            await _prepareTreeReapply(zipPath, archive,
                archiveBooksPrefix(archive), booksRootDirectory,
                onBytes: reportBytes)) {
          toCommit.add(booksRootDirectory);
        }
        if (effAudiobooksRoot != null &&
            await _prepareTreeReapply(
                zipPath, archive, _audiobooksPrefix, effAudiobooksRoot,
                onBytes: reportBytes)) {
          toCommit.add(effAudiobooksRoot);
        }
        if (effFontsRoot != null &&
            await _prepareTreeReapply(
                zipPath, archive, _fontsPrefix, effFontsRoot,
                onBytes: reportBytes)) {
          toCommit.add(effFontsRoot);
        }
        if (effVideosRoot != null &&
            await _prepareTreeReapply(
                zipPath, archive, _videosPrefix, effVideosRoot,
                onBytes: reportBytes)) {
          toCommit.add(effVideosRoot);
        }
      } catch (_) {
        // A write failed: drop every staged temp dir; no tree was swapped.
        if (booksRootDirectory != null) {
          await _abortPreparedTree(booksRootDirectory);
        }
        if (effAudiobooksRoot != null) {
          await _abortPreparedTree(effAudiobooksRoot);
        }
        if (effFontsRoot != null) {
          await _abortPreparedTree(effFontsRoot);
        }
        if (effVideosRoot != null) {
          await _abortPreparedTree(effVideosRoot);
        }
        rethrow;
      }
      // All writes succeeded → commit each prepared tree (fast renames).
      for (final String root in toCommit) {
        await _commitPreparedTree(root);
      }

      // 2c) Restore local-audio databases into the support directory. These are
      //     individual files sharing the directory with hibiki.db, so they are
      //     extracted file-by-file (never the destructive tree swap). When the
      //     backup carries no localAudio/ prefix the existing local-audio DBs
      //     are left untouched (same preserve-on-absent contract as the trees).
      if (wants(BackupCategory.localAudio)) {
        await _reapplyLocalAudioFiles(zipPath, archive, dbDirectory,
            onBytes: reportBytes);
      }

      // 3) Restore what must stay on this device — inline, not deferred to
      //    startup, so the common path never depends on bak surviving a restart.
      if (importSettings) {
        // TODO-1193: the backup EXCLUDED settings and/or profiles → its DB blob
        // has those layers empty by choice. Preserve THIS device's layer from
        // bak FIRST so the overwrite never wipes settings/profiles to empty.
        // Runs before the sync re-apply so _applyPreservedConfig stays the
        // authoritative last word on sync config (and clears the folder cache).
        if ((backupSettingsExcluded || backupProfilesExcluded) && haveCurrent) {
          await _reapplyExcludedSettingsLayers(
            dbDirectory,
            bakPath,
            reapplySettings: backupSettingsExcluded,
            reapplyProfiles: backupProfilesExcluded,
          );
        }
        // Re-apply device-local sync config (preferences is schema-stable).
        if (preservedSync.isNotEmpty) {
          await _applyPreservedConfig(dbDirectory, preservedSync);
        }
      } else if (haveCurrent) {
        // Keep this device's whole settings layer.
        await _reapplySettingsLayer(dbDirectory);
      }

      // 3a) BUG-816: the export wipes device-local tables (LAN pairing token +
      //     sync baselines) unconditionally, so they arrive EMPTY. Restore this
      //     device's rows from bak on any overwrite import (both importSettings
      //     branches) — else the overwrite would wipe the device's pairings and
      //     baselines. No-op on a fresh install (no bak).
      if (haveCurrent) {
        deviceLocalTablesReapplied =
            await _reapplyDeviceLocalTablesFromBak(dbDirectory, bakPath);
        // BUG-816: preserve THIS device's content-registry prefs from bak when
        // the backup excluded their owning category (books/fonts/localAudio) —
        // runs in both importSettings branches, mirroring the export strip.
        await _reapplyExcludedContentRegistry(
          dbDirectory,
          bakPath,
          reapplyFavorites: backupBooksExcluded,
          reapplyFonts: backupFontsExcluded,
          reapplyLocalAudio: backupLocalAudioExcluded,
        );
      }

      // 3b) Rebase the imported DB's stored absolute paths (which point at the
      //     SOURCE device's roots) onto this device's roots. Books/audiobooks
      //     are content, so they come from the backup in BOTH import modes →
      //     always rebase. No-op for a legacy backup (meta has no roots).
      if (meta != null) {
        await _rebaseAllPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newBooksRoot: booksRootDirectory,
          newAudiobooksRoot: effAudiobooksRoot,
          newFontsRoot: effFontsRoot,
          newLocalAudioRoot: effLocalAudioRoot,
          newVideosRoot: effVideosRoot,
        );
      }

      // 3c) Honour the per-category IMPORT selection for the DB-content
      //     categories the overwrite blob carries wholesale (TODO-1358). The
      //     file categories are already gated above (skipped file restore), but
      //     books / statistics / progress live in the swapped-in DB, so strip
      //     the unticked ones here. Overwrite semantics: unticking = that
      //     category's data does not end up on this device (the DB was replaced
      //     wholesale, so there is no local layer to preserve — mirrors how the
      //     statistics/progress strip already works on the export side).
      if (!wants(BackupCategory.books)) {
        // Strip every book row (+ its cascade) so no book from the backup
        // travels; the hoshi_books tree restore was skipped above too.
        await _retainBooks(dbDirectory, const <String>{});
      }
      if (!wants(BackupCategory.videos)) {
        // Videos live in the overwrite DB blob (video_books + cascade), so
        // unticking the video category must strip those rows too — skipping the
        // FILE restore (effVideosRoot=null) alone left every video_books row in
        // the swapped-in DB, so the videos imported uninvited & un-skippable even
        // when the dialog did offer the toggle (BUG-779). Mirrors the books strip
        // and the export-side [_retainVideos].
        await _retainVideos(dbDirectory, const <String>{});
      }
      if (!wants(BackupCategory.audiobooks)) {
        // Same class as videos (BUG-781): audiobook rows (audiobooks + audio_cues
        // + srt shelf entry) ride the overwrite DB blob, so unticking the
        // audiobooks category must strip them — the skipped FILE restore
        // (effAudiobooksRoot=null) alone left ghost audiobooks (shelf + alignment
        // rows pointing at audio that never travelled).
        await _retainAudiobooks(dbDirectory, const <String>{});
      }
      if (!wants(BackupCategory.statistics) ||
          !wants(BackupCategory.progress)) {
        await _stripExcludedDataCategories(
          dbDirectory,
          stripProgress: !wants(BackupCategory.progress),
          stripStatistics: !wants(BackupCategory.statistics),
          // settings / profiles stay governed by the importSettings toggle and
          // the excluded-layer preserve above — never touched by this strip.
          stripSettings: false,
          stripProfiles: false,
        );
      }

      // 4) Success: drop the sidecar and the pre-restore copy (no disk leak).
      // A failed device-local replay is recoverable at the next startup, but
      // only while BOTH artifacts survive. The replay transaction starts with
      // a child-first wipe and is therefore safe to run again.
      if (deviceLocalTablesReapplied) {
        await _safeDelete(sidecar.path);
        await _safeDelete(bakPath);
      } else {
        debugPrint('BackupRestoreService.restoreBackup: device-local tables were not '
            'reapplied; retaining restore sidecar and pre-restore.bak for '
            'startup recovery.');
      }
    } finally {
      await input.close();
    }
  }

  /// Sidecar file marking a pending MERGE import (TODO-888). The merge runs in
  /// one Drift transaction, so a crash leaves the DB already-consistent (the
  /// transaction either committed or rolled back); this sidecar only drives
  /// startup cleanup of the temp `merge-src` + `pre-merge.bak` files.
  static const String _mergeSidecar = '$_dbName.merge-preserve.json';
  static const String _mergeSrcName = '$_dbName.merge-src';

  /// MERGE a backup into the current database instead of overwriting it
  /// (TODO-888). The device keeps everything it has; the backup only ADDS what
  /// is missing and MAX-unions statistics, so re-importing the same backup is
  /// idempotent. Unlike [restoreBackup] this NEVER touches the destructive
  /// overwrite path (`writeAsBytes`) or the two-phase tree swap; content trees
  /// are restored copy-if-absent (existing files are never replaced or deleted).
  ///
  /// The caller must close the app's DB first (same contract as
  /// [restoreBackup]); this opens its own connections. Crash safety: the
  /// whole row merge is ONE [FushiDatabase.transaction] (rolled back on any
  /// failure) plus a `pre-merge.bak` snapshot for manual recovery, and a
  /// `mode:'merge'` sidecar so [recoverPendingRestore] cleans up temp files.
  static Future<void> mergeRestoreBackup({
    required String dbDirectory,
    required String zipPath,
    Set<BackupCategory>? categories,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
    String? fontsRootDirectory,
    String? videosRootDirectory,
    void Function(double progress)? onProgress,
    bool adoptSourcePreferences = false,
  }) async {
    // Per-category merge selection (import dialog, merge mode). null = merge
    // every category (legacy full merge). Gates BOTH the DB row merge (via the
    // engine) AND the content-tree copies below, so an unticked category adds
    // nothing — neither rows nor files.
    bool wants(BackupCategory c) =>
        categories == null || categories.contains(c);
    final Set<String>? enabledCategoryNames =
        categories?.map((BackupCategory c) => c.name).toSet();
    final String dbPath = p.join(dbDirectory, _dbName);
    final String mergeSrcPath = p.join(dbDirectory, _mergeSrcName);
    final String bakPath = '$dbPath.pre-merge.bak';
    final File sidecar = File(p.join(dbDirectory, _mergeSidecar));

    final InputFileStream input = InputFileStream(zipPath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? dbFile = _findDbEntry(archive);
      if (dbFile == null) throw StateError('No $_dbName in backup archive');

      // TODO-1183: determinate progress across every streamed byte.
      final void Function(int deltaBytes) reportBytes =
          _archiveByteProgress(archive, onProgress);

      final BackupMeta? meta = _readBackupMeta(archive);

      // 1) Extract the backup DB to a sibling temp file (NEVER overwrite the
      //    live DB). Drop any stale merge-src/-wal/-shm from a prior crash.
      await _safeDelete(mergeSrcPath);
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');
      await _extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(dbFile.name, mergeSrcPath),
        ],
        onBytes: reportBytes,
      );

      // 2) Migrate the backup DB up to the current schema so its columns align
      //    with the live DB for the ATTACH-based row merge. (Its schemaVersion
      //    is <= current — validated by the caller.) Opening + closing
      //    FushiDatabase on its file runs onUpgrade if needed.
      final FushiDatabase srcMigrate = FushiDatabase.atFile(mergeSrcPath);
      try {
        await srcMigrate.customStatement('PRAGMA user_version');
      } finally {
        await srcMigrate.close();
      }
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');

      // 3) Snapshot the live DB for manual recovery + drop the crash-cleanup
      //    sidecar BEFORE mutating the live DB.
      final File currentDb = File(dbPath);
      if (currentDb.existsSync()) {
        await currentDb.copy(bakPath);
      }
      await sidecar.writeAsString(jsonEncode(<String, dynamic>{
        'mode': 'merge',
        'mergeSrc': mergeSrcPath,
      }));

      // 4) Open the live DB, ATTACH the backup, run the whole row merge in one
      //    transaction (rolled back on any failure -> DB unchanged).
      final FushiDatabase db = FushiDatabase(dbDirectory);
      try {
        final String safeSrc =
            mergeSrcPath.replaceAll(r'\', '/').replaceAll("'", "''");
        await db.customStatement("ATTACH DATABASE '$safeSrc' AS mergesrc");
        try {
          // TODO-1261: only import video rows whose file travelled (or streaming
          // URLs) so a backup never lands a dead "empty video" shell. The carried
          // set is the exact video files packed by export (meta.videoFiles keys).
          await BackupMergeEngine(
            db,
            carriedVideoSourcePaths:
                meta?.videoFiles.keys.toSet() ?? const <String>{},
            enabledCategoryNames: enabledCategoryNames,
            adoptSourcePreferences: adoptSourcePreferences,
          ).merge();
        } finally {
          await db.customStatement('DETACH DATABASE mergesrc');
        }
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await db.close();
      }

      // 5) Restore content trees COPY-IF-ABSENT (never delete/replace existing
      //    files — the device's own library must stay intact). Each tree is
      //    gated by its category so an unticked category copies no files (its
      //    rows were likewise skipped by the engine above).
      if (dictionaryResourceDirectory != null &&
          wants(BackupCategory.dictionary)) {
        await _copyTreeIfAbsent(zipPath, archive, _dictionaryResourcesPrefix,
            dictionaryResourceDirectory,
            onBytes: reportBytes);
      }
      if (booksRootDirectory != null && wants(BackupCategory.books)) {
        await _copyTreeIfAbsent(
            zipPath, archive, archiveBooksPrefix(archive), booksRootDirectory,
            onBytes: reportBytes);
      }
      if (audiobooksRootDirectory != null && wants(BackupCategory.audiobooks)) {
        await _copyTreeIfAbsent(
            zipPath, archive, _audiobooksPrefix, audiobooksRootDirectory,
            onBytes: reportBytes);
      }
      if (fontsRootDirectory != null && wants(BackupCategory.fonts)) {
        await _copyTreeIfAbsent(
            zipPath, archive, _fontsPrefix, fontsRootDirectory,
            onBytes: reportBytes);
      }
      if (videosRootDirectory != null && wants(BackupCategory.videos)) {
        await _copyTreeIfAbsent(
            zipPath, archive, _videosPrefix, videosRootDirectory,
            onBytes: reportBytes);
      }
      // Local-audio DBs are copy-if-absent into the support directory (never
      // overwrite the device's own local_audio_*.db files).
      if (wants(BackupCategory.localAudio)) {
        await _reapplyLocalAudioFiles(zipPath, archive, dbDirectory,
            overwrite: false, onBytes: reportBytes);
      }

      // 6) Rebase the newly-merged backup rows' stored paths onto this device's
      //    roots. Device-local rows aren't under the backup's source root, so
      //    rebasePath leaves them untouched (a no-op for them).
      if (meta != null) {
        await _rebaseAllPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newBooksRoot: booksRootDirectory,
          newAudiobooksRoot: audiobooksRootDirectory,
          newFontsRoot: fontsRootDirectory,
          newLocalAudioRoot: dbDirectory,
          newVideosRoot: videosRootDirectory,
        );
      }

      // 7) Success: drop the merge-src temp, the bak, and the sidecar.
      await _safeDelete(mergeSrcPath);
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');
      await _safeDelete(bakPath);
      await _safeDelete(sidecar.path);
    } finally {
      await input.close();
    }
  }

  /// Temp filename for the preview-only extracted backup DB (TODO-1195 part B).
  static const String _mergePreviewSrcName = '$_dbName.merge-preview-src';

  /// Read-only estimate of what a MERGE import of [zipPath] would change on this
  /// device, for the import confirm dialog (TODO-1195 part B). Extracts ONLY the
  /// backup's main-DB entry to a temp file, migrates it to the current schema,
  /// ATTACHes it to the still-open [liveDb] and runs [BackupMergeEngine.preview]
  /// (no mutation, no transaction), then detaches and cleans up. Best-effort:
  /// any failure returns null so the caller shows a generic dialog and the
  /// import is never blocked by a preview problem. The content trees are NOT
  /// extracted (only row counts matter), so this stays cheap even for a
  /// multi-GB backup.
  static Future<BackupMergePreview?> previewMergeRestore({
    required FushiDatabase liveDb,
    required String dbDirectory,
    required String zipPath,
  }) async {
    final String tmpSrc = p.join(dbDirectory, _mergePreviewSrcName);
    try {
      final InputFileStream input = InputFileStream(zipPath);
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBuffer(input);
      } finally {
        await input.close();
      }
      final ArchiveFile? dbFile = _findDbEntry(archive);
      if (dbFile == null) return null;

      // TODO-1261: the merge only materialises REACHABLE video rows (streaming
      // or a local file the backup carried), so the preview must count with the
      // same predicate. The carried set is the packed video files (meta.videoFiles).
      final BackupMeta? meta = _readBackupMeta(archive);
      final Set<String> carriedVideoSourcePaths =
          meta?.videoFiles.keys.toSet() ?? const <String>{};

      await _safeDelete(tmpSrc);
      await _safeDelete('$tmpSrc-wal');
      await _safeDelete('$tmpSrc-shm');
      await _extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(dbFile.name, tmpSrc),
        ],
      );

      // Migrate the extracted DB up to the current schema so its columns align
      // for the ATTACH-based COUNT queries (same contract as the real merge).
      final FushiDatabase srcMigrate = FushiDatabase.atFile(tmpSrc);
      try {
        await srcMigrate.customStatement('PRAGMA user_version');
      } finally {
        await srcMigrate.close();
      }
      await _safeDelete('$tmpSrc-wal');
      await _safeDelete('$tmpSrc-shm');

      final String safeSrc = tmpSrc.replaceAll(r'\', '/').replaceAll("'", "''");
      await liveDb.customStatement("ATTACH DATABASE '$safeSrc' AS previewsrc");
      try {
        return await BackupMergeEngine(
          liveDb,
          srcAlias: 'previewsrc',
          carriedVideoSourcePaths: carriedVideoSourcePaths,
        ).preview();
      } finally {
        await liveDb.customStatement('DETACH DATABASE previewsrc');
      }
    } catch (e, st) {
      // Never block the import on a preview failure — fall back to a generic
      // confirm dialog.
      debugPrint('BackupRestoreService.previewMergeRestore failed: $e\n$st');
      return null;
    } finally {
      await _safeDelete(tmpSrc);
      await _safeDelete('$tmpSrc-wal');
      await _safeDelete('$tmpSrc-shm');
    }
  }

  /// Copies every file under `<prefix>/` in [archive] into [targetRootPath],
  /// SKIPPING any whose destination already exists (the merge-import invariant:
  /// never delete or overwrite the device's own content). Reuses the same path
  /// traversal safety checks as the overwrite path's [_buildTreeReapplyPlan].
  static Future<void> _copyTreeIfAbsent(
    String zipPath,
    Archive archive,
    String prefix,
    String targetRootPath, {
    void Function(int deltaBytes)? onBytes,
  }) async {
    final List<MapEntry<ArchiveFile, String>> plan = _buildTreeReapplyPlan(
      archive: archive,
      prefix: prefix,
      targetRootPath: targetRootPath,
    );
    final List<MapEntry<String, String>> toWrite = <MapEntry<String, String>>[];
    for (final MapEntry<ArchiveFile, String> entry in plan) {
      if (await File(entry.value).exists()) continue; // copy-if-absent
      toWrite.add(MapEntry<String, String>(entry.key.name, entry.value));
    }
    await _extractEntriesStreaming(
      zipPath: zipPath,
      entries: toWrite,
      onBytes: onBytes,
    );
  }

  /// Cleans up a crashed/finished MERGE import's temp files (TODO-888). Returns
  /// true when a merge sidecar was present (and was handled), false otherwise.
  /// The DB itself is untouched: the merge transaction is all-or-nothing, so the
  /// live DB is already consistent regardless of when a crash happened.
  static Future<bool> recoverMergeRestore(String dbDirectory) async {
    final File sidecar = File(p.join(dbDirectory, _mergeSidecar));
    if (!sidecar.existsSync()) return false;
    try {
      final Map<String, dynamic> decoded =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      final Object? mergeSrc = decoded['mergeSrc'];
      if (mergeSrc is String) {
        await _safeDelete(mergeSrc);
        await _safeDelete('$mergeSrc-wal');
        await _safeDelete('$mergeSrc-shm');
      }
    } catch (e, st) {
      debugPrint('BackupRestoreService.recoverMergeRestore failed: $e\n$st');
    }
    await _safeDelete(p.join(dbDirectory, _mergeSrcName));
    await _safeDelete(p.join(dbDirectory, '$_mergeSrcName-wal'));
    await _safeDelete(p.join(dbDirectory, '$_mergeSrcName-shm'));
    await _safeDelete(p.join(dbDirectory, '$_dbName.pre-merge.bak'));
    await _safeDelete(sidecar.path);
    return true;
  }

  /// Finish a pending import at startup, before any sync code reads prefs.
  /// Handles both: (a) re-applying device-local sync prefs if a full-restore
  /// import crashed mid-way; (b) restoring this device's settings layer for a
  /// keep-settings import. No-op when no sidecar is present.
  static Future<void> recoverPendingRestore(String dbDirectory) async {
    // MERGE import (TODO-888) leaves its own sidecar. The row merge ran in ONE
    // Drift transaction, so the live DB is already consistent whether or not we
    // crashed (the transaction either committed or rolled back) — there is
    // NOTHING to apply to the DB, only leftover temp files to sweep. Handle it
    // first + return so a 'merge' marker can never fall through to the legacy
    // bare-map prefs path and get mis-applied. (recoverMergeRestore is reused by
    // tests; keep the sweep there.)
    if (await recoverMergeRestore(dbDirectory)) return;

    final sidecar = File(p.join(dbDirectory, _preserveSidecar));
    if (!sidecar.existsSync()) return;
    final String bakPath = p.join(dbDirectory, '$_dbName.pre-restore.bak');
    bool sidecarStateApplied = false;
    bool shouldReapplyDeviceLocalTables = false;
    try {
      final raw = await sidecar.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      shouldReapplyDeviceLocalTables =
          decoded['preserveDeviceLocalTables'] == true;
      if (decoded['mode'] == 'settings') {
        await _reapplySettingsLayer(dbDirectory);
      } else {
        // 'prefs' mode, or a legacy bare-map sidecar (no 'mode' field).
        // TODO-1193: preserve the LOCAL settings/profiles layer from bak first
        // (a settings/profiles-excluded backup crashed mid-import), then re-apply
        // device-local sync config — same order as the inline path.
        final bool preserveSettings = decoded['preserveSettings'] == true;
        final bool preserveProfiles = decoded['preserveProfiles'] == true;
        if (preserveSettings || preserveProfiles) {
          await _reapplyExcludedSettingsLayers(
            dbDirectory,
            p.join(dbDirectory, '$_dbName.pre-restore.bak'),
            reapplySettings: preserveSettings,
            reapplyProfiles: preserveProfiles,
          );
        }
        final Map<String, dynamic> prefsRaw =
            (decoded['prefs'] as Map<String, dynamic>?) ?? decoded;
        final prefs = prefsRaw.map((k, v) => MapEntry(k, v as String));
        if (prefs.isNotEmpty) await _applyPreservedConfig(dbDirectory, prefs);
      }
      sidecarStateApplied = true;
    } on FormatException catch (e, st) {
      // A malformed marker cannot describe settings/prefs, but the independent
      // pre-restore DB snapshot can still rescue device-local tables. Preserve
      // the historical behavior of dropping an irreparably corrupt marker once
      // that table replay succeeds.
      debugPrint('BackupRestoreService.recoverPendingRestore: corrupt sidecar: '
          '$e\n$st');
      sidecarStateApplied = true;
    } on TypeError catch (e, st) {
      debugPrint('BackupRestoreService.recoverPendingRestore: invalid sidecar shape: '
          '$e\n$st');
      sidecarStateApplied = true;
    } catch (e, st) {
      // Database/filesystem failures are retryable. Keep both artifacts so the
      // next startup can replay the same idempotent operations.
      debugPrint('BackupRestoreService.recoverPendingRestore failed: $e\n$st');
      return;
    }

    if (!sidecarStateApplied) return;
    if (shouldReapplyDeviceLocalTables) {
      final bool deviceLocalTablesReapplied =
          await _reapplyDeviceLocalTablesFromBak(dbDirectory, bakPath);
      if (!deviceLocalTablesReapplied) {
        debugPrint('BackupRestoreService.recoverPendingRestore: retaining sidecar and '
            'pre-restore.bak because device-local table replay did not finish.');
        return;
      }
    }
    await _safeDelete(sidecar.path);
    await _safeDelete(bakPath);
  }

  /// Restores the settings layer (preferences + profiles + bindings) from
  /// pre-restore.bak into the freshly-imported DB, keeping the backup's content.
  /// Runs at startup, so both DBs are at the current schema → `SELECT *` columns
  /// align. audiobook positions are content and stay from the backup.
  static Future<void> _reapplySettingsLayer(String dbDirectory) async {
    final String bakPath = p.join(dbDirectory, '$_dbName.pre-restore.bak');
    if (!File(bakPath).existsSync()) {
      // bak is the only copy of this device's settings layer (the main DB was
      // already overwritten with the backup). If it's gone we cannot restore —
      // surface it loudly rather than silently dropping the user's settings.
      // (Normal flow restores inline while bak definitely exists; reaching here
      // means a crash + external deletion of bak before the next launch.)
      debugPrint('BackupRestoreService._reapplySettingsLayer: pre-restore.bak missing '
          '— local settings/profiles could not be preserved on import.');
      return;
    }
    final db = FushiDatabase(dbDirectory);
    try {
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS bak");
      await db.transaction(() async {
        // preferences: keep this device's SETTINGS from bak, but let CONTENT
        // prefs (audiobook positions, favorites, local-audio / audio-source
        // registry, font registry) follow the imported backup — see
        // [_keepDeviceSettingsPrefPredicate]. `sync_*` stays restored from bak
        // (device-local, never exported), which this predicate keeps.
        await db.customStatement(
            'DELETE FROM preferences WHERE $_keepDeviceSettingsPrefPredicate');
        await db.customStatement(
            'INSERT INTO preferences SELECT * FROM bak.preferences '
            'WHERE $_keepDeviceSettingsPrefPredicate');
        // profiles before its FK dependents.
        for (final String t in _settingsLayerTables) {
          await db.customStatement('DELETE FROM $t');
          await db.customStatement('INSERT INTO $t SELECT * FROM bak.$t');
        }
      });
      await db.customStatement('DETACH DATABASE bak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Restores ONLY the excluded settings and/or profiles layers from [bakPath]
  /// (this device's pre-import snapshot) into the freshly-overwritten DB, so a
  /// backup that UNTICKED the `settings` / `profiles` category never wipes this
  /// device's settings/profiles to empty (TODO-1193). The exact mirror of the
  /// export strip:
  ///  - [reapplySettings]: the pure-settings preference rows
  ///    ([settingsPrefPredicate]) — progress / favorites / content-registry /
  ///    sync prefs stay from the backup (they are content or handled elsewhere).
  ///  - [reapplyProfiles]: the four profile-layer tables (child-first DELETE
  ///    then parent-first INSERT for FK-safety).
  /// Runs while both DBs are at the current schema (bak is a copy of the live
  /// DB), so `SELECT *` columns align. No-op (logged) if bak is gone.
  static Future<void> _reapplyExcludedSettingsLayers(
    String dbDirectory,
    String bakPath, {
    required bool reapplySettings,
    required bool reapplyProfiles,
  }) async {
    if (!reapplySettings && !reapplyProfiles) return;
    if (!File(bakPath).existsSync()) {
      // bak is the only copy of this device's settings/profiles after the
      // overwrite. Missing it means a crash + external deletion before this ran;
      // surface loudly rather than silently wiping the layer to empty.
      debugPrint('BackupRestoreService._reapplyExcludedSettingsLayers: '
          'pre-restore.bak missing — local settings/profiles could not be '
          'preserved for a settings/profiles-excluded backup.');
      return;
    }
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS setbak");
      await db.transaction(() async {
        if (reapplySettings) {
          await db.customStatement(
              'DELETE FROM preferences WHERE $settingsPrefPredicate');
          await db.customStatement(
              'INSERT INTO preferences SELECT * FROM setbak.preferences '
              'WHERE $settingsPrefPredicate');
        }
        if (reapplyProfiles) {
          // Child-first DELETE so an enforced FK to `profiles` never blocks the
          // wipe; parent-first INSERT ([_settingsLayerTables]) so children land
          // after their profile row.
          for (final String t in _profilesLayerTablesChildFirst) {
            await db.customStatement('DELETE FROM $t');
          }
          for (final String t in _settingsLayerTables) {
            await db.customStatement('INSERT INTO $t SELECT * FROM setbak.$t');
          }
        }
      });
      await db.customStatement('DETACH DATABASE setbak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Tables holding this device's imported dictionaries. Re-seated from
  /// pre-restore.bak when a backup that carries NO dictionaries is imported in
  /// overwrite mode (BUG-454), so an unselected-dictionary backup never wipes
  /// the device's dictionary library. `dictionary_metadata` is the queryable
  /// dictionary set; `dictionary_history` is its recent-lookup list. Neither is
  /// FK-targeted by content tables, so a wholesale per-table swap is FK-safe.
  static const List<String> _dictionaryLayerTables = <String>[
    'dictionary_metadata',
    'dictionary_history',
  ];

  /// Restores [_dictionaryLayerTables] from [bakPath] (this device's pre-import
  /// snapshot) into the freshly-overwritten DB in [dbDirectory]. Runs inline
  /// during import while both DBs are at the current schema (bak is a copy of
  /// the live DB), so `SELECT *` columns align. No-op (logged) if bak is gone.
  static Future<void> _reapplyDictionaryTablesFromBak(
    String dbDirectory,
    String bakPath,
  ) async {
    if (!File(bakPath).existsSync()) {
      // bak is the only copy of this device's dictionary rows after the
      // overwrite. Missing it means a crash + external deletion before this
      // ran; surface loudly rather than silently dropping the dictionaries.
      debugPrint('BackupRestoreService._reapplyDictionaryTablesFromBak: '
          'pre-restore.bak missing — local dictionaries could not be '
          'preserved on import.');
      return;
    }
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS dictbak");
      await db.transaction(() async {
        for (final String t in _dictionaryLayerTables) {
          await db.customStatement('DELETE FROM $t');
          await db.customStatement('INSERT INTO $t SELECT * FROM dictbak.$t');
        }
      });
      await db.customStatement('DETACH DATABASE dictbak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Reads this device's device-local / credential prefs from the DB in
  /// [dbDirectory] so an import can write them back afterwards.
  ///
  /// Filters by [PrefRedactionPolicy] rather than enumerating
  /// [SyncRepository.deviceLocalPrefKeys]: the policy also matches by prefix and
  /// shape (`media_source_secret_<id>` is one key PER SOURCE ROW and could never
  /// be listed), and — decisively — it is the SAME predicate the export strip
  /// uses. Enumerating a fixed list here while the strip matched by shape is
  /// exactly how the two sides would drift: every key the strip removed but the
  /// list did not name would be deleted from the imported DB and never restored,
  /// silently wiping this device's own SFTP passwords / API keys on import.
  static Future<Map<String, String>> _readDeviceLocalPrefs(
      String dbDirectory) async {
    FushiDatabase? db;
    try {
      db = FushiDatabase(dbDirectory);
      final all = await db.getAllPrefs();
      final out = <String, String>{};
      for (final MapEntry<String, String> entry in all.entries) {
        if (PrefRedactionPolicy.isDeviceLocalOrCredential(entry.key)) {
          out[entry.key] = entry.value;
        }
      }
      return out;
    } catch (e, st) {
      // Current DB unreadable/corrupt: nothing to preserve. Import the backup
      // as-is rather than aborting — a broken local DB shouldn't block restore.
      debugPrint('BackupRestoreService._readDeviceLocalPrefs failed: $e\n$st');
      return const <String, String>{};
    } finally {
      try {
        await db?.close();
      } catch (_) {/* db may have failed to open */}
    }
  }

  /// Writes the preserved device-local [prefs] into the imported DB, clears the
  /// stale (backup-origin) folder cache so the next sync rebuilds it against the
  /// preserved backend account, then durably flushes.
  static Future<void> _applyPreservedConfig(
      String dbDirectory, Map<String, String> prefs) async {
    final db = FushiDatabase(dbDirectory);
    try {
      for (final entry in prefs.entries) {
        await db.setPref(entry.key, entry.value);
      }
      // The imported DB carries the BACKUP's folder cache (title → source
      // account folder ids), which is wrong for the preserved local backend.
      // BUG-1576：清**所有**通道那几格（含解耦前的旧全局键）。导入库里带的是备份
      // 来源机的目录布局，对本机保留下来的后端账号一条都不成立。
      await SyncRepository(db).clearAllFolderCaches();
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  static List<ArchiveFile> _dictionaryResourceFiles(Archive archive) {
    return archive.files.where((ArchiveFile file) {
      if (!file.isFile) return false;
      return file.name
          .replaceAll(r'\', '/')
          .startsWith('$_dictionaryResourcesPrefix/');
    }).toList();
  }

  static List<MapEntry<ArchiveFile, String>> _buildDictionaryReapplyPlan({
    required Archive archive,
    required String dictionaryResourceDirectory,
  }) {
    final Directory targetRoot = Directory(dictionaryResourceDirectory);
    final String canonicalRoot = p.canonicalize(targetRoot.path);
    final List<MapEntry<ArchiveFile, String>> reapplyPlan =
        <MapEntry<ArchiveFile, String>>[];
    for (final ArchiveFile file in _dictionaryResourceFiles(archive)) {
      final String rawName = file.name.replaceAll(r'\', '/');
      final String relativePath =
          rawName.substring(_dictionaryResourcesPrefix.length + 1);
      final String normalizedRelative = p.posix.normalize(relativePath);
      if (relativePath.isEmpty ||
          p.posix.isAbsolute(relativePath) ||
          normalizedRelative == '..' ||
          normalizedRelative.startsWith('../')) {
        throw FormatException('Invalid dictionary resource path: ${file.name}');
      }

      final String targetPath = p.normalize(
        p.join(targetRoot.path, normalizedRelative),
      );
      final String canonicalTarget = p.canonicalize(targetPath);
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        throw FormatException('Invalid dictionary resource path: ${file.name}');
      }
      reapplyPlan.add(MapEntry<ArchiveFile, String>(file, targetPath));
    }
    return reapplyPlan;
  }

  static Future<void> _reapplyDictionaryResources({
    required String zipPath,
    required List<MapEntry<ArchiveFile, String>> reapplyPlan,
    required String dictionaryResourceDirectory,
    void Function(int deltaBytes)? onBytes,
  }) async {
    final Directory targetRoot = Directory(dictionaryResourceDirectory);
    // 引擎常驻映射着每本词典的 hash.table / blobs.bin（native map_rd）；Windows 上
    // 只要 view 还活着，删资源根一律 ERROR_USER_MAPPED_FILE，整个恢复流程就断在
    // 这一行（BUG-1756）。恢复流程收尾必定重启 app（backupImportRestart），故这里
    // 把引擎清空不需要再装回来。
    FushiDicts.releaseAllMappings();
    if (await targetRoot.exists()) {
      await targetRoot.delete(recursive: true);
    }
    await targetRoot.create(recursive: true);
    await _extractEntriesStreaming(
      zipPath: zipPath,
      entries: reapplyPlan
          .map((MapEntry<ArchiveFile, String> e) =>
              MapEntry<String, String>(e.key.name, e.value))
          .toList(),
      onBytes: onBytes,
    );
  }

  /// Extracts the packed local-audio databases (`localAudio/<file>`) into the
  /// support directory [dbDirectory]. Unlike the content TREES these are
  /// individual files SHARING the directory with `hibiki.db`, so they are
  /// written file-by-file rather than via the destructive tree swap. Only file
  /// names matching [_localAudioFileName] are accepted (defense in depth: an
  /// archive entry naming `hibiki.db` under `localAudio/` is rejected).
  ///
  /// When the backup carries no `localAudio/` entries this is a no-op, so an
  /// audio-less backup leaves this device's local-audio DBs intact (the same
  /// preserve-on-absent contract the content trees follow — BUG-454 family).
  ///
  /// [overwrite] true (overwrite import) replaces an existing same-named file;
  /// false (merge import) keeps the device's own file (copy-if-absent).
  static Future<void> _reapplyLocalAudioFiles(
    String zipPath,
    Archive archive,
    String dbDirectory, {
    bool overwrite = true,
    void Function(int deltaBytes)? onBytes,
  }) async {
    final Directory targetRoot = Directory(dbDirectory);
    final List<MapEntry<String, String>> plan = <MapEntry<String, String>>[];
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String rawName = file.name.replaceAll(r'\', '/');
      if (!rawName.startsWith('$_localAudioPrefix/')) continue;
      final String name = rawName.substring(_localAudioPrefix.length + 1);
      // Reject nested paths / traversal / non-local-audio names: these files
      // must land flat in the support dir and never escape it or clobber
      // hibiki.db.
      if (name.isEmpty ||
          name.contains('/') ||
          !_localAudioFileName.hasMatch(name)) {
        throw FormatException('Invalid local audio backup path: ${file.name}');
      }
      final File dest = File(p.join(targetRoot.path, name));
      if (!overwrite && await dest.exists()) continue; // copy-if-absent (merge)
      plan.add(MapEntry<String, String>(file.name, dest.path));
    }
    await _extractEntriesStreaming(
      zipPath: zipPath,
      entries: plan,
      onBytes: onBytes,
    );
  }

  /// Files in [archive] under `<prefix>/`, validated against path traversal and
  /// mapped to absolute targets under [targetRootPath]. Mirrors the dictionary
  /// plan's safety checks (reject absolute / `..` escapes, `p.isWithin` gate).
  static List<MapEntry<ArchiveFile, String>> _buildTreeReapplyPlan({
    required Archive archive,
    required String prefix,
    required String targetRootPath,
  }) {
    final Directory targetRoot = Directory(targetRootPath);
    final String canonicalRoot = p.canonicalize(targetRoot.path);
    final List<MapEntry<ArchiveFile, String>> plan =
        <MapEntry<ArchiveFile, String>>[];
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String rawName = file.name.replaceAll(r'\', '/');
      if (!rawName.startsWith('$prefix/')) continue;
      final String relativePath = rawName.substring(prefix.length + 1);
      final String normalizedRelative = p.posix.normalize(relativePath);
      if (relativePath.isEmpty ||
          p.posix.isAbsolute(relativePath) ||
          normalizedRelative == '..' ||
          normalizedRelative.startsWith('../')) {
        throw FormatException('Invalid backup content path: ${file.name}');
      }
      final String targetPath =
          p.normalize(p.join(targetRoot.path, normalizedRelative));
      final String canonicalTarget = p.canonicalize(targetPath);
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        throw FormatException('Invalid backup content path: ${file.name}');
      }
      plan.add(MapEntry<ArchiveFile, String>(file, targetPath));
    }
    return plan;
  }

  static String _importTmpPath(String root) => '$root.import-tmp';
  static String _importOldPath(String root) => '$root.import-old';

  /// Removes any stale `.import-tmp` / `.import-old` siblings left by a prior
  /// import that crashed mid-swap. Called on entry to every prepare so a stale
  /// `.import-old` can never be mistaken for a valid rollback target by a later
  /// import (review W1).
  static Future<void> _clearImportLeftovers(String targetRootPath) async {
    for (final String path in <String>[
      _importTmpPath(targetRootPath),
      _importOldPath(targetRootPath),
    ]) {
      final Directory d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    }
  }

  /// PHASE 1 of the content-tree restore: write every file under `<prefix>/`
  /// into the sibling `<root>.import-tmp` (NO swap yet). Returns true when there
  /// is something staged to commit; false when the backup carries no files under
  /// [prefix] (db-only / audio-less backup) so the existing tree is left alone.
  ///
  /// Splitting write (slow, GB-scale, failure-prone) from the swap (fast rename)
  /// lets the caller stage ALL trees before committing ANY — a write failure
  /// then swaps nothing and leaves every existing tree intact (review W2).
  /// 该归档实际使用的书树前缀：任一条目落在新前缀（[_booksPrefix]）下即用新，
  /// 否则回退旧前缀 [_legacyBooksPrefix]（旧 Hibiki app 导出的备份/迁移归档）。
  /// 一份归档只会有一代前缀，不存在混排。`@visibleForTesting`：读侧回退是
  /// 跨版本契约，测试直接对两代归档断言。
  @visibleForTesting
  static String archiveBooksPrefix(Archive archive) {
    for (final ArchiveFile file in archive) {
      if (file.name.startsWith('$_booksPrefix/')) return _booksPrefix;
    }
    return _legacyBooksPrefix;
  }

  static Future<bool> _prepareTreeReapply(
    String zipPath,
    Archive archive,
    String prefix,
    String targetRootPath, {
    void Function(int deltaBytes)? onBytes,
  }) async {
    final String tmpRoot = _importTmpPath(targetRootPath);
    final List<MapEntry<ArchiveFile, String>> plan = _buildTreeReapplyPlan(
      archive: archive,
      prefix: prefix,
      targetRootPath: tmpRoot,
    );
    await _clearImportLeftovers(targetRootPath);
    if (plan.isEmpty) return false;

    final Directory tmpDir = Directory(tmpRoot);
    await tmpDir.create(recursive: true);
    try {
      await _extractEntriesStreaming(
        zipPath: zipPath,
        entries: plan
            .map((MapEntry<ArchiveFile, String> e) =>
                MapEntry<String, String>(e.key.name, e.value))
            .toList(),
        onBytes: onBytes,
      );
    } catch (_) {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      rethrow; // nothing swapped; existing tree untouched
    }
    return true;
  }

  /// PHASE 2: swap the staged `<root>.import-tmp` into place. tmp and target are
  /// siblings → rename is atomic on the same filesystem. Caller invokes this for
  /// each prepared tree back-to-back; only the (rare) rename failure between two
  /// trees leaves a cross-tree half-state, which is far smaller than the old
  /// write-between-swaps window.
  static Future<void> _commitPreparedTree(String targetRootPath) async {
    final String asideRoot = _importOldPath(targetRootPath);
    final Directory aside = Directory(asideRoot);
    final Directory target = Directory(targetRootPath);
    final Directory tmpDir = Directory(_importTmpPath(targetRootPath));
    // Every swap rename retries transient Windows FS-busy (errno 5/32/145): an
    // antivirus/indexer scanning the freshly-written tree briefly locks it, so
    // a bare rename fails with "拒绝访问" even though nothing is really wrong.
    Future<void> renameDir(Directory dir, String to) =>
        renameDirectoryWithRetry(
          rename: () => dir.rename(to),
          sleep: (int ms) => Future<void>.delayed(Duration(milliseconds: ms)),
          isWindows: Platform.isWindows,
        );
    if (await aside.exists()) await aside.delete(recursive: true);
    if (await target.exists()) await renameDir(target, asideRoot);
    try {
      await renameDir(tmpDir, targetRootPath);
    } catch (_) {
      // Roll back: put the old tree back if the new one didn't land.
      if (await aside.exists() && !await target.exists()) {
        await renameDir(aside, targetRootPath);
      }
      rethrow;
    }
    if (await aside.exists()) await aside.delete(recursive: true);
  }

  /// Drops a staged-but-not-committed `<root>.import-tmp` (idempotent).
  static Future<void> _abortPreparedTree(String targetRootPath) async {
    final Directory tmpDir = Directory(_importTmpPath(targetRootPath));
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  }

  static Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // Best-effort cleanup; a leftover sidecar/bak is harmless and swept later.
    }
  }

  /// Total uncompressed byte size of every content entry in [archive] (the DB +
  /// packed trees + local-audio DBs), excluding the tiny meta json. Used as the
  /// denominator for the import progress bar. Read from the central directory,
  /// so it never decompresses anything. Never returns 0 (avoids /0).
  static int _totalContentBytes(Archive archive) {
    int total = 0;
    for (final ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      if (f.name == _metaName) continue;
      total += f.size;
    }
    return total > 0 ? total : 1;
  }

  /// TODO-1183: determinate progress across every streamed byte. Total is the
  /// sum of all content entry sizes ([_totalContentBytes]); each streamed
  /// chunk advances the bar, clamped at 1.0. Returns the `onBytes` callback
  /// shared by the overwrite- and merge-import extraction helpers.
  static void Function(int deltaBytes) _archiveByteProgress(
    Archive archive,
    void Function(double progress)? onProgress,
  ) {
    final int totalBytes = _totalContentBytes(archive);
    int writtenBytes = 0;
    return (int deltaBytes) {
      writtenBytes += deltaBytes;
      final double fraction = writtenBytes / totalBytes;
      onProgress?.call(fraction > 1.0 ? 1.0 : fraction);
    };
  }

  /// Parses the source-device manifest (`backup_meta.json`) carried by
  /// [archive]. Null for a legacy backup without one (or an unparseable one).
  /// Only the tiny meta entry is materialized.
  static BackupMeta? _readBackupMeta(Archive archive) {
    final ArchiveFile? metaFile = archive.findFile(_metaName);
    if (metaFile == null) return null;
    return BackupMeta.tryParse(utf8.decode(metaFile.content as List<int>));
  }

  // ── TODO-1183: streaming, off-UI-isolate backup extraction ───────────────
  //
  // The import/merge paths used to `dest.writeAsBytes(archiveFile.content)`,
  // which decodes a whole archive entry into ONE Uint8List. A full-data backup's
  // local-audio DB alone can be many GB, so that single allocation OOM-killed the
  // app mid-import (TODO-1183); even when it fit, the synchronous write froze the
  // UI isolate for the whole copy (progress bar stuck → looked like a hang).
  //
  // Extraction now runs on a BACKGROUND isolate and STREAMS each entry to disk in
  // bounded chunks (never materializing a whole entry), reporting bytes written
  // through a port so the overlay shows real progress. Only pure file IO +
  // archive decoding runs in the isolate (no sqlite / platform channels), so it
  // is isolate-safe — the DB work stays on the caller's isolate. archive 3.6.1's
  // `ArchiveFile.writeContent` is NOT usable here: for a `decodeBuffer`-produced
  // file it still fully materializes (`_content is FileContent` → `.content` →
  // `toUint8List()`), so we stream the raw file-backed window directly instead.

  /// Sent by the extract worker once every planned entry has been written.
  static const String _extractDoneToken = '__fushi_backup_extract_done__';

  /// Streams the entries in [entries] (archive entry name → absolute dest path)
  /// out of the zip at [zipPath] on a background isolate. [onBytes] is invoked on
  /// THIS isolate with each chunk's byte count as it lands, so callers accumulate
  /// determinate progress. Throws (on this isolate) if the worker reports an
  /// error, preserving the caller's existing try/catch crash-safety.
  static Future<void> _extractEntriesStreaming({
    required String zipPath,
    required List<MapEntry<String, String>> entries,
    void Function(int deltaBytes)? onBytes,
  }) async {
    if (entries.isEmpty) return;
    final ReceivePort port = ReceivePort();
    final Completer<void> completer = Completer<void>();
    Isolate? isolate;
    port.listen((dynamic message) {
      if (message is int) {
        onBytes?.call(message);
      } else if (message == _extractDoneToken) {
        if (!completer.isCompleted) completer.complete();
        port.close();
      } else {
        // Worker failure ('errorText') or an uncaught isolate error
        // ([error, stack]): fail the future so the caller's rollback runs.
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Backup extraction failed: $message'),
          );
        }
        port.close();
      }
    });
    isolate = await Isolate.spawn(
      _backupExtractWorker,
      _BackupExtractRequest(zipPath, entries, port.sendPort),
      onError: port.sendPort,
    );
    try {
      await completer.future;
    } finally {
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Background-isolate entry point for [_extractEntriesStreaming]. Re-opens the
  /// zip by path (the decoded [Archive] from the caller's isolate cannot cross
  /// the boundary), then streams each requested entry to disk, reporting progress
  /// and terminal status through the [SendPort].
  static void _backupExtractWorker(_BackupExtractRequest request) {
    final SendPort port = request.sendPort;
    InputFileStream? input;
    try {
      input = InputFileStream(request.zipPath);
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final Map<String, ArchiveFile> byName = <String, ArchiveFile>{
        for (final ArchiveFile file in archive.files) file.name: file,
      };
      for (final MapEntry<String, String> entry in request.entries) {
        final ArchiveFile? file = byName[entry.key];
        if (file == null) {
          throw StateError('Backup archive missing entry: ${entry.key}');
        }
        _streamArchiveFileToDisk(file, entry.value, port);
      }
      port.send(_extractDoneToken);
    } catch (error, stack) {
      port.send('$error\n$stack');
    } finally {
      input?.closeSync();
    }
  }

  /// Streams one [file]'s uncompressed bytes to [destPath] without buffering the
  /// whole entry. Hibiki backups are written STORE (see
  /// [_writeBackupZipInIsolate]) so the raw window IS the uncompressed data and is
  /// copied in bounded 4 MB chunks (each chunk's size reported via [port]); a
  /// DEFLATE entry (small metadata / test fixtures — never a multi-GB file in
  /// practice) is inflated streaming.
  static void _streamArchiveFileToDisk(
    ArchiveFile file,
    String destPath,
    SendPort port,
  ) {
    File(destPath).parent.createSync(recursive: true);
    final OutputFileStream output = OutputFileStream(destPath);
    try {
      final InputStreamBase? raw = file.rawContent;
      if (raw != null && !file.isCompressed) {
        const int chunkSize = 4 * 1024 * 1024; // 4 MB peak heap per chunk
        final int total = raw.length;
        int written = 0;
        while (written < total) {
          final int want =
              (total - written) < chunkSize ? (total - written) : chunkSize;
          final Uint8List bytes = raw.readBytes(want).toUint8List();
          if (bytes.isEmpty) break;
          output.writeBytes(bytes);
          written += bytes.length;
          port.send(bytes.length);
        }
      } else if (raw != null && file.compressionType == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, output);
        port.send(file.size);
      } else {
        // Last resort (already-materialized content): write buffered bytes.
        output.writeBytes(file.content as List<int>);
        port.send(file.size);
      }
    } finally {
      output.closeSync();
    }
  }
}

/// Sendable request for the background extract worker (records with a `List` and
/// a `SendPort` cross the isolate boundary fine). Kept a top-level class rather
/// than an anonymous record for a clearer worker signature.
class _BackupExtractRequest {
  const _BackupExtractRequest(this.zipPath, this.entries, this.sendPort);
  final String zipPath;
  final List<MapEntry<String, String>> entries;
  final SendPort sendPort;
}
