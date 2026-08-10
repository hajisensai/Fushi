// 基础设施：表/列存在性探测与幂等索引（God 类拆分 2026-08）。
part of 'database.dart';

mixin _FushiDbInfra on _$FushiDatabase {
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

  /// 当前连接上 `PRAGMA foreign_keys` 的取值。迁移里要临时关外键时用它记住进入
  /// 时的状态，收尾按原值恢复 —— 无条件置 ON 会把调用方显式关掉的外键悄悄打开。
  Future<bool> _foreignKeysEnabled() async {
    final QueryRow row = await customSelect('PRAGMA foreign_keys').getSingle();
    return row.read<int>('foreign_keys') == 1;
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

  /// Creates all secondary indexes idempotently. Called from onCreate (fresh
  /// install) and schema steps that add indexed tables — NOT on every open. Each
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
            'ON audio_cues (book_key, chapter_href, sentence_index)'
      ],
      // tag_id lookups（v77 合表后一条索引服务全部 kind）：countBooksForTag /
      // _entryKeysForAllTags 按 tag_id 过滤，PK (media_kind, entry_key, tag_id)
      // 服务不了 tag_id 单列查询。
      [
        'tag_assignments',
        'CREATE INDEX IF NOT EXISTS idx_tag_assignments_tag_id '
            'ON tag_assignments (tag_id)'
      ],
      // favorite_words is filtered by source_type ('book' | 'video') in
      // getFavoritesBySource; the table had no index on it.
      [
        'favorite_words',
        'CREATE INDEX IF NOT EXISTS idx_favorite_words_source_type '
            'ON favorite_words (source_type)'
      ],
      // v49：首页 Activity 面板按 timestamp_ms DESC 取最近 N 条（可按 event_type
      // 过滤），主排序列建索引避免全表扫描 + 排序。
      [
        'activity_events',
        'CREATE INDEX IF NOT EXISTS idx_activity_events_timestamp '
            'ON activity_events (timestamp_ms DESC)'
      ],
      // v69：provider 外部 id 反查、来源任务历史与 sidecar 批次查询是刮削热路径。
      [
        'video_metadata_provider_identities',
        'CREATE INDEX IF NOT EXISTS idx_video_metadata_identity_external '
            'ON video_metadata_provider_identities (provider, external_id)'
      ],
      [
        'video_source_scrape_runs',
        'CREATE INDEX IF NOT EXISTS idx_video_scrape_runs_source_started '
            'ON video_source_scrape_runs (source_id, started_at DESC)'
      ],
      [
        'video_sidecar_artifacts',
        'CREATE INDEX IF NOT EXISTS idx_video_sidecar_artifacts_source_run '
            'ON video_sidecar_artifacts (source_id, run_id)'
      ],
      // v78：worker claim、任务列表与订阅轮询的热路径。
      [
        'video_download_jobs',
        'CREATE INDEX IF NOT EXISTS idx_video_download_jobs_claim '
            'ON video_download_jobs '
            '(lifecycle, next_attempt_at, priority DESC, created_at)'
      ],
      [
        'video_download_jobs',
        'CREATE UNIQUE INDEX IF NOT EXISTS '
            'idx_video_download_jobs_fingerprint_torrent '
            'ON video_download_jobs (fingerprint, torrent_hash) '
            'WHERE torrent_hash IS NOT NULL'
      ],
      [
        'video_download_jobs',
        'CREATE INDEX IF NOT EXISTS idx_video_download_jobs_backend_task '
            'ON video_download_jobs (backend_kind, backend_task_id)'
      ],
      [
        'video_download_job_files',
        'CREATE INDEX IF NOT EXISTS idx_video_download_job_files_job_status '
            'ON video_download_job_files (job_id, status)'
      ],
      [
        'video_download_job_subtitles',
        'CREATE INDEX IF NOT EXISTS idx_video_download_job_subtitles_job_status '
            'ON video_download_job_subtitles (job_id, status)'
      ],
      [
        'video_download_subscriptions',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscriptions_claim '
            'ON video_download_subscriptions '
            '(enabled, next_check_at, claim_expires_at)'
      ],
      [
        'video_download_subscription_items',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscription_items_state '
            'ON video_download_subscription_items '
            '(subscription_id, status, season, episode)'
      ],
      [
        'video_download_subscription_items',
        'CREATE INDEX IF NOT EXISTS idx_video_download_subscription_items_job '
            'ON video_download_subscription_items (job_id)'
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
      // v55 游戏库：会话表按游戏取流水（详情页时间线）与全局按时间取最近游玩
      // （首页「最近玩过」）是两条热路径，各建一条索引。
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_game_start '
            'ON galgame_sessions (game_id, start_ms DESC)',
        'game_id'
      ],
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_start '
            'ON galgame_sessions (start_ms DESC)',
        'start_ms'
      ],
      // 按天聚合（统计页每日柱状图）走 dateKey。
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_date '
            'ON galgame_sessions (date_key)',
        'date_key'
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
}
