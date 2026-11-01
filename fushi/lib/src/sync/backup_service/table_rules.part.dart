part of '../backup_service.dart';

/// 一张表在备份导出里的去向。
enum BackupTableFate {
  /// 归属的类别**全部**未勾选时，导出副本整表清空（[_stripTablesOfExcludedCategories]）。
  followsCategories,

  /// 按行裁剪：由 [BackupTableRule.handler] 指名的专门逻辑决定哪些行随包，
  /// 其余照常出境（共享表、带每条内容选择的主表、偏好等）。
  rowLevel,

  /// 永不出境：导出时清空，覆盖导入时从本机 `pre-restore.bak` 回灌。
  deviceLocal,

  /// 私人使用痕迹：任何组合下导出时都清空。
  alwaysStripped,
}

/// [backupTableRules] 的一条规则。
@immutable
class BackupTableRule {
  const BackupTableRule.follows(this.categories)
    : fate = BackupTableFate.followsCategories,
      handler = null;

  const BackupTableRule.rowLevel(String this.handler)
    : fate = BackupTableFate.rowLevel,
      categories = const <BackupCategory>{};

  const BackupTableRule.deviceLocal()
    : fate = BackupTableFate.deviceLocal,
      categories = const <BackupCategory>{},
      handler = null;

  const BackupTableRule.alwaysStripped()
    : fate = BackupTableFate.alwaysStripped,
      categories = const <BackupCategory>{},
      handler = null;

  final BackupTableFate fate;

  /// [BackupTableFate.followsCategories] 的归属类别：任一被勾选，整表随包。
  final Set<BackupCategory> categories;

  /// [BackupTableFate.rowLevel] 的按行裁剪逻辑名（仅供阅读与审计）。
  final String? handler;

  /// 在勾选集合 [included] 下，导出副本是否必须整表清空。
  bool strippedFor(Set<BackupCategory> included) => switch (fate) {
    BackupTableFate.followsCategories => !categories.any(included.contains),
    BackupTableFate.alwaysStripped => true,
    BackupTableFate.rowLevel || BackupTableFate.deviceLocal => false,
  };
}

const Set<BackupCategory> _bookOrVideo = <BackupCategory>{
  BackupCategory.books,
  BackupCategory.videos,
};

