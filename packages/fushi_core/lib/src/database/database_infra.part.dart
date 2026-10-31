// 基础设施：表/列存在性探测与幂等索引（God 类拆分 2026-08）。
part of 'database.dart';

mixin _FushiDbInfra on _$FushiDatabase {
  static final RegExp _identifierRe = RegExp(r'^[a-zA-Z_]\w*$');

  Future<bool> _columnExists(String tableName, String columnName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'not a valid identifier',
      );
    }
    if (!_identifierRe.hasMatch(columnName)) {
      throw ArgumentError.value(
        columnName,
        'columnName',
        'not a valid identifier',
      );
    }
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    return rows.any((row) => row.read<String>('name') == columnName);
  }

  /// 当前连接上 `PRAGMA foreign_keys` 的取值。迁移里要临时关外键时用它记住进入
  /// 时的状态，收尾按原值恢复 —— 无条件置 ON 会把调用方显式关掉的外键悄悄打开。
  Future<bool> _foreignKeysEnabled() async {
    final QueryRow row = await customSelect('PRAGMA foreign_keys').getSingle();
    return row.read<int>('foreign_keys') == 1;
  }

  /// 表上是否还挂着任何外键约束（`PRAGMA foreign_key_list` 非空）。迁移里去掉
  /// 内联 FK 要重建表，用它做幂等守卫。
  Future<bool> _hasForeignKeys(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'not a valid identifier',
      );
    }
    final List<QueryRow> rows = await customSelect(
      'PRAGMA foreign_key_list($tableName)',
    ).get();
    return rows.isNotEmpty;
  }

  /// 表上是否还有一条**只**覆盖 [columnName] 的唯一索引（列级 `.unique()` 生成
  /// 的 `sqlite_autoindex_*` 也算）。迁移里去掉列级 UNIQUE 要重建表，用它做幂等
  /// 守卫：fresh 建出的新 shape 没有这条索引就短路。
  Future<bool> _hasUniqueIndexOnColumn(
    String tableName,
    String columnName,
  ) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'not a valid identifier',
      );
    }
    if (!_identifierRe.hasMatch(columnName)) {
      throw ArgumentError.value(
        columnName,
        'columnName',
        'not a valid identifier',
      );
    }
    final List<QueryRow> indexes = await customSelect(
      'PRAGMA index_list($tableName)',
    ).get();
    for (final QueryRow index in indexes) {
      if (index.read<int>('unique') != 1) continue;
      final String name = index.read<String>('name');
      if (!_identifierRe.hasMatch(name)) continue;
      final List<QueryRow> columns = await customSelect(
        'PRAGMA index_info($name)',
      ).get();
      if (columns.length == 1 &&
          columns.single.read<String>('name') == columnName) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _tableExists(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'not a valid identifier',
      );
    }
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    return rows.isNotEmpty;
  }

  /// v118 迁移：把 [tableName] 里尚未记录的 `local_added_at` 回填成
  /// `imported_at`（理由见迁移步注释）。只碰 NULL 行，重跑幂等。没有
  /// `imported_at` 列的表（阶梯上的合成 / 残缺库，与其它加列步的 `_columnExists`
  /// 守卫同形）无从回填，保持 NULL = 时刻未知。
  Future<void> _backfillLocalAddedAt(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'not a valid identifier',
      );
    }
    if (!await _columnExists(tableName, 'imported_at')) return;
    await customStatement(
      'UPDATE $tableName SET local_added_at = imported_at '
      'WHERE local_added_at IS NULL',
    );
  }

  /// Creates all secondary indexes idempotently. Called from onCreate (fresh
  /// install) and schema steps that add indexed tables — NOT on every open. Each
  /// index is guarded by a table-existence check because a partially-migrated
  /// legacy DB may lack some v1 baseline tables (those are created only in
  /// onCreate, never in the onUpgrade ladder).
  Future<void> _ensureIndexes() async {
    const List<List<String>> indexes = <List<String>>[
      [
        'profile_settings',
        'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
      ],
      [
        'media_type_profiles',
        'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
      ],
      [
        'book_profiles',
        'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
      ],
      [
        'language_profiles',
        'CREATE INDEX IF NOT EXISTS idx_language_profiles_profile ON language_profiles (profile_id)',
      ],
      // bookmarks 索引 v82 起换 book_uid 列，移出本清单（清单会被早期迁移步
      // 调用，彼时新列不存在）：v82 步与 onCreate 成对内联维护。
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_type '
            'ON media_items (media_type_identifier)',
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_source '
            'ON media_items (media_source_identifier)',
      ],
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_key '
            'ON audio_cues (book_key)',
      ],
      [
        'search_history_items',
        'CREATE INDEX IF NOT EXISTS idx_search_history_key '
            'ON search_history_items (history_key)',
      ],
      [
        'audiobooks',
        'CREATE INDEX IF NOT EXISTS idx_audiobooks_book_key '
            'ON audiobooks (book_key)',
      ],
      [
        'srt_books',
        'CREATE INDEX IF NOT EXISTS idx_srt_books_book_key '
            'ON srt_books (book_key)',
      ],
      // BUG-906 (B): hot-path indexes that were missing.
      // audio_cues is read on every audiobook chapter load via
      // getCuesForChapter (WHERE book_key AND chapter_href ORDER BY
      // sentence_index) and findCue (WHERE book_key AND chapter_href AND
      // sentence_index). The lone single-column idx_audio_cues_book_key can't
      // serve the chapter_href filter or the sentence_index sort. A composite
      // (book_key, chapter_href, sentence_index) covers filter + sort for both,
      // and its leading book_key column still serves the book-only queries.
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_chapter_sentence '
            'ON audio_cues (book_key, chapter_href, sentence_index)',
      ],
      // tag_id lookups（v77 合表后一条索引服务全部 kind）：countBooksForTag /
      // _entryKeysForAllTags 按 tag_id 过滤，PK (media_kind, entry_key, tag_id)
      // 服务不了 tag_id 单列查询。
      [
        'tag_assignments',
        'CREATE INDEX IF NOT EXISTS idx_tag_assignments_tag_id '
            'ON tag_assignments (tag_id)',
      ],
      // favorite_words is filtered by source_type ('book' | 'video') in
      // getFavoritesBySource; the table had no index on it.
      [
        'favorite_words',
        'CREATE INDEX IF NOT EXISTS idx_favorite_words_source_type '
            'ON favorite_words (source_type)',
      ],
      // v49：首页 Activity 面板按 timestamp_ms DESC 取最近 N 条（可按 event_type
      // 过滤），主排序列建索引避免全表扫描 + 排序。
      [
        'activity_events',
        'CREATE INDEX IF NOT EXISTS idx_activity_events_timestamp '
            'ON activity_events (timestamp_ms DESC)',
      ],
      // v69：provider 外部 id 反查、来源任务历史与 sidecar 批次查询是刮削热路径。
      [
        'video_metadata_provider_identities',
        'CREATE INDEX IF NOT EXISTS idx_video_metadata_identity_external '
            'ON video_metadata_provider_identities (provider, external_id)',
      ],
      [
        'video_source_scrape_runs',
        'CREATE INDEX IF NOT EXISTS idx_video_scrape_runs_source_started '
            'ON video_source_scrape_runs (source_id, started_at DESC)',
      ],
      // v110：分集行按绑定文件反查（一文件多集后不再是唯一索引）。
      [
        'video_metadata_episodes',
        'CREATE INDEX IF NOT EXISTS idx_video_metadata_episodes_book '
            'ON video_metadata_episodes (book_uid)',
      ],
      // v106：文件级 AniDB 身份按「路径 + 大小」免哈希命中、按作品反查。
      [
        'anidb_file_identities',
        'CREATE INDEX IF NOT EXISTS idx_anidb_file_identities_path '
            'ON anidb_file_identities (file_path, file_size)',
      ],
      [
        'anidb_file_identities',
        'CREATE INDEX IF NOT EXISTS idx_anidb_file_identities_anime '
            'ON anidb_file_identities (anidb_anime_id)',
      ],
      [
        'video_sidecar_artifacts',
        'CREATE INDEX IF NOT EXISTS idx_video_sidecar_artifacts_source_run '
            'ON video_sidecar_artifacts (source_id, run_id)',
      ],
      // v78：worker claim、任务列表与订阅轮询的热路径。
      [
        'video_download_jobs',
        'CREATE INDEX IF NOT EXISTS idx_video_download_jobs_claim '
            'ON video_download_jobs '
            '(lifecycle, next_attempt_at, priority DESC, created_at)',
      ],
      [
        'video_download_jobs',
        'CREATE UNIQUE INDEX IF NOT EXISTS '
            'idx_video_download_jobs_fingerprint_torrent '
            'ON video_download_jobs (fingerprint, torrent_hash) '
            'WHERE torrent_hash IS NOT NULL',
      ],
      [
        'video_download_jobs',
        'CREATE INDEX IF NOT EXISTS idx_video_download_jobs_backend_task '
            'ON video_download_jobs (backend_kind, backend_task_id)',
      ],
      [
        'video_download_job_files',
        'CREATE INDEX IF NOT EXISTS idx_video_download_job_files_job_status '
            'ON video_download_job_files (job_id, status)',
      ],
      [
        'video_download_job_subtitles',
        'CREATE INDEX IF NOT EXISTS idx_video_download_job_subtitles_job_status '
            'ON video_download_job_subtitles (job_id, status)',
      ],
      [
        'video_download_subscriptions',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscriptions_claim '
            'ON video_download_subscriptions '
            '(enabled, next_check_at, claim_expires_at)',
      ],
      [
        'video_download_subscription_items',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscription_items_state '
            'ON video_download_subscription_items '
            '(subscription_id, status, season, episode)',
      ],
      [
        'video_download_subscription_items',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscription_items_job '
            'ON video_download_subscription_items (job_id)',
      ],
      // v103：漫画下载队列——同章幂等 + worker 按 (status, created_at) 取最早。
      // 与 database.dart 的 v103 升级步逐字一致。
      [
        'manga_download_jobs',
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_manga_download_jobs_identity '
            'ON manga_download_jobs (kind, book_key, chapter_key)',
      ],
      [
        'manga_download_jobs',
        'CREATE INDEX IF NOT EXISTS idx_manga_download_jobs_status_created '
            'ON manga_download_jobs (status, created_at)',
      ],
    ];
    for (final List<String> entry in indexes) {
      if (await _tableExists(entry[0])) {
        await customStatement(entry[1]);
      }
    }
  }
}