/// **每张表**在备份导出里的去向——唯一真相源。
///
/// 以前只有被某段剥离逻辑点名的表才受类别勾选约束，没人点名的表（剪贴板历史、
/// 最近打开流、视频刮削缓存与本地路径、AniDB 文件身份、书籍注音揭示状态……）
/// 不管勾了什么都整份随包出境——「只导出词典」的备份照样带着这些个人数据。
/// 守卫 `test/sync/backup_table_rules_guard_test.dart` 要求 schema 里每张表都在
/// 这里登记，新加表不归类就红。
///
/// 顺序即 [_stripTablesOfExcludedCategories] 的删除顺序：同组内子表在前。
const Map<String, BackupTableRule> backupTableRules = <String, BackupTableRule>{
  // ── 词典 ──
  'dictionary_metadata': BackupTableRule.rowLevel(
    '_stripDictionaryState / _stripGhostDictionaryRows',
  ),

  // ── 设置 / 配置档案 ──
  'preferences': BackupTableRule.rowLevel(
    'settingsPrefPredicate / _stripExcludedContentRegistry / _stripCredentials',
  ),
  'anki_mappings': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.settings,
  }),
  'profile_settings': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.profiles,
  }),
  'media_type_profiles': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.profiles,
  }),
  'book_profiles': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.profiles,
  }),
  'language_profiles': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.profiles,
  }),
  'profiles': BackupTableRule.rowLevel(
    '_stripExcludedDataCategories（勾了 srs 时保留 SRS 归属档案行）',
  ),

  // ── 书 ──
  'epub_books': BackupTableRule.rowLevel('_retainBooks'),
  'book_custom_css': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'revealed_images': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'manga_chapter_states': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'manga_reader_overrides': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'collection_book_aliases': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'book_tombstones': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
  }),
  'srt_books': BackupTableRule.rowLevel('无类别：独立字幕书架条目恒随包'),

  // ── 有声书 ──
  'audio_cues': BackupTableRule.rowLevel('_retainAudiobooks'),
  'audiobooks': BackupTableRule.rowLevel('_retainAudiobooks'),

  // ── 视频（刮削元数据 / 本地路径 / 识别缓存）──
  'video_books': BackupTableRule.rowLevel('_retainVideos'),
  'video_sidecar_artifacts': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_source_scrape_runs': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_source_scrape_settings': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_episode_binding_overrides': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_scrape_meta': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_raw_snapshots': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_provider_identities': BackupTableRule.follows(
    <BackupCategory>{BackupCategory.videos},
  ),
  'video_metadata_images': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_credits': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_work_terms': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_extras': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_episodes': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_seasons': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_works': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_terms': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_people': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'video_metadata_characters': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  'anidb_file_identities': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  // v119 视频字幕 AI 校对的作品级专名表：含用户手编条目（用户数据），随「视频」
  // 类别出境。键是本机合集 / 作品 id，与 video_metadata_* 同样不进合并导入。
  'video_subtitle_glossaries': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),
  // v143 用户在字幕列表里手改的单条字幕文本（用户数据），随「视频」类别出境。
  // 键是本机视频 uid，与 video_subtitle_glossaries 一样不进合并导入。
  'video_subtitle_text_overrides': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
  }),

  // ── 游戏 ──
  'galgame_sources': BackupTableRule.rowLevel('_retainGames（FK cascade）'),
  'galgames': BackupTableRule.rowLevel('_retainGames'),
  // v134：文本钩子台词——唯一的持久副本（「我库里的例句」的游戏来源由它派生），随游戏
  // 一起出境；按游戏选择裁剪时经外键 cascade 跟着宿主走。合并导入见
  // BackupMergeEngine._mergeGalgameTextLines（按游戏身份重映射 + (游戏, 台词) 去重）。
  'galgame_text_lines': BackupTableRule.rowLevel('_retainGames（FK cascade）'),

  // ── 书 / 视频共享 ──
  'media_tracking_outbox': BackupTableRule.follows(_bookOrVideo),
  'media_tracking_mappings': BackupTableRule.follows(_bookOrVideo),
  'series': BackupTableRule.follows(_bookOrVideo),
  'collection_member_tombstones': BackupTableRule.follows(_bookOrVideo),
  // v129 作品图谱：连接跨书 / 视频 / 游戏三类内容，任一勾选就随包（端点本机不在
  // 的连接照常保留，详情页显示「未入库」灰卡），三类全不勾整表清空。
  'media_links': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
    BackupCategory.videos,
    BackupCategory.games,
  }),
  // v135 作品图谱 L5：人物身份桥（Wikidata 桥接缓存 + 用户确认 / 否决的「同一人」）
  // 连接视频 / 游戏 / 音乐三域的人物，任一勾选就随包；只含外部 id 与人物引用串。
  'person_identity_bridges': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.videos,
    BackupCategory.games,
    BackupCategory.music,
  }),
  // v135：动画集 ↔ 原作卷 / 章的手动对应点（用户数据，端点是书与视频）。
  'adaptation_progress_anchors': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.books,
    BackupCategory.videos,
  }),

  // ── 合集 / 书架 / 标签 / 同步墓碑（按 media_type 行级裁剪）──
  'collection_scrape_meta': BackupTableRule.rowLevel(
    '随 media_collections FK cascade',
  ),
  'collection_relations': BackupTableRule.rowLevel(
    '随 media_collections FK cascade',
  ),
  'media_images': BackupTableRule.rowLevel(
    '随 media_collections / video_books FK cascade',
  ),
  'media_collection_items': BackupTableRule.rowLevel(
    '_stripOrphanUserDataTables',
  ),
  'media_collections': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),
  'shelf_entries': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),
  'tag_assignments': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),
  // v122 作品级私密标记：与 tag_assignments 同一套宿主逻辑外键，被裁剪内容的标记
  // 一并收敛掉。
  'media_privacy_flags': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),
  'book_tags': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),
  'book_tag_membership_tombstones': BackupTableRule.rowLevel(
    '_stripOrphanUserDataTables',
  ),
  'sync_deletion_tombstones': BackupTableRule.rowLevel(
    '_stripOrphanUserDataTables',
  ),
  'media_sources': BackupTableRule.rowLevel('_stripOrphanUserDataTables'),

  // ── 进度 ──
  'reader_positions': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.progress,
  }),
  'bookmarks': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.progress,
  }),
  // v128 内置浏览器历史 / 书签（含文件夹）：浏览「进度」，随进度类别走。
  'web_browser_history': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.progress,
  }),
  'web_browser_bookmarks': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.progress,
  }),
  // 「最近打开流」：带进度两数，外部媒体行还带 URL 与标题快照。
  'media_open_history': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.progress,
  }),

  // ── 统计（与 _statisticsTables 一致，守卫钉死）──
  'reading_statistics': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'reading_hourly_logs': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'video_watch_statistics': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'video_hourly_logs': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'mining_statistics': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'lookup_mining_counters': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'mined_sentences': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'favorite_words': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'activity_events': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'galgame_sessions': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'study_segments': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'study_segment_tombstones': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),
  'statistics_tombstones': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.statistics,
  }),

  // 复习（SRS）的表不在主库里：归 Rust 的 srs.db，随「复习」类别整份快照进 zip 的 `srs.db`
  // 条目（docs/specs/2026-10-23-srs-rust-store.md §4，见 backup_srs_tables.dart）。

  // ── 音乐用户数据（v130；与 musicUserTables 一致，子表在前）──
  'music_playlist_entries': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.music,
  }),
  'music_playlists': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.music,
  }),
  'music_lyrics': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.music,
  }),
  'music_videos': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.music,
  }),
  'music_play_events': BackupTableRule.follows(<BackupCategory>{
    BackupCategory.music,
  }),

  // ── 私人使用痕迹 ──
  'search_history_items': BackupTableRule.alwaysStripped(),
  'dictionary_history': BackupTableRule.alwaysStripped(),

  // ── 设备本地（= _deviceLocalTables）──
  'clipboard_history': BackupTableRule.deviceLocal(),
  'video_download_subscription_items': BackupTableRule.deviceLocal(),
  'video_download_job_subtitles': BackupTableRule.deviceLocal(),
  'video_download_job_files': BackupTableRule.deviceLocal(),
  'video_download_subscriptions': BackupTableRule.deviceLocal(),
  'video_download_jobs': BackupTableRule.deviceLocal(),
  'manga_source_preferences': BackupTableRule.deviceLocal(),
  'manga_online_sources': BackupTableRule.deviceLocal(),
  'manga_extensions': BackupTableRule.deviceLocal(),
  'manga_extension_stores': BackupTableRule.deviceLocal(),
  'manga_trusted_signers': BackupTableRule.deviceLocal(),
  'sync_baselines': BackupTableRule.deviceLocal(),
  'fushi_paired_peers': BackupTableRule.deviceLocal(),
  'web_mine_queue': BackupTableRule.deviceLocal(),
  'video_file_specs': BackupTableRule.deviceLocal(),
  'update_feed_entries': BackupTableRule.deviceLocal(),
  'manga_download_jobs': BackupTableRule.deviceLocal(),
  'pending_mine_queue': BackupTableRule.deviceLocal(),
  // v124：AI 整理记录（本机做过哪些整理、供撤销），设备本地。
  'library_organize_runs': BackupTableRule.deviceLocal(),
  'library_organize_changes': BackupTableRule.deviceLocal(),
  // v136：AI 助手对话与操作记录，设备本地，见 2026-10-26 设计稿 §5.3。
  'ai_agent_sessions': BackupTableRule.deviceLocal(),
  'ai_agent_actions': BackupTableRule.deviceLocal(),
  // v128：内置浏览器标签页会话 / 最近关闭 / 下载记录，设备本地。
  'web_browser_session_tabs': BackupTableRule.deviceLocal(),
  'web_browser_closed_tabs': BackupTableRule.deviceLocal(),
  'web_browser_downloads': BackupTableRule.deviceLocal(),
  // v130 音乐曲库目录：设备本地（本机重扫产物 + 绝对路径，见 _deviceLocalTables）。
  'music_track_credits': BackupTableRule.deviceLocal(),
  'music_tracks': BackupTableRule.deviceLocal(),
  'music_albums': BackupTableRule.deviceLocal(),
  'music_artists': BackupTableRule.deviceLocal(),
  'music_disc_sources': BackupTableRule.deviceLocal(),
  // v131：OP / ED 声纹比对的按集缓存，设备本地（见 _deviceLocalTables）。
  'video_theme_song_spans': BackupTableRule.deviceLocal(),
  // v135：游戏 VNDB 配音表缓存，设备本地（见 _deviceLocalTables）。
  'game_voice_casts': BackupTableRule.deviceLocal(),
  // v133：音乐刮削三表（识别结论 / 原始快照 / 字段锁），键含本机路径派生的 track_uid、
  // 可由重刮重建，设备本地（见 _deviceLocalTables）。
  'music_scrape_meta': BackupTableRule.deviceLocal(),
  'music_metadata_raw_snapshots': BackupTableRule.deviceLocal(),
  'music_locked_fields': BackupTableRule.deviceLocal(),
  'remote_audio_bindings': BackupTableRule.deviceLocal(),
};

/// 守卫测试用：各段专门剥离逻辑点名的表清单，用来核对与 [backupTableRules]
/// 不漂移。
@visibleForTesting
Map<String, List<String>> get backupNamedTableListsForTesting =>
    <String, List<String>>{
      'deviceLocal': _deviceLocalTables,
      'deviceLocalParentFirst': _deviceLocalTablesParentFirst,
      'statistics': _statisticsTables,
    };

/// 按 [backupTableRules] 清空导出副本里**必须不随包**的表：归属类别全部未勾选
/// 的 [BackupTableFate.followsCategories] 表，以及 [BackupTableFate.alwaysStripped]
/// 表。跑在各段专门剥离之后，作为统一的兜底：专门逻辑已清过的表在这里是空操作。
/// 外键保持开启、按 [backupTableRules] 的子表在前顺序删，cascade / setNull 照常生效。
/// 最后 VACUUM + checkpoint，删掉的原文不留在空闲页 / WAL。
Future<void> _stripTablesOfExcludedCategories(
  String dbDirectory,
  Set<BackupCategory> included,
) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    await db.transaction(() async {
      for (final MapEntry<String, BackupTableRule> e
          in backupTableRules.entries) {
        if (!e.value.strippedFor(included)) continue;
        await db.customStatement('DELETE FROM ${e.key}');
      }
    });
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}
