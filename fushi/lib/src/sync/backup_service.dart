import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/media/override_title_key.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/fushi_time_format.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

part 'backup_service/fs_retry.part.dart';
part 'backup_service/path_rebase.part.dart';
part 'backup_service/restore.part.dart';

/// 本地备份导出物文件名口径。存储页与导出前清扫共用，避免一边展示、一边认不出。
///
/// 形状 = [BackupService.defaultFilename] 产出的 `fushi-backup-<日期>.fushi.zip`
/// （`hibiki-backup-*.hibiki.zip` 是改名前的老包）。
///
/// **刻意用「前缀 + 后缀」双重限定，而不是只认 `.fushi.zip`**：临时目录里还可能躺着
/// 推荐词典包 `fushi-recommended.fushi.zip` 这类同后缀、但绝不该被当成备份清掉的文件。
/// 这条理由必须住在真相源这里——它以前留在 `backup.part.dart` 的清扫函数头上，正则搬
/// 过来时被落下了，于是唯一定义这个口径的地方反而不知道自己为什么长这样。
final RegExp backupArchiveNamePattern =
    RegExp(r'^(fushi|hibiki)-backup-.*\.(fushi|hibiki)\.zip$');

bool isBackupArchiveName(String name) =>
    backupArchiveNamePattern.hasMatch(name);

/// Optional file-tree categories a backup export can include. The database
/// (`fushi.db`) is NOT a category - it carries every table's metadata
/// (books / stats / favorites / profiles / settings / dictionary records) whose
/// rows FK into each other, so it is ALWAYS exported as one consistent blob;
/// only the bulky sidecar file trees below are individually selectable.
///
/// When [BackupService.createBackup] is called with a [categories] set, only the
/// listed trees are packed; an unselected tree's root is skipped exactly as if
/// the user had no such content. A null set means "everything" (the legacy
/// all-in export), so existing callers are unchanged.
enum BackupCategory {
  /// Imported dictionary resource files (`dictionaryResources/`).
  dictionary,

  /// Extracted book content tree (`hoshi_books/`: epub + html/images/fonts +
  /// covers).
  books,

  /// Audiobook audio + alignment files (`audiobooks/`).
  audiobooks,

  /// User-imported custom font files (`custom_fonts/`).
  fonts,

  /// Video files referenced by `video_books.video_path` / playlist episodes.
  ///
  /// Videos can be very large and are often stored outside the app documents
  /// directory, so the UI leaves this category opt-in by default.
  videos,

  /// Local audio pronunciation databases (`local_audio_*.db` + `-wal`/`-shm`),
  /// stored flat in the support/database directory alongside `hibiki.db`. The
  /// `local_audio_dbs` preference stores their absolute paths, so without
  /// packing the files a restore points at databases that never crossed over
  /// and the local audio sources silently disappear (TODO-941). Packed under
  /// the `localAudio/` archive prefix; these sets can be large (Forvo-style
  /// audio), so the UI leaves this opt-in by default like videos.
  localAudio,

  /// Reading progress: where you left off in every book. Covers the
  /// `reader_positions` + `bookmarks` tables and the `audiobook_pos_*`
  /// preference rows. When unticked these rows are stripped from the exported
  /// DB copy, so the backup carries the library WITHOUT any position/bookmark.
  /// Included by default.
  progress,

  /// Reading / video / mining statistics + favorite words. Covers
  /// `reading_statistics`, `reading_hourly_logs`, `video_watch_statistics`,
  /// `video_hourly_logs`, `mining_statistics`, `lookup_mining_counters`,
  /// `mined_sentences`, `favorite_words`, plus the two fact streams
  /// `activity_events` (home Activity timeline) and `galgame_sessions`
  /// (play-session facts; the `galgames` library rows themselves are content,
  /// not statistics, and always travel). Stripped from the DB copy when
  /// unticked. Included by default.
  statistics,

  /// App + reader settings -- the `preferences` table's pure-settings rows
  /// (everything EXCEPT audiobook positions/progress, favorite sentences, and
  /// the content-registry prefs owned by the fonts / local-audio / audio
  /// categories; see [BackupService.settingsPrefPredicate]). Stripped from the
  /// DB copy when unticked; on import the LOCAL device's settings are preserved
  /// instead of being wiped to empty (never turn "exclude settings" into "wipe
  /// settings"). Included by default.
  settings,

  /// Configuration profiles -- the `profiles`, `profile_settings`,
  /// `media_type_profiles` and `book_profiles` tables. Stripped from the DB
  /// copy when unticked; on import the LOCAL device's profiles are preserved
  /// instead of being wiped to empty. Included by default.
  profiles,
}

/// Rewrites an absolute [oldPath] that lives under [oldRoot] so it lives under
/// [newRoot] instead, preserving the sub-path. Returns [oldPath] verbatim when
/// it is not under [oldRoot] (already local, or an unrelated location).
///
/// A full-data backup stores file paths captured on the SOURCE device. On the
/// importing device the app directories differ (iOS reassigns the container
/// UUID on every reinstall), so the stored absolute paths would not resolve.
/// Import rebases every stored path from the backup's recorded root to this
/// device's matching root. Separators are normalized so `/` vs `\` differences
/// between the compared strings don't defeat the prefix match.
String rebasePath(String oldPath, String oldRoot, String newRoot) {
  String stripTrailing(String s) =>
      (s.endsWith('/') || s.endsWith('\\')) ? s.substring(0, s.length - 1) : s;
  // Normalize separators ONLY for the prefix comparison; the returned path
  // keeps the source path's original separators (a POSIX backup restored on a
  // POSIX host must not gain Windows separators just because p.join would, and
  // vice-versa). So we slice the original oldPath rather than rebuild via join.
  final String nrOld = stripTrailing(oldRoot.replaceAll('\\', '/'));
  final String npOld = oldPath.replaceAll('\\', '/');
  if (npOld == nrOld) return stripTrailing(newRoot);
  // Require a separator boundary so "/a/books_extra" is not treated as under
  // "/a/books". replaceAll preserves length, so nrOld.length indexes the
  // original oldPath correctly.
  if (!npOld.startsWith('$nrOld/')) return oldPath;
  final String suffix = oldPath.substring(nrOld.length); // keeps leading sep
  return stripTrailing(newRoot) + suffix;
}

/// Rebases every file-font `path` inside a persisted font-list JSON string
/// (`[{name, path, enabled}, ...]`) from [oldRoot] onto [newRoot] via
/// [rebasePath]. System fonts (`path == null`) and paths not under [oldRoot]
/// are left untouched. A malformed value (not a JSON list of maps) is returned
/// verbatim so a corrupt pref never aborts the import.
///
/// Custom fonts live under the SOURCE device's `<appDoc>/custom_fonts`; the
/// importing device's root differs, so the stored absolute paths would not
/// resolve and the fonts (shown as imported & enabled) would silently never
/// apply (BUG-183). Import rebases them so the reader/AppFontLoader find them.
String rebaseFontListJson(String json, String oldRoot, String newRoot,
    {String Function(String path)? rewritePath}) {
  String rewrite(String path) => rewritePath == null
      ? rebasePath(path, oldRoot, newRoot)
      : rewritePath(path);
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Object? path = e['path'];
      if (path is! String) return e; // system font (null) or odd shape
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': rewrite(path),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return json; // never throw on a corrupt pref value
  }
}

/// Rebases every file-font `path` inside the canonical font catalog JSON
/// (`{version, fonts:[{id, name, path}]}`) from [oldRoot] onto [newRoot].
/// Target rows (`font_targets`) refer to catalog entries by id and do not carry
/// paths, so preserving ids while rebasing catalog paths keeps targets valid.
/// Malformed values are returned verbatim so a corrupt pref never aborts import.
String rebaseFontCatalogJson(String json, String oldRoot, String newRoot,
    {String Function(String path)? rewritePath}) {
  String rewrite(String path) => rewritePath == null
      ? rebasePath(path, oldRoot, newRoot)
      : rewritePath(path);
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return json;
    final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
    final dynamic fonts = root['fonts'];
    if (fonts is! List) return json;
    root['fonts'] = fonts.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Map<String, dynamic> row = Map<String, dynamic>.from(e);
      final Object? path = row['path'];
      if (path is! String) return row;
      return <String, dynamic>{
        ...row,
        'path': rewrite(path),
      };
    }).toList();
    return jsonEncode(root);
  } catch (_) {
    return json; // never throw on a corrupt pref value
  }
}

/// Splits a possibly PrefCodec-tagged pref value into its (tag, jsonBody). The
/// repo writes `local_audio_dbs` as a jsonEncode(...) STRING -> `s:<json>` and
/// `audio_source_configs` as a List -> `j:<json>`; legacy / low-level
/// `db.setPref` writes are untagged `<json>` (empty tag). The pre-TODO-1171
/// rebase json-decoded the whole tagged string and silently no-op'd in
/// production; splitting the tag off first is what makes re-homing actually run.
({String tag, String body}) splitPrefTag(String raw) {
  if (raw.length >= 2 && raw[1] == ':' && (raw[0] == 's' || raw[0] == 'j')) {
    return (tag: raw[0], body: raw.substring(2));
  }
  return (tag: '', body: raw);
}

/// Re-applies the [splitPrefTag] tag to a rewritten [body].
String joinPrefTag(String tag, String body) =>
    tag.isEmpty ? body : '$tag:$body';

/// Re-homes every internal local-audio copy path (`local_audio_<ts>.db`) inside
/// a stored `local_audio_dbs` pref value onto [newRoot] by FILENAME (see
/// [LocalAudioManager.resolveInternalPath]), preserving the PrefCodec tag.
///
/// Import used to rebase by source-root prefix (TODO-941) but (a) that never ran
/// in production: the pref is PrefCodec-tagged and the old code json-decoded the
/// whole tagged string, always throwing -> verbatim no-op (the TODO-1171 root
/// cause), and (b) a bare-db import carries no source root. Filename re-homing is
/// root-independent and idempotent; each `path` points at a `local_audio_*.db`
/// under the source device's support dir, which the backup drops flat under this
/// device's support dir with the SAME name. External references (BUG-483, name
/// mismatch) keep their path. A malformed value is returned verbatim so a corrupt
/// pref never aborts import/migration.
String normalizeLocalAudioDbsJson(String stored, String newRoot) {
  final ({String tag, String body}) split = splitPrefTag(stored);
  return joinPrefTag(split.tag, _rehomeLocalAudioBody(split.body, newRoot));
}

String _rehomeLocalAudioBody(String jsonBody, String newRoot) {
  try {
    final dynamic decoded = jsonDecode(jsonBody);
    if (decoded is! List) return jsonBody;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Object? path = e['path'];
      if (path is! String) return e;
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': LocalAudioManager.resolveInternalPath(path, newRoot),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return jsonBody; // never throw on a corrupt pref value
  }
}

/// Same filename re-homing for the typed `audio_source_configs` pref value: only
/// `localAudio` entries carry a re-homable `path`; every other kind passes
/// through untouched. Kept in lock-step with [normalizeLocalAudioDbsJson] so the
/// typed-config <-> `local_audio_dbs` join (AppModel.audioSourceConfigs matches
/// by path) survives import — re-homing only one side would split them and
/// silently drop the typed local source (TODO-1171).
String normalizeAudioSourceConfigsJson(String stored, String newRoot) {
  final ({String tag, String body}) split = splitPrefTag(stored);
  return joinPrefTag(split.tag, _rehomeAudioConfigsBody(split.body, newRoot));
}

String _rehomeAudioConfigsBody(String jsonBody, String newRoot) {
  try {
    final dynamic decoded = jsonDecode(jsonBody);
    if (decoded is! List) return jsonBody;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      if (e['kind'] != AudioSourceKind.localAudio.wireName) return e;
      final Object? path = e['path'];
      if (path is! String) return e;
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': LocalAudioManager.resolveInternalPath(path, newRoot),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return jsonBody; // never throw on a corrupt pref value
  }
}

class BackupMeta {
  BackupMeta({
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.bookCount,
    required this.statsCount,
    this.booksRoot,
    this.audiobooksRoot,
    this.fontsRoot,
    this.localAudioRoot,
    this.videoFiles = const <String, String>{},
    this.excludedCategories = const <String>{},
    this.videoBookCount,
    this.audiobookCount,
  });

  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final int bookCount;
  final int statsCount;

  /// Number of `video_books` rows carried in this backup's DB blob (0 when the
  /// video category was unticked → every row was stripped on export). Lets the
  /// import dialog offer the video toggle even for a backup that packed NO video
  /// FILES (streaming/http videos, or a video whose file could not be packed) —
  /// videos live in the overwrite DB blob regardless of files, so a files-only
  /// count would hide them and import them uninvited (BUG-779). Null for older
  /// backups that predate this field; import falls back to a DB-blob peek.
  final int? videoBookCount;

  /// Number of `audiobooks` rows carried in this backup's DB blob (0 when the
  /// audiobooks category was unticked → every row stripped on export). Same role
  /// as [videoBookCount]: lets the import dialog offer the audiobooks toggle even
  /// when no audiobook FILES were packed. Null for older backups → import falls
  /// back to a DB-blob peek (BUG-781).
  final int? audiobookCount;

  /// Absolute root of the extracted-books tree on the SOURCE device
  /// (`<appDoc>/hoshi_books`), captured so import can rebase stored book paths
  /// to this device's root. Null for legacy (db-only) backups → import skips
  /// path rebasing.
  final String? booksRoot;

  /// Absolute root of the audiobook-audio tree on the SOURCE device
  /// (`<appDoc>/audiobooks`). Null for legacy backups.
  final String? audiobooksRoot;

  /// Absolute root of the custom-font tree on the SOURCE device
  /// (`<appDoc>/custom_fonts`), captured so import can rebase the stored
  /// font-config paths (`font_catalog` plus legacy shadow prefs) to
  /// this device's root. Null for legacy backups → import skips font rebasing.
  final String? fontsRoot;

  /// Absolute root of the support/database directory on the SOURCE device,
  /// where the local-audio pronunciation databases (`local_audio_*.db`) live
  /// flat alongside `hibiki.db`. Captured so import can rebase the stored
  /// `local_audio_dbs` preference paths onto this device's root. Null when the
  /// local-audio category was not packed (or a legacy backup).
  final String? localAudioRoot;

  /// Exact source video path -> archive-relative path under `videos/`.
  ///
  /// Imported videos are not copied into one stable app directory today; the DB
  /// stores the user's original absolute file paths. A single source root is
  /// therefore not enough to rebase them after restore, so the backup records
  /// the exact paths it packed and import rewrites matching DB paths onto the
  /// chosen local video restore root.
  final Map<String, String> videoFiles;

  /// Enum names ([BackupCategory.name]) of the categories the user UNTICKED for
  /// this export (TODO-1193). Import reads `settings` / `profiles` from here to
  /// know a layer is empty BY CHOICE and must be preserved from the local
  /// device rather than restored empty. Empty for a legacy backup (all-in).
  final Set<String> excludedCategories;

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'bookCount': bookCount,
        'statsCount': statsCount,
        if (booksRoot != null) 'booksRoot': booksRoot,
        if (audiobooksRoot != null) 'audiobooksRoot': audiobooksRoot,
        if (fontsRoot != null) 'fontsRoot': fontsRoot,
        if (localAudioRoot != null) 'localAudioRoot': localAudioRoot,
        if (videoFiles.isNotEmpty) 'videoFiles': videoFiles,
        if (excludedCategories.isNotEmpty)
          'excludedCategories': excludedCategories.toList(),
        if (videoBookCount != null) 'videoBookCount': videoBookCount,
        if (audiobookCount != null) 'audiobookCount': audiobookCount,
      };

  factory BackupMeta.fromJson(Map<String, dynamic> json) => BackupMeta(
        appVersion: json['appVersion'] as String,
        schemaVersion: json['schemaVersion'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        // Optional for backward compatibility with older backups.
        bookCount: json['bookCount'] as int? ?? 0,
        statsCount: json['statsCount'] as int? ?? 0,
        booksRoot: json['booksRoot'] as String?,
        audiobooksRoot: json['audiobooksRoot'] as String?,
        fontsRoot: json['fontsRoot'] as String?,
        localAudioRoot: json['localAudioRoot'] as String?,
        videoFiles: (json['videoFiles'] as Map?)?.map(
                (dynamic k, dynamic v) => MapEntry(k as String, v as String)) ??
            const <String, String>{},
        excludedCategories: (json['excludedCategories'] as List?)
                ?.map((dynamic e) => e as String)
                .toSet() ??
            const <String>{},
        videoBookCount: json['videoBookCount'] as int?,
        audiobookCount: json['audiobookCount'] as int?,
      );

  static BackupMeta? tryParse(String source) {
    try {
      return BackupMeta.fromJson(
        jsonDecode(source) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Per-category presence + item counts describing what a backup carries, driving
/// the "what's inside" manifest and the import "choose what to restore" toggles
/// (TODO-1358). Counts use the natural unit per category (dictionaries / books /
/// audiobooks / video files / font files / local-audio DBs). A category with no
/// countable content is simply absent from both [counts] and [present].
class BackupContentSummary {
  const BackupContentSummary({
    this.counts = const <BackupCategory, int>{},
    this.present = const <BackupCategory>{},
  });

  /// Item count per category that carries countable content in this backup.
  final Map<BackupCategory, int> counts;

  /// Every category this backup / device carries content for.
  final Set<BackupCategory> present;

  int countFor(BackupCategory c) => counts[c] ?? 0;
  bool has(BackupCategory c) => present.contains(c);
}

// ── 导出侧与恢复侧共用的常量 / 纯 SQL helper ───────────────────────────
// 归属拆分见 docs/plans/2026-09-06-sync-interconnect-refactor.md B1：两侧都用的
// 东西提到库级顶层，导出类（本文件）与恢复类（restore.part.dart）引用零改动。

/// 备份归档里主库条目名 = 活库文件名（fushi_core 单一真相源）。写侧（导出/
/// bak/临时提取路径）一律用它；读老归档（Hibiki 时代备份 / 迁移压缩包，条目名
/// `hibiki.db`）经 [_findDbEntry] 做 legacy 回退（Never break userspace）。
const String _dbName = fushiDatabaseFileName;
const String _metaName = 'backup_meta.json';
const String _dictionaryResourcesPrefix = 'dictionaryResources';

/// 书树条目在归档里的前缀。写侧一律用它；读侧经 [archiveBooksPrefix] 对旧
/// Hibiki 归档（前缀 `hoshi_books`）做 legacy 回退（Never break userspace，
/// 同 [_dbName] 的 `_findDbEntry` 先例）。
const String _booksPrefix = 'fushi_books';

/// 旧 Hibiki 时代备份/迁移归档的书树前缀（W2-7 读侧回退输入；旧字面量只
/// 允许活在读旧归档的回退里）。
const String _legacyBooksPrefix = 'hoshi_books';
const String _audiobooksPrefix = 'audiobooks';
const String _fontsPrefix = 'custom_fonts';
const String _videosPrefix = 'videos';
const String _localAudioPrefix = 'localAudio';

/// Preference key (in the `preferences` table) whose JSON value is the
/// local-audio library list `[{path, displayName, enabled, sources}]`. The
/// `path` of each entry points at a `local_audio_*.db` file in the support
/// directory and is rebased onto this device's root on import (TODO-941).
const String _localAudioDbsPrefKey = 'local_audio_dbs';
const String _audioSourceConfigsPrefKey = 'audio_source_configs';

/// Matches a packed local-audio database file (and its `-wal`/`-shm`
/// siblings). Only these are packed from the support directory so the export
/// never sweeps in `fushi.db` or other unrelated support files.
final RegExp _localAudioFileName = RegExp(r'^local_audio_\d+\.db(-wal|-shm)?$');

/// Matches ONLY a packed local-audio database file (not its `-wal`/`-shm`
/// siblings), for counting distinct local-audio databases in a summary.
final RegExp _localAudioDbOnly = RegExp(r'^local_audio_\d+\.db$');

/// Persisted preference key (ReaderSettings prefix included) whose JSON
/// value is the canonical catalog `{version, fonts:[{id, name, path}]}`.
const String _fontCatalogPrefKey = 'src:reader_fushi:font_catalog';

/// Persisted legacy shadow preference keys (ReaderSettings prefix included)
/// whose JSON value is a font list `[{name, path, enabled}]`. These remain
/// import-compatible while `font_catalog` is the canonical model.
const List<String> _legacyFontPrefKeys = <String>[
  'src:reader_fushi:custom_fonts',
  'src:reader_fushi:app_ui_fonts',
  'src:reader_fushi:dict_fonts',
  'src:reader_fushi:video_sub_fonts',
  'src:reader_fushi:game_lookup_fonts',
];

/// Preference key holding the favorite-sentence JSON list (mirrors
/// `FavoriteSentenceRepository._key` / `BackupMergeEngine`). It is CONTENT
/// (favorite sentences travel / merge as content), so the `settings` category
/// strip must never delete it.
const String _favoriteSentencesPrefKey = 'favorite_sentences';

/// Device-local tables that must NEVER travel in a shared backup and are
/// always restored from this device's pre-restore bak on an overwrite import
/// (BUG-816). Same philosophy as [SyncRepository.deviceLocalPrefKeys]:
///   - `fushi_paired_peers` — LAN pairing rows including the plaintext auth
///     `token` (a live credential the HBK-AUDIT-012 pref-key sweep missed
///     because it lives in its own table, not `preferences`).
///   - `sync_baselines`      — per-asset incremental-sync causality; carrying
///     it to another device corrupts later fork detection (mirrors why
///     `_keyCollectionsBaselineMs` is device-local).
///   - `manga_*`             — Mihon repositories, executable-extension
///     identities, signer trust decisions, source state and arbitrary
///     extension preferences. APKs and runtime cookies deliberately do not
///     travel, so exporting these rows would both create broken ghost
///     extensions and risk leaking source credentials stored as preferences.
///   - `video_download_*`    — durable jobs/subscriptions are tied to this
///     installation's backend fingerprint, local paths and source-library
///     ids. Sending them to another device could enqueue work against the
///     wrong backend. Their five-table FK graph is ordered explicitly below.
///
/// [_deviceLocalTables] is CHILD-first and is the only order allowed for a
/// wipe. [_deviceLocalTablesParentFirst] is the inverse dependency order used
/// for restore. Keeping two named lists is intentional: reusing one loop for
/// both directions silently worked before the v78 graph existed, but now
/// fails with `foreign_keys=ON`.
const List<String> _deviceLocalTables = <String>[
  'video_download_subscription_items',
  'video_download_job_subtitles',
  'video_download_job_files',
  'video_download_subscriptions',
  'video_download_jobs',
  'manga_source_preferences',
  'manga_online_sources',
  'manga_extensions',
  'manga_extension_stores',
  'manga_trusted_signers',
  'sync_baselines',
  'fushi_paired_peers',
  'web_mine_queue',
  'video_file_specs',
];

const List<String> _deviceLocalTablesParentFirst = <String>[
  'video_file_specs',
  'web_mine_queue',
  'sync_baselines',
  'fushi_paired_peers',
  'manga_extension_stores',
  'manga_extensions',
  'manga_online_sources',
  'manga_source_preferences',
  'manga_trusted_signers',
  'video_download_jobs',
  'video_download_subscriptions',
  'video_download_job_files',
  'video_download_job_subtitles',
  'video_download_subscription_items',
];

/// Content tables stripped from the exported DB copy when the `statistics`
/// category is unticked (TODO-1193). None is FK-targeted by another content
/// table, so a wholesale DELETE is safe (`galgame_sessions` is itself an FK
/// CHILD of `galgames`; nothing references it, so deleting it trips nothing).
///
/// `activity_events` / `galgame_sessions` are session-granularity FACT
/// streams, not aggregates, but they are what the statistics pages render
/// from — the untick promise ("my stats don't travel") must cover them too.
/// The `galgames` library rows stay: games are content, their sessions are
/// statistics (mirrors `clearAllGalgameStatistics`, which deletes only the
/// session facts).
const List<String> _statisticsTables = <String>[
  'reading_statistics',
  'reading_hourly_logs',
  'video_watch_statistics',
  'video_hourly_logs',
  'mining_statistics',
  'lookup_mining_counters',
  'mined_sentences',
  'favorite_words',
  'activity_events',
  'galgame_sessions',
];

/// The four profile-layer tables in CHILD-first order, so a DELETE sweep of
/// the `profiles` category (TODO-1193) never trips an enforced FK to
/// `profiles`. The reverse of [_settingsLayerTables] (which is parent-first
/// for INSERT).
const List<String> _profilesLayerTablesChildFirst = <String>[
  'profile_settings',
  'media_type_profiles',
  'book_profiles',
  'profiles',
];

/// SQL predicate selecting the `preferences` rows the `settings` backup
/// category governs (TODO-1193): the PURE app/reader settings only. It
/// EXCLUDES (preserves) the rows owned by other categories or that are
/// content, so an "exclude settings" export never collaterally drops them:
///   - `audiobook_pos_*`         -> progress (the `progress` category)
///   - `favorite_sentences`      -> favorites content, gated on `books`
///     (BUG-816, stripped/restored separately by the content-registry path)
///   - `local_audio_dbs`         -> local-audio registry (`localAudio`, BUG-816)
///   - `audio_source_configs`    -> audio-source config (`localAudio`, BUG-816)
///   - font catalog + legacy font prefs -> font registry (`fonts`, BUG-816)
///   - `*override_title://*`     -> 用户给书改的名字，是**内容**不是设置
///     (BUG-1488)。`ProfileKeys.isExcludedPref` 早就这么归类（改名不进 Profile
///     快照），这里却把它当 app 设置 strip 掉 —— 不勾 `settings` 导出，用户
///     所有书的改名一并消失（视频改名落在 `video_books.title` 列上，不受影响，
///     所以这条不对称只砸书）。
/// BUG-816: `sync_*` behaviour toggles ARE settings (see `sync_repository.dart`
/// — they are treated as user settings that travel), so they are NO LONGER
/// excepted here: unticking `settings` now strips them from the export and the
/// import restores them from bak. The device-local sync CONFIG / credentials
/// (`deviceLocalPrefKeys`) are handled out-of-band by `_stripCredentials`
/// (export) + `_applyPreservedConfig` (import, authoritative last word), so
/// letting this predicate also touch them on a settings-excluded restore is a
/// harmless no-op that `_applyPreservedConfig` overrides.
/// Used SYMMETRICALLY by the export strip and the import preserve-from-bak so
/// a `settings`-excluded backup and its restore never diverge.
final String settingsPrefPredicate = _buildSettingsPrefPredicate();

String _buildSettingsPrefPredicate() {
  final List<String> preservedExactKeys = <String>[
    _favoriteSentencesPrefKey,
    _localAudioDbsPrefKey,
    _audioSourceConfigsPrefKey,
    _fontCatalogPrefKey,
    ..._legacyFontPrefKeys,
  ];
  final String notIn = preservedExactKeys
      .map((String k) => "'${k.replaceAll("'", "''")}'")
      .join(', ');
  return "key NOT LIKE 'audiobook_pos_%' "
      'AND key NOT IN ($notIn) '
      'AND $_notOverrideTitleSql';
}

/// 「这行 pref 不是书名 override」的 SQL 判据。用 `instr` 而非 `LIKE '%…%'`：
/// 前缀里的 `_` 在 LIKE 里是通配符，`instr` 是逐字节子串匹配，零歧义。
const String _notOverrideTitleSql =
    "instr(key, '$kOverrideTitleKeyMarker') = 0";

/// Strips the four DB-only data categories (TODO-1193) from the standalone
/// exported DB copy in [dbDirectory] when the user unticked them. Opened via
/// [FushiDatabase] (the copy is already at the current schema, so no
/// migration runs). Operates ONLY on the export copy — the live user DB is
/// never touched.
///
/// - [stripProgress]   : `reader_positions`, `bookmarks`, and the
///   `audiobook_pos_*` preference rows.
/// - [stripStatistics] : [_statisticsTables].
/// - [stripSettings]   : the pure-settings `preferences` rows
///   ([settingsPrefPredicate]) — progress / favorites / content-registry /
///   sync prefs are deliberately preserved.
/// - [stripProfiles]   : the four profile-layer tables (child-first so an
///   enforced FK to `profiles` never blocks the sweep).
///
/// A single VACUUM + checkpoint afterwards keeps the deleted rows out of the
/// freelist pages so they cannot be recovered from the shared backup.
Future<void> _stripExcludedDataCategories(
  String dbDirectory, {
  required bool stripProgress,
  required bool stripStatistics,
  required bool stripSettings,
  required bool stripProfiles,
}) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    if (stripProgress) {
      await db.customStatement('DELETE FROM reader_positions');
      await db.customStatement('DELETE FROM bookmarks');
      await db.customStatement(
          "DELETE FROM preferences WHERE key LIKE 'audiobook_pos_%'");
    }
    if (stripStatistics) {
      for (final String table in _statisticsTables) {
        await db.customStatement('DELETE FROM $table');
      }
    }
    if (stripSettings) {
      await db.customStatement(
          'DELETE FROM preferences WHERE $settingsPrefPredicate');
    }
    if (stripProfiles) {
      for (final String table in _profilesLayerTablesChildFirst) {
        await db.customStatement('DELETE FROM $table');
      }
    }
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// Deletes from the exported DB copy in [dbDirectory] every epub book whose
/// `book_key` is NOT in [keep], plus all of that book's dependent rows via the
/// canonical [FushiDatabase.deleteEpubBook] cascade (reader position,
/// bookmarks, tag mappings, audiobook + cues, srt rows, shelf entry). [keep]
/// empty strips every book (the "book content" category was unticked);
/// a non-empty set keeps only the user-selected books (per-book export).
///
/// Root fix for the "ghost book" bug (TODO-1195 part C/A): the whole DB is
/// exported as one VACUUM-INTO blob, so without this every book's `epub_books`
/// row travelled even when its `hoshi_books/` files were left out — a
/// restore/merge then inserted book rows with no content = un-openable books.
/// Filtering the rows here makes the "book content" switch / per-book
/// selection consistent: a book that isn't packed never appears after import.
Future<void> _retainBooks(
  String dbDirectory,
  Set<String> keep,
) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    for (final EpubBookRow b in await db.getAllEpubBooks()) {
      if (keep.contains(b.bookKey)) continue;
      // Default (tombstone: false): stripping a book from an export copy is
      // NOT a user deletion, so it must never write a resurrection tombstone
      // into the backup DB (TODO-1195 part B interaction).
      await db.deleteEpubBook(b.bookKey);
    }
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// Per-video analogue of [_retainBooks]: DELETEs every `video_books` row whose
/// `book_uid` is NOT in [keep] (plus its dependent rows — subtitle cues, tag
/// mappings, shelf entry — via the canonical [FushiDatabase.deleteVideoBook]
/// cascade). [keep] empty strips every video (the video category was
/// unticked); a non-empty set keeps only the user-selected videos (per-video
/// export). Same root fix as books: without stripping the row a restore/merge
/// would insert a video record whose file never travelled = an un-openable
/// "ghost video".
Future<void> _retainVideos(
  String dbDirectory,
  Set<String> keep,
) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    for (final VideoBookRow v in await db.allVideoBooks()) {
      if (keep.contains(v.bookUid)) continue;
      await db.deleteVideoBook(v.bookUid);
    }
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// Audiobook analogue of [_retainVideos] (BUG-781): DELETEs every `audiobooks`
/// row whose `bookKey` is NOT in [keep], via the canonical
/// [FushiDatabase.deleteAudiobookByBookKey] cascade (its `audio_cues` rows +
/// the `srt` shelf entry). [keep] empty strips every audiobook (the audiobooks
/// category was unticked). Same root fix as books/videos: an audiobook whose
/// audio never travelled must not survive as a "ghost audiobook" (a shelf entry
/// + alignment rows pointing at audio files that are not on this device). Does
/// NOT touch standalone `srt_books` rows — those are their own shelf items, not
/// counted in the audiobooks category (which is `getAllAudiobooks()` = the
/// epub-attached `Audiobooks` table).
Future<void> _retainAudiobooks(
  String dbDirectory,
  Set<String> keep,
) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    for (final AudiobookRow a in await db.getAllAudiobooks()) {
      if (keep.contains(a.bookKey)) continue;
      await db.deleteAudiobookByBookKey(a.bookKey);
    }
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// 一次导出里词典的**逐本**打包计划（BUG-2193）。
///
/// 存在的理由：以前判据是一个 bool（`_hasCompleteDictionaryResources`），语义是
/// 「**每一行** dictionary_metadata 都在磁盘上有文件才打包」。这条不变式本身是对的
/// （不能让恢复端造出查不了的幽灵词典），但把它实现成**全表 AND 门**意味着：
/// 库里只要有一条幽灵行（profile 切换误删过目录、导入中断、`.pending_delete` 残留
/// 都会造出来），**全部**词典就一本都不打包，还顺手把 DB 副本里的词典行整表清空，
/// 而导出照样报成功。用户勾了「词典」，拿到手的 zip 里只有 backup_meta.json 和
/// fushi.db。
///
/// 改法是把「全表 AND」换成「逐本分区」：有文件的照打，幽灵行只删它自己那一行。
/// 不变式依然成立——出包里的每一行都有对应文件——但代价从「全部」降到「那一条」。
class _DictionaryPackPlan {
  const _DictionaryPackPlan({required this.packable, required this.ghosts});

  const _DictionaryPackPlan.empty()
      : packable = const <String>[],
        ghosts = const <String>[];

  /// 磁盘上确有文件、这次会被打进 zip 的词典名。
  final List<String> packable;

  /// 元数据在、磁盘资源缺失的词典名。它们的 DB 行会从导出副本里删掉，
  /// **只删这些行**，其余词典不受牵连。
  final List<String> ghosts;
}

class BackupService {
  BackupService({
    required FushiDatabase db,
    required String dbDirectory,
    required String appVersion,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
    String? fontsRootDirectory,
  })  : _db = db,
        _dbDirectory = dbDirectory,
        _dictionaryResourceDirectory = dictionaryResourceDirectory,
        _booksRootDirectory = booksRootDirectory,
        _audiobooksRootDirectory = audiobooksRootDirectory,
        _fontsRootDirectory = fontsRootDirectory,
        _appVersion = appVersion;

  final FushiDatabase _db;
  final String _dbDirectory;
  final String? _dictionaryResourceDirectory;

  /// Root of the extracted-books tree (`<appDoc>/hoshi_books`). When provided,
  /// the full book content (epub + extracted html/images/fonts + covers) is
  /// packed into the backup; null keeps the legacy db-only export.
  final String? _booksRootDirectory;

  /// Root of the audiobook-audio tree (`<appDoc>/audiobooks`). When provided,
  /// audio files are packed into the backup.
  final String? _audiobooksRootDirectory;

  /// Root of the custom-font tree (`<appDoc>/custom_fonts`). When provided, the
  /// imported font files are packed into the backup so they travel with the
  /// font config (BUG-183: otherwise the config points at files that never
  /// crossed over).
  final String? _fontsRootDirectory;

  final String _appVersion;

  String get _dbPath => p.join(_dbDirectory, _dbName);

  /// A streaming (URL) video book — its `video_path` is an http(s) URL and it is
  /// self-contained (re-opens by URL, needs no packed file). Mirrors the merge
  /// engine's SQL predicate so export counts and import filtering stay aligned
  /// (TODO-1261).
  static bool _isStreamingVideoPath(String videoPath) =>
      videoPath.startsWith('http://') || videoPath.startsWith('https://');

  /// COUNT(*) of a table on the live DB (used to report honest export totals).
  Future<int> _countRows(String table) async {
    final row =
        await _db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.data['c'] as int;
  }

  /// Builds the export "what's inside" summary from the live DB + this device's
  /// content roots (TODO-1358). Counts are the natural unit per category; a root
  /// this service was built without counts as zero. Reads only counts, so it is
  /// cheap even on a large library.
  Future<BackupContentSummary> summarizeLiveContent() async {
    final int books = (await _db.getAllEpubBooks()).length;
    final int audiobooks = (await _db.getAllAudiobooks()).length;
    final int videos = (await _db.allVideoBooks()).length;
    // BUG-2193：**只数打得出来的那些**。旧实现数的是 dictionary_metadata 行数，
    // 与打包判据不同源，于是勾选框显示「词典 (12)」、导出后一本都没有，用户完全
    // 无从察觉。与下面字体那一条同一条纪律：预览计数 = 实际打包内容。
    final int dictionaries =
        (await _planDictionaryPack(_dictionaryResourceDirectory == null
                ? null
                : Directory(_dictionaryResourceDirectory)))
            .packable
            .length;
    // Count the fonts the USER manages (catalog entries whose file lives under
    // custom_fonts/), not every file in the tree: failed `_tmp_*` downloads and
    // replaced-but-unreferenced old files inflated the count (a user with 2
    // fonts saw 7). This is also exactly what the export packs, so the preview
    // count, the packed content and the import readback all agree.
    final int fonts = (await _referencedFontFiles()).length;
    final int localAudio = await _countLocalAudioDbs();
    final Map<BackupCategory, int> counts = <BackupCategory, int>{
      BackupCategory.dictionary: dictionaries,
      BackupCategory.books: books,
      BackupCategory.audiobooks: audiobooks,
      BackupCategory.fonts: fonts,
      BackupCategory.videos: videos,
      BackupCategory.localAudio: localAudio,
    };
    return BackupContentSummary(
      counts: counts,
      present: counts.entries
          .where((MapEntry<BackupCategory, int> e) => e.value > 0)
          .map((MapEntry<BackupCategory, int> e) => e.key)
          .toSet(),
    );
  }

  /// The custom-font files under [_fontsRootDirectory] the user actually
  /// manages: every `path` referenced by the canonical font catalog (or its
  /// legacy shadow lists) that resolves to an existing file under the fonts
  /// root. Orphan/temp leftovers in the tree (failed `_tmp_*` downloads,
  /// replaced-but-unreferenced old files) are excluded, so the export count and
  /// the packed content match the custom-fonts page instead of the raw file
  /// total (root fix for "2 fonts shown as 7"). System fonts, whose catalog
  /// entries point outside custom_fonts/, are excluded because no file travels.
  /// Returned paths keep their original (as-stored) form, deduped by their
  /// forward-slash-normalized value.
  Future<List<String>> _referencedFontFiles() async {
    final String? root = _fontsRootDirectory;
    if (root == null) return const <String>[];
    final Directory rootDir = Directory(root);
    if (!await rootDir.exists()) return const <String>[];
    final String rootNorm = rootDir.path.replaceAll(r'\', '/');
    final Set<String> seen = <String>{};
    final List<String> result = <String>[];
    for (final String key in <String>[
      _fontCatalogPrefKey,
      ..._legacyFontPrefKeys,
    ]) {
      final String? json = await _db.getPref(key);
      if (json == null || json.isEmpty) continue;
      for (final String path in _fontPathsFromPrefJson(json)) {
        if (path.isEmpty) continue;
        if (!_isUnderRoot(path, rootNorm)) continue;
        if (!await File(path).exists()) continue;
        if (seen.add(path.replaceAll(r'\', '/'))) result.add(path);
      }
    }
    return result;
  }

  /// Extracts font-file `path` strings from a persisted font pref [json]: the
  /// canonical catalog `{version, fonts:[{id, name, path}]}` or a legacy list
  /// `[{name, path, enabled}]`. A malformed value yields nothing rather than
  /// throwing (a corrupt pref never aborts an export summary).
  static Iterable<String> _fontPathsFromPrefJson(String json) sync* {
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return;
    }
    final Iterable<dynamic>? entries =
        decoded is Map && decoded['fonts'] is List
            ? decoded['fonts'] as List<dynamic>
            : decoded is List
                ? decoded
                : null;
    if (entries == null) return;
    for (final dynamic e in entries) {
      if (e is Map && e['path'] is String) yield e['path'] as String;
    }
  }

  /// Packs ONLY the custom-font files the catalog references (see
  /// [_referencedFontFiles]) into [into] under the `custom_fonts/` prefix, keyed
  /// by each file's path relative to the fonts root (mirrors [_collectTreeFiles]
  /// so import restores identically). Orphan/temp leftovers are skipped so the
  /// backup carries only the fonts the user manages, and the archive font-file
  /// count matches the export preview.
  Future<void> _collectReferencedFontFiles(Map<String, String> into) async {
    final String? root = _fontsRootDirectory;
    if (root == null) return;
    for (final String abs in await _referencedFontFiles()) {
      final String rel = p.relative(abs, from: root).replaceAll(r'\', '/');
      into[p.posix.join(_fontsPrefix, rel)] = abs;
    }
  }

  Future<int> _countLocalAudioDbs() async {
    final Directory root = Directory(_dbDirectory);
    if (!await root.exists()) return 0;
    int n = 0;
    await for (final FileSystemEntity e in root.list()) {
      if (e is File && _localAudioDbOnly.hasMatch(p.basename(e.path))) n++;
    }
    return n;
  }

  /// Create a backup ZIP file at [outputPath].
  ///
  /// [categories] selects which optional file trees are packed. A null set
  /// (default) packs every tree this service was constructed with - the legacy
  /// all-in export, so existing callers are unchanged. A non-null set packs
  /// ONLY the listed trees; an omitted tree is skipped (its root treated as if
  /// it carried no content), exactly the same as constructing the service
  /// without that root. The database (`hibiki.db`) is always included
  /// regardless, since it holds every table's metadata. [BackupMeta] still
  /// records the source roots of the trees that were actually packed so import
  /// can rebase them; an omitted tree's root is left null in the meta.
  ///
  /// [bookKeys] optionally restricts the export to specific books (TODO-1195
  /// part A): null (default) exports every book (legacy); a non-null set exports
  /// ONLY those books — both their `epub_books` records (every unselected book's
  /// row is stripped from the DB copy) AND their `hoshi_books/` content. Other
  /// categories (dictionaries / statistics / settings / videos / local audio)
  /// are unaffected. When the [BackupCategory.books] category itself is excluded
  /// no book records or content travel at all, regardless of [bookKeys].
  ///
  /// [videoKeys] is the per-video analogue (by `video_books.book_uid`): null
  /// (default) exports every video (legacy); a non-null set exports ONLY those
  /// videos — both their `video_books` records (every unselected row is stripped
  /// from the DB copy so restore never resurrects a "ghost video" with no file)
  /// AND their `videos/` content. Ignored when the [BackupCategory.videos]
  /// category itself is excluded (then no video rows or files travel at all).
  ///
  /// [onProgress] 报打包阶段的确定进度（0..1，已写入字节 / 待打包总字节）。它只在
  /// 真正写 zip 时才开始走 —— 之前的 VACUUM INTO、按分类裁剪行、枚举待打包文件
  /// 都没有可分的量，调用方在收到第一次回调前应显示不确定动画。
  Future<BackupMeta> createBackup(
    String outputPath, {
    Set<BackupCategory>? categories,
    Set<String>? bookKeys,
    Set<String>? videoKeys,
    void Function(double progress)? onProgress,
    void Function(List<String> names)? onDictionariesSkipped,
  }) async {
    bool wants(BackupCategory c) =>
        categories == null || categories.contains(c);
    final tmpDir = await Directory.systemTemp.createTemp('hibiki_backup_');
    try {
      final cleanDbPath = p.join(tmpDir.path, _dbName);
      try {
        final safePath =
            cleanDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
        await _db.customStatement("VACUUM INTO '$safePath'");
      } catch (e, st) {
        // HBK-AUDIT-028: do NOT swallow the VACUUM INTO failure. The original
        // reason (disk full, locked, read-only temp, unsupported SQLite) is
        // the only diagnostic we have, so surface it before falling back.
        debugPrint('BackupService: VACUUM INTO failed, '
            'falling back to checkpoint+copy: $e\n$st');
        // Best-effort fallback: flush the WAL into the main DB file, then copy.
        // A raw copy of a still-open WAL database cannot be made fully torn-free
        // from Dart (that needs the SQLite C backup API or a closed DB); the
        // TRUNCATE checkpoint substantially reduces the window. We do an extra
        // PASSIVE checkpoint after the truncate to flush any frames committed
        // between the two awaits before reading bytes.
        await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        await _db.customStatement('PRAGMA wal_checkpoint(PASSIVE)');
        await File(_dbPath).copy(cleanDbPath);
      }

      // Strip sync credentials from the copy before it leaves the device.
      // The backup ZIP is shared/saved anywhere the user picks, and the
      // preferences table holds OAuth refresh tokens and FTP/SFTP/WebDAV/SMB/
      // server passwords (base64 = encoding, not encryption). VACUUM after the
      // delete so the secrets are not recoverable from freelist pages.
      // (HBK-AUDIT-012)
      final Directory? dictionaryResourceRoot =
          _dictionaryResourceDirectory == null
              ? null
              : Directory(_dictionaryResourceDirectory);
      // Full-data backup includes dictionary resources whenever they exist on
      // disk — no longer gated on dictionary-sync being enabled (the user asked
      // for everything). Still strip dictionary DB rows when the resource files
      // are absent, so the restore never resurrects un-queryable ghost
      // dictionaries.
      // Honor the category selection: when the user unticked Dictionaries,
      // exclude them entirely (and strip their DB rows below) even if the
      // resource files are present on disk.
      // BUG-2193：判据从「全表 AND 门」换成「逐本分区」。以前一条幽灵行就让全部
      // 词典不打包（且静默），用户勾了词典却拿到一个只有 db 的 zip。
      final bool wantsDictionary = wants(BackupCategory.dictionary);
      final _DictionaryPackPlan dictionaryPlan = wantsDictionary
          ? await _planDictionaryPack(dictionaryResourceRoot)
          : const _DictionaryPackPlan.empty();
      final bool includeDictionary =
          wantsDictionary && dictionaryPlan.packable.isNotEmpty;
      // Whether the "book content" category is packed. When it is NOT, the
      // hoshi_books/ tree is skipped below AND the epub_books rows must be
      // stripped from the DB copy — otherwise a restore/merge would insert book
      // records whose content files never travelled = un-openable "ghost" books
      // (TODO-1195 part C). This keeps the switch consistent: a book that isn't
      // packed never appears after import.
      final bool includeBooks = wants(BackupCategory.books);
      await _stripCredentials(tmpDir.path);
      if (!wantsDictionary) {
        // 用户没勾词典 → 整表清空（行为不变）。
        await _stripDictionaryState(tmpDir.path);
      } else if (dictionaryPlan.packable.isEmpty) {
        // 勾了，但一本都打不出来 → 与上同（避免恢复端造出全是幽灵的词典库）。
        await _stripDictionaryState(tmpDir.path);
      } else {
        // 勾了且有得打 → **只**删缺文件的那几行，其余词典照常出包。
        await _stripGhostDictionaryRows(tmpDir.path, dictionaryPlan.ghosts);
      }
      // 无论哪条分支，跳过的词典都必须让调用方知道——这正是本 bug 里
      // 「导出报成功、包里没词典」的那半个真相。
      if (wantsDictionary && dictionaryPlan.ghosts.isNotEmpty) {
        onDictionariesSkipped?.call(
          List<String>.unmodifiable(dictionaryPlan.ghosts),
        );
      }
      // Which books' records survive in the exported DB copy:
      //  - book content unticked      → keep NONE (strip every epub_books row).
      //  - a per-book selection given  → keep ONLY the selected book_keys.
      //  - otherwise                   → keep all (null = legacy full export).
      final Set<String>? retainBookKeys =
          !includeBooks ? const <String>{} : bookKeys; // null = every book
      if (retainBookKeys != null) {
        await _retainBooks(tmpDir.path, retainBookKeys);
      }
      // Which video records survive in the exported DB copy — mirrors books:
      //  - video category unticked     → keep NONE (strip every video_books row).
      //  - a per-video selection given → keep ONLY the selected book_uids.
      //  - otherwise                   → keep all (null = legacy full export).
      // Stripping the row (not just skipping the file) is what stops a restore
      // from resurrecting a "ghost video" whose file never travelled.
      final bool includeVideos = wants(BackupCategory.videos);
      final Set<String>? retainVideoKeys =
          !includeVideos ? const <String>{} : videoKeys; // null = every video
      if (retainVideoKeys != null) {
        await _retainVideos(tmpDir.path, retainVideoKeys);
      }
      // Audiobooks mirror books/videos (BUG-781): unticking the category strips
      // every `audiobooks` row from the DB COPY so a restore never resurrects a
      // ghost audiobook whose audio never travelled. (No per-audiobook selection
      // yet, so it is all-or-nothing.)
      final bool includeAudiobooks = wants(BackupCategory.audiobooks);
      if (!includeAudiobooks) {
        await _retainAudiobooks(tmpDir.path, const <String>{});
      }

      // TODO-1193: the four data categories (progress / statistics / settings /
      // profiles) live only in the DB blob, so when the user unticks any of
      // them the matching rows are DELETEd from the standalone DB COPY (never
      // the live user DB). Excluding settings/profiles is made safe on import
      // by _reapplyExcludedSettingsLayers preserving the LOCAL layer from bak.
      final bool includeProgress = wants(BackupCategory.progress);
      final bool includeStatistics = wants(BackupCategory.statistics);
      final bool includeSettings = wants(BackupCategory.settings);
      final bool includeProfiles = wants(BackupCategory.profiles);
      if (!includeProgress ||
          !includeStatistics ||
          !includeSettings ||
          !includeProfiles) {
        await _stripExcludedDataCategories(
          tmpDir.path,
          stripProgress: !includeProgress,
          stripStatistics: !includeStatistics,
          stripSettings: !includeSettings,
          stripProfiles: !includeProfiles,
        );
      }

      // BUG-828: strip the "orphan" user-data tables that NO backup category
      // governed — before this they leaked unconditionally into every backup
      // (a "dictionary + local-audio only" export still carried the user's
      // collections, shelf, tags, search history and deletion tombstones).
      // Gated on the CATEGORY choice, not on row-resolution: a full export keeps
      // every collection/tag/tombstone (so the cross-device merge-union in
      // [BackupMergeEngine] still propagates memberships whose book lives on
      // another device), while a content-excluding export drops the rows that
      // belong to the unticked content.
      await _stripOrphanUserDataTables(
        tmpDir.path,
        includeBooks: includeBooks,
        includeVideos: includeVideos,
        includeStatistics: includeStatistics,
      );

      // BUG-816: content-registry preference rows follow their OWNING content
      // category, not `settings` — strip favorites when `books` is unticked,
      // the font registry when `fonts` is, and the local-audio registry (incl.
      // the localAudio entries of `audio_source_configs`) when `localAudio` is.
      await _stripExcludedContentRegistry(
        tmpDir.path,
        stripFavorites: !includeBooks,
        stripFonts: !wants(BackupCategory.fonts),
        stripLocalAudio: !wants(BackupCategory.localAudio),
      );

      final books = await _db.getAllEpubBooks();
      final stats = await _db.getAllReadingStatistics();
      // The count reported to the import confirm dialog must reflect what is
      // actually exported, not the live library — a book whose record was
      // stripped above must not be counted (TODO-1195 part C/A).
      final int exportedBookCount = retainBookKeys == null
          ? books.length
          : books
              .where((EpubBookRow b) => retainBookKeys.contains(b.bookKey))
              .length;

      // Build the flat "zip-path → disk-path" map, then stream every file into
      // the ZIP off the UI isolate. The old path read each file fully into a
      // single in-memory Archive and ran a synchronous ZipEncoder().encode() on
      // the UI isolate — that froze the app (ANR) on any non-trivial library.
      final Map<String, String> files = <String, String>{
        _dbName: cleanDbPath,
      };
      Map<String, String> videoFiles = const <String, String>{};
      if (includeVideos) {
        videoFiles = await _collectVideoFiles(files, videoKeys: videoKeys);
      }
      if (wants(BackupCategory.localAudio)) {
        await _collectLocalAudioFiles(files);
      }

      // TODO-1261: the confirm dialog's "N books" must count EVERY shelf item
      // that will travel usably, not just EPUBs. A video book travels usably iff
      // it is selected (video category on + not filtered out by [videoKeys]) AND
      // either its file was packed (in [videoFiles]) or it is a streaming book
      // (http(s) URL, self-contained) — the SAME reachability the merge/preview
      // enforce, so a video-only backup no longer reports "0 books" while 19
      // videos land, and an unticked/deselected video is not counted.
      bool videoTravels(VideoBookRow v) {
        if (!includeVideos) return false;
        if (videoKeys != null && !videoKeys.contains(v.bookUid)) return false;
        return _isStreamingVideoPath(v.videoPath) ||
            videoFiles.containsKey(v.videoPath);
      }

      final List<VideoBookRow> allVideos = await _db.allVideoBooks();
      final int usableVideoCount = allVideos.where(videoTravels).length;
      // Rows that actually REMAIN in the exported DB blob after [_retainVideos]:
      // 0 when video was unticked (all stripped), all rows when video is on with
      // no per-video filter, else the selected subset. Recorded in meta so the
      // import dialog can offer the video toggle even when NO video files were
      // packed (streaming videos), independent of [usableVideoCount] which counts
      // only videos whose media travels (BUG-779).
      final int blobVideoBookCount = retainVideoKeys == null
          ? allVideos.length
          : allVideos
              .where((VideoBookRow v) => retainVideoKeys.contains(v.bookUid))
              .length;
      // Audiobook rows remaining in the exported DB blob after [_retainAudiobooks]
      // (0 when unticked → all stripped). Recorded so import can offer the
      // audiobooks toggle even with no packed audiobook files (BUG-781).
      final int blobAudiobookCount =
          includeAudiobooks ? (await _db.getAllAudiobooks()).length : 0;

      // "Statistics records" spans reading + video + mining buckets, not reading
      // alone, so a video-watcher's backup no longer reports "0 statistics".
      final int totalStatsCount = includeStatistics
          ? stats.length +
              await _countRows('video_watch_statistics') +
              await _countRows('mining_statistics')
          : 0;

      // Record the SOURCE-device content roots so import can rebase the stored
      // absolute paths (epubPath/extractDir/coverPath/audioRoot/...) onto the
      // importing device's roots. Null roots → legacy db-only backup.
      final meta = BackupMeta(
        appVersion: _appVersion,
        schemaVersion: _db.schemaVersion,
        createdAt: DateTime.now(),
        bookCount: exportedBookCount + usableVideoCount,
        // Honest to what actually travels: a statistics-excluded backup reports
        // zero even though the live library has stats (mirrors bookCount).
        statsCount: totalStatsCount,
        // Only record a tree's source root when that tree is actually packed,
        // so import never rebases stored paths against a tree the backup never
        // carried (a no-op for the missing tree either way, but keeping the
        // meta honest avoids surprising the restore code).
        booksRoot: wants(BackupCategory.books) ? _booksRootDirectory : null,
        audiobooksRoot:
            wants(BackupCategory.audiobooks) ? _audiobooksRootDirectory : null,
        fontsRoot: wants(BackupCategory.fonts) ? _fontsRootDirectory : null,
        localAudioRoot: wants(BackupCategory.localAudio) ? _dbDirectory : null,
        videoFiles: videoFiles,
        videoBookCount: blobVideoBookCount,
        audiobookCount: blobAudiobookCount,
        // Record every unticked category by enum name so import knows a layer is
        // empty BY CHOICE (vs a genuinely empty DB). Only settings/profiles are
        // acted on at import; the rest is diagnostic / future-proofing.
        excludedCategories: <String>{
          for (final BackupCategory c in BackupCategory.values)
            if (!wants(c)) c.name,
        },
      );

      if (includeDictionary) {
        await _collectDictionaryTrees(
            dictionaryResourceRoot!, dictionaryPlan.packable, files);
      }
      if (_booksRootDirectory != null && includeBooks) {
        if (bookKeys == null) {
          // Legacy full export: pack the whole books tree.
          await _collectTreeFiles(
              Directory(_booksRootDirectory), _booksPrefix, files);
        } else {
          // Per-book export (TODO-1195 part A): pack ONLY the selected books'
          // content, keyed by each file's path relative to the books root so
          // the archive layout matches the full-tree export (import restores
          // the whole hoshi_books/ prefix onto this device's root either way).
          await _collectSelectedBookFiles(
              bookKeys, books, _booksRootDirectory, files);
        }
      }
      if (_audiobooksRootDirectory != null &&
          wants(BackupCategory.audiobooks)) {
        await _collectTreeFiles(
            Directory(_audiobooksRootDirectory), _audiobooksPrefix, files);
      }
      if (_fontsRootDirectory != null && wants(BackupCategory.fonts)) {
        await _collectReferencedFontFiles(files);
      }

      final String metaJson =
          const JsonEncoder.withIndent('  ').convert(meta.toJson());
      // 分母：files 已经是一张平铺的 archivePath→磁盘路径表，逐项求大小即可。
      final int totalBytes = _totalSourceBytes(files);
      int writtenBytes = 0;
      await _writeBackupZipInIsolate(
        outputPath: outputPath,
        metaName: _metaName,
        metaJson: metaJson,
        archivePathToSource: files,
        onBytes: onProgress == null
            ? null
            : (int deltaBytes) {
                writtenBytes += deltaBytes;
                final double fraction = writtenBytes / totalBytes;
                onProgress(fraction > 1.0 ? 1.0 : fraction);
              },
      );

      return meta;
    } finally {
      await _deleteDirectoryIfPresent(tmpDir);
    }
  }

  static Future<void> _deleteDirectoryIfPresent(Directory directory) async {
    await deleteDirectoryWithRetry(
      exists: directory.exists,
      delete: () => directory.delete(recursive: true),
      sleep: (int ms) => Future<void>.delayed(Duration(milliseconds: ms)),
      isWindows: Platform.isWindows,
    );
  }

  /// Strips device-local config and credentials from the standalone DB copy in
  /// [dbDirectory] before it leaves the device. Opened via [FushiDatabase]
  /// (the copy is already at the current schema, so no migration runs).
  ///
  /// What counts as "must not leave this device" is [PrefRedactionPolicy] —
  /// the single predicate shared by all three outbound channels (backup zip,
  /// Profile snapshot, Profile share JSON) and by the import-side preserve
  /// ([_readDeviceLocalPrefs]). It subsumes the old two layers here (the
  /// `deviceLocalPrefKeys` whitelist + a `sync_%` secret-shaped LIKE sweep);
  /// the sweep was strictly narrower — being anchored on the `sync_` prefix it
  /// missed every credential belonging to another subsystem
  /// (`media_source_secret_*`, `qb_connection_config`, the `*_api_key` family).
  ///
  /// **Two tables, both required.** Stripping `preferences` alone was the leak:
  /// `ProfileRepository.snapshotCurrentSettings` copies *every* Drift pref into
  /// `profile_settings` as `category='pref'` rows, and `profiles` is ticked by
  /// default on export (`defaultBackupExportCategories()`). So on any device
  /// that ever switched profiles, the credentials deleted from `preferences`
  /// were still sitting in the exported `hibiki.db` under `profile_settings`.
  /// The snapshot writer/reader now applies the same policy
  /// ([ProfileKeys.isExcludedPref]) so no NEW credential rows are produced, but
  /// pre-existing snapshots on an upgrading device still carry them — this
  /// strip is what keeps those out of the exported copy, with no migration.
  ///
  /// VACUUM + checkpoint so values are not recoverable from freelist/WAL pages.
  static Future<void> _stripCredentials(String dbDirectory) async {
    final db = FushiDatabase(dbDirectory);
    try {
      final Map<String, String> allPrefs = await db.getAllPrefs();
      final List<String> redactedPrefKeys = allPrefs.keys
          .where(PrefRedactionPolicy.isDeviceLocalOrCredential)
          .toList(growable: false);
      if (redactedPrefKeys.isNotEmpty) {
        await (db.delete(db.preferences)
              ..where((t) => t.key.isIn(redactedPrefKeys)))
            .go();
      }
      await _stripCredentialRowsFromProfileSnapshots(db);
      // BUG-816: device-local tables (LAN pairing token + sync baselines) live
      // outside `preferences`, so the key sweeps above never touched them and a
      // shared backup leaked the plaintext pairing `token`. Wipe them from the
      // export copy unconditionally — they are meaningless (or harmful) on any
      // other device and are restored from bak on an overwrite import.
      for (final String table in _deviceLocalTables) {
        await db.customStatement('DELETE FROM $table');
      }
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Deletes the credential-bearing `category='pref'` rows from every Profile
  /// snapshot in the export copy (see [_stripCredentials] for why this table is
  /// a second, independent outbound channel).
  ///
  /// Gated on `category='pref'` on purpose: the `anki` category holds deck /
  /// note-type / field-mapping values and `dictionary_meta` is keyed by
  /// dictionary NAME, so an unfiltered sweep could drop a dictionary that merely
  /// happens to be named e.g. "secret". Only the `pref` rows mirror
  /// `preferences` and are therefore the ones the policy is written for.
  ///
  /// The keys are resolved in Dart (one predicate, no SQL LIKE dialect of it)
  /// and deleted in a single parameterised statement.
  static Future<void> _stripCredentialRowsFromProfileSnapshots(
    FushiDatabase db,
  ) async {
    final List<QueryRow> rows = await db.customSelect(
      'SELECT DISTINCT key FROM profile_settings WHERE category = ?',
      variables: <Variable<Object>>[Variable<String>(profilePrefCategory)],
    ).get();
    final List<String> redacted = rows
        .map((QueryRow row) => row.read<String>('key'))
        .where(PrefRedactionPolicy.isDeviceLocalOrCredential)
        .toList(growable: false);
    if (redacted.isEmpty) return;
    final String placeholders =
        List<String>.filled(redacted.length, '?').join(', ');
    await db.customStatement(
      'DELETE FROM profile_settings '
      'WHERE category = ? AND key IN ($placeholders)',
      <Object>[profilePrefCategory, ...redacted],
    );
  }

  /// `ProfileKeys.categoryPref`. Duplicated as a literal rather than imported so
  /// `backup_service` (which `profile_repository` already imports) does not gain
  /// a back-edge into the profile layer; a test pins the two to stay equal.
  @visibleForTesting
  static const String profilePrefCategory = 'pref';

  /// Removes dictionary rows from the exported DB copy when dictionary sync is
  /// disabled. Keeping DB metadata without matching `dictionaryResources/`
  /// files would restore ghost dictionaries that cannot be queried.
  static Future<void> _stripDictionaryState(String dbDirectory) async {
    final db = FushiDatabase(dbDirectory);
    try {
      await db.clearDictionaryHistory();
      await db.clearAllDictionaryMeta();
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Strips the "orphan" user-data tables that no [BackupCategory] governs from
  /// the standalone DB copy (BUG-828). Before this they leaked unconditionally
  /// into every backup, so a "dictionary + local-audio only" export still
  /// carried the user's collections, shelf, tags, search history and deletion
  /// tombstones.
  ///
  /// The strip is gated on the user's CATEGORY choice, NOT on row-resolution —
  /// this is the crux. A membership can legitimately point at a book that lives
  /// on ANOTHER device: [BackupMergeEngine] reads `media_collections` /
  /// `media_collection_items` / `book_tags` FROM THE BACKUP to propagate the
  /// multi-device union, so a full export must keep them even when the pointed-at
  /// book has no local row. Row-resolution stripping would gut exactly that
  /// feature. Gating on the ticked categories instead means:
  ///   - full export (books + videos ticked) → nothing content-following is
  ///     stripped, the union still travels;
  ///   - content-excluding export → only the rows belonging to the UNTICKED
  ///     content are dropped.
  ///
  /// Groups:
  /// 1. ALWAYS wiped — `search_history_items` and `dictionary_history`: private
  ///    usage traces (search terms / recent lookups + rendered result JSON) with
  ///    no content to follow, never wanted on another device (BUG-832).
  /// 2. CATEGORY-GATED, `media_kind`/`media_type`-keyed rows — collection memberships, shelf
  ///    entries and the per-item deletion markers (`book_tag_membership_tombstones`,
  ///    `sync_deletion_tombstones`) are logical (non-DB-FK) references, so
  ///    stripping a book does NOT cascade to them. When a content category is
  ///    unticked we drop its `media_type` rows explicitly, plus its
  ///    `media_sources` library-root rows (`media_kind` 'book'/'video'; local
  ///    paths that leak the device's folder layout). `srt` has no category,
  ///    but since `srt_books` is never category-stripped a content-excluding
  ///    export drops only srt member/shelf rows that DON'T resolve to an
  ///    `srt_books` row (dangling); a full export keeps every srt row for the
  ///    merge-union. A collection is dropped ONLY when the strip left it with no
  ///    members (tracked via
  ///    [hadMembers]) — a legitimately member-less, tag-only collection is
  ///    preserved (its `collection_tag_mappings` cascade with it if it IS
  ///    dropped). `book_tags` is drained of pool rows no longer referenced by any
  ///    surviving mapping, INCLUDING `collection_tag_mappings` (a tag may label a
  ///    collection without labelling a book); the per-content mapping tables were
  ///    FK-cascade-cleared by [_retainBooks] / [_retainVideos].
  /// 3. CATEGORY-GATED whole-table deletion tombstones — `book_tombstones`
  ///    (books), `statistics_tombstones` (statistics), `collection_member_tombstones`
  ///    (once no book/video content travels). Merge reads the IMPORTING device's
  ///    OWN tombstones (not the backup's), so this never weakens resurrection
  ///    suppression.
  ///
  /// Runs AFTER [_retainBooks] / [_retainVideos] so tag-mapping cascades and the
  /// pool drain observe the final content set. Every DELETE is FK-safe (verified
  /// with `foreign_key_check` against a real v44 export copy).
  static Future<void> _stripOrphanUserDataTables(
    String dbDirectory, {
    required bool includeBooks,
    required bool includeVideos,
    required bool includeStatistics,
  }) async {
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      // (1) Always-wipe: search history and recent dictionary lookups are
      // private usage traces (BUG-832) — no content to follow, never wanted on
      // another device (dictionary_history also stores each lookup's rendered
      // result JSON, so it is both private and bulky).
      await db.customStatement('DELETE FROM search_history_items');
      await db.customStatement('DELETE FROM dictionary_history');

      // Snapshot which collections had members BEFORE the gated member strip so
      // we can drop only the ones the strip emptied (never an always-empty,
      // tag-only collection).
      final hadMembersRows = await db
          .customSelect(
              'SELECT DISTINCT collection_id AS id FROM media_collection_items')
          .get();
      final List<int> hadMembers =
          hadMembersRows.map((r) => r.data['id'] as int).toList();

      // (2) Category-gated content rows. Each unticked content category drops
      // its own `media_type`-keyed rows across the shared tables (collection
      // memberships, shelf entries, and the per-item deletion markers). srt has
      // no category (always exported), so its rows always stay.
      Future<void> stripForMediaType(MediaKind mediaType) async {
        for (final String table in const <String>[
          'media_collection_items',
          'shelf_entries',
          'book_tag_membership_tombstones',
          'sync_deletion_tombstones',
        ]) {
          await db.customStatement(
              'DELETE FROM $table WHERE media_type = ?', [mediaType.dbValue]);
        }
      }

      if (!includeBooks) await stripForMediaType(MediaKind.epub);
      if (!includeVideos) await stripForMediaType(MediaKind.video);
      // media_sources holds local library ROOT PATHS (e.g. D:/books, D:/videos)
      // — a privacy leak in a content-excluding backup and useless without the
      // content it indexes (BUG-832). Its `media_kind` is 'book' | 'video'; drop
      // the kind whose category is unticked. `epub_books`/`video_books.source_id
      // → media_sources` is `onDelete: setNull` and those content rows are
      // already stripped when the category is excluded, so this is FK-safe.
      if (!includeBooks) {
        await db.customStatement(
            "DELETE FROM media_sources WHERE media_kind = 'book'");
      }
      if (!includeVideos) {
        await db.customStatement(
            "DELETE FROM media_sources WHERE media_kind = 'video'");
      }
      // srt has no category checkbox, but `srt_books` is never category-stripped,
      // so a srt member/shelf row whose `entry_key` has no `srt_books.uid` match
      // is genuinely dangling (deleted, or cross-device srt content absent from
      // this backup). In a CONTENT-EXCLUDING export drop those to honour
      // "collections carry only exported content"; a FULL export keeps them so
      // the merge-union still propagates cross-device srt memberships.
      if (!includeBooks || !includeVideos) {
        // P5：'srt' 改参数绑定（值来自 MediaKind.srt.dbValue，串不变）。
        const String srtDangling = 'media_type = ? AND entry_key NOT IN '
            '(SELECT uid FROM srt_books WHERE uid IS NOT NULL)';
        await db.customStatement(
            'DELETE FROM media_collection_items WHERE $srtDangling',
            [MediaKind.srt.dbValue]);
        await db.customStatement('DELETE FROM shelf_entries WHERE $srtDangling',
            [MediaKind.srt.dbValue]);
      }
      // Drop collections the strip emptied — but keep always-empty tag-only
      // collections (a member-less collection is a valid tag-union carrier).
      if (hadMembers.isNotEmpty && (!includeBooks || !includeVideos)) {
        final String ids = hadMembers.join(',');
        await db.customStatement(
          'DELETE FROM media_collections WHERE id IN ($ids) AND id NOT IN '
          '(SELECT DISTINCT collection_id FROM media_collection_items)',
        );
      }
      // v77：标签映射是逻辑外键，被裁剪内容的映射行不再随 FK cascade 消失——
      // 先按「宿主在本份导出里已不存在」显式收敛（与旧 cascade 语义精确等价，
      // 且顺带清掉任何历史悬垂行），再排干无引用的共享标签池（合集可以只有
      // 标签没有成员，drain 必须以统一表为准，否则 collection-only 标签会被
      // 误排掉）。
      await db.customStatement(
        'DELETE FROM tag_assignments WHERE '
        "(media_kind = 'epub' AND entry_key NOT IN "
        '(SELECT book_key FROM epub_books)) '
        "OR (media_kind = 'srt' AND entry_key NOT IN "
        '(SELECT uid FROM srt_books)) '
        "OR (media_kind = 'video' AND entry_key NOT IN "
        '(SELECT book_uid FROM video_books)) '
        "OR (media_kind = 'collection' AND entry_key NOT IN "
        '(SELECT CAST(id AS TEXT) FROM media_collections)) '
        "OR (media_kind = 'game' AND entry_key NOT IN "
        '(SELECT id FROM galgames))',
      );
      await db.customStatement(
        'DELETE FROM book_tags WHERE id NOT IN ('
        'SELECT tag_id FROM tag_assignments)',
      );

      // (3) Category-gated deletion tombstones.
      if (!includeBooks) {
        await db.customStatement('DELETE FROM book_tombstones');
      }
      if (!includeStatistics) {
        await db.customStatement('DELETE FROM statistics_tombstones');
      }
      if (!includeBooks && !includeVideos) {
        // Collection member-removal markers carry no signal once no book/video
        // content travels.
        await db.customStatement('DELETE FROM collection_member_tombstones');
      }

      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// BUG-816: strips the content-registry preference rows whose OWNING content
  /// category the user unticked, from the standalone export DB copy. Each key is
  /// governed by the feature it belongs to, NOT `settings`:
  ///  - favorites (`favorite_sentences`)          -> `books`
  ///  - font catalog + legacy font prefs          -> `fonts`
  ///  - local-audio registry (`local_audio_dbs`)  -> `localAudio`
  ///  - `audio_source_configs` localAudio entries -> `localAudio` (option B:
  ///    only the `kind == 'localAudio'` entries carrying this device's absolute
  ///    `.db` paths are dropped; remote audio-source entries are kept).
  /// Mirrored on an overwrite import by [_reapplyExcludedContentRegistry].
  static Future<void> _stripExcludedContentRegistry(
    String dbDirectory, {
    required bool stripFavorites,
    required bool stripFonts,
    required bool stripLocalAudio,
  }) async {
    if (!stripFavorites && !stripFonts && !stripLocalAudio) return;
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      if (stripFavorites) {
        await db.customStatement(
            "DELETE FROM preferences WHERE key = '$_favoriteSentencesPrefKey'");
      }
      if (stripFonts) {
        for (final String k in <String>[
          _fontCatalogPrefKey,
          ..._legacyFontPrefKeys,
        ]) {
          await db.customStatement("DELETE FROM preferences WHERE key = '$k'");
        }
      }
      if (stripLocalAudio) {
        await db.customStatement(
            "DELETE FROM preferences WHERE key = '$_localAudioDbsPrefKey'");
        await _filterLocalAudioFromAudioSourceConfigs(db);
      }
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Rewrites the `audio_source_configs` pref (BUG-816 option B): removes only
  /// its `kind == 'localAudio'` entries (they carry this device's absolute `.db`
  /// paths), keeping remote audio-source entries. Preserves the [PrefCodec] tag
  /// on write. No-op if the pref is absent, unparseable, or has no local-audio
  /// entry.
  static Future<void> _filterLocalAudioFromAudioSourceConfigs(
      FushiDatabase db) async {
    final rows = await db
        .customSelect('SELECT value FROM preferences '
            "WHERE key = '$_audioSourceConfigsPrefKey'")
        .get();
    if (rows.isEmpty) return;
    final String? raw = rows.first.read<String?>('value');
    if (raw == null) return;
    final dynamic decoded = PrefCodec.decodeUntyped(raw);
    if (decoded is! List) return;
    final List<dynamic> kept = decoded
        .where((dynamic e) => !(e is Map && e['kind'] == 'localAudio'))
        .toList();
    if (kept.length == decoded.length) return; // no local-audio entry to strip
    if (kept.isEmpty) {
      await db.customStatement('DELETE FROM preferences '
          "WHERE key = '$_audioSourceConfigsPrefKey'");
      return;
    }
    await db.customStatement(
      'UPDATE preferences SET value = ? WHERE key = ?',
      <Object?>[PrefCodec.encode(kept), _audioSourceConfigsPrefKey],
    );
  }

  /// Walks [root] and adds every file to [into] keyed by its zip path
  /// (`<archivePrefix>/<relative>`, always posix separators). Does not read file
  /// contents — only paths — so it is cheap regardless of tree size.
  static Future<void> _collectTreeFiles(
    Directory root,
    String archivePrefix,
    Map<String, String> into,
  ) async {
    if (!await root.exists()) return;
    await for (final FileSystemEntity entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final String relativePath = p.relative(entity.path, from: root.path);
      final String archivePath =
          p.posix.join(archivePrefix, relativePath.replaceAll(r'\', '/'));
      into[archivePath] = entity.path;
    }
  }

  /// Packs ONLY the selected [bookKeys]' book content into [into] (per-book
  /// export, TODO-1195 part A). For each selected [EpubBookRow] its extracted
  /// content directory subtree plus the epub file and cover file are added,
  /// each keyed by its path RELATIVE to [booksRootDirectory] under the
  /// `hoshi_books/` prefix — identical to what the full-tree export would emit
  /// for those files, so import (which restores the whole prefix) is unchanged.
  /// A book whose paths are not under the books root, or whose files are gone,
  /// is silently skipped (its DB row is likewise stripped by [_retainBooks]).
  static Future<void> _collectSelectedBookFiles(
    Set<String> bookKeys,
    List<EpubBookRow> allBooks,
    String booksRootDirectory,
    Map<String, String> into,
  ) async {
    final Directory booksRoot = Directory(booksRootDirectory);
    if (!await booksRoot.exists()) return;
    final String rootNorm = booksRoot.path.replaceAll(r'\', '/');
    for (final EpubBookRow b in allBooks) {
      if (!bookKeys.contains(b.bookKey)) continue;
      // The book's extracted directory subtree (epub + html/images/fonts +
      // in-tree cover) — the bulk of its content.
      await _collectSubtreeUnderRoot(
          b.extractDir, booksRootDirectory, rootNorm, into);
      // The epub file and cover file explicitly, in case either lives directly
      // under the books root rather than inside extractDir.
      await _collectSingleFileUnderRoot(
          b.epubPath, booksRootDirectory, rootNorm, into);
      if (b.coverPath != null) {
        await _collectSingleFileUnderRoot(
            b.coverPath!, booksRootDirectory, rootNorm, into);
      }
    }
  }

  /// Walks [subtreePath] and adds every file to [into] keyed by its path
  /// relative to [booksRootDirectory] under the `hoshi_books/` prefix. No-op
  /// when the subtree is missing or is not located under the books root
  /// ([rootNorm] is the forward-slash-normalized root, precomputed by the
  /// caller). Used by per-book export to pack one book's extracted directory.
  static Future<void> _collectSubtreeUnderRoot(
    String subtreePath,
    String booksRootDirectory,
    String rootNorm,
    Map<String, String> into,
  ) async {
    final Directory dir = Directory(subtreePath);
    if (!await dir.exists()) return;
    if (!_isUnderRoot(subtreePath, rootNorm)) return;
    await for (final FileSystemEntity entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      _addFileRelativeToRoot(entity.path, booksRootDirectory, rootNorm, into);
    }
  }

  /// Adds one file at [filePath] to [into] keyed by its path relative to the
  /// books root under the `hoshi_books/` prefix. No-op when the file is missing
  /// or not under the root. Idempotent via the map key (a file already added by
  /// the subtree walk is simply overwritten with the same value).
  static Future<void> _collectSingleFileUnderRoot(
    String filePath,
    String booksRootDirectory,
    String rootNorm,
    Map<String, String> into,
  ) async {
    if (!_isUnderRoot(filePath, rootNorm)) return;
    if (!await File(filePath).exists()) return;
    _addFileRelativeToRoot(filePath, booksRootDirectory, rootNorm, into);
  }

  /// Whether [path] is located within [rootNorm] (a forward-slash-normalized
  /// directory), using a separator-boundary prefix test so `/a/books_extra` is
  /// not treated as under `/a/books`.
  static bool _isUnderRoot(String path, String rootNorm) {
    final String pNorm = path.replaceAll(r'\', '/');
    return pNorm == rootNorm || pNorm.startsWith('$rootNorm/');
  }

  /// Maps [filePath] to its `hoshi_books/<relative-to-root>` archive key and
  /// records it in [into]. Mirrors [_collectTreeFiles]'s keying so a per-book
  /// export and a full-tree export produce identical archive paths.
  static void _addFileRelativeToRoot(
    String filePath,
    String booksRootDirectory,
    String rootNorm,
    Map<String, String> into,
  ) {
    final String relativePath = p.relative(filePath, from: booksRootDirectory);
    final String archivePath =
        p.posix.join(_booksPrefix, relativePath.replaceAll(r'\', '/'));
    into[archivePath] = filePath;
  }

  /// Adds every local-audio pronunciation database file (`local_audio_*.db`
  /// plus its `-wal`/`-shm` siblings) from the support/database directory to
  /// [into], keyed by its zip path (`localAudio/<filename>`). Only files
  /// matching [_localAudioFileName] are packed, so `hibiki.db`, sidecars and
  /// every other support file stay out of the backup (TODO-941).
  Future<void> _collectLocalAudioFiles(Map<String, String> into) async {
    final Directory root = Directory(_dbDirectory);
    if (!await root.exists()) return;
    await for (final FileSystemEntity entity in root.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (!_localAudioFileName.hasMatch(name)) continue;
      into[p.posix.join(_localAudioPrefix, name)] = entity.path;
    }
  }

  /// Packs the referenced video files into [into] under the `videos/` prefix.
  /// [videoKeys] (by `video_books.book_uid`) restricts packing to the selected
  /// videos (per-video export); null packs every video (legacy full export).
  Future<Map<String, String>> _collectVideoFiles(
    Map<String, String> into, {
    Set<String>? videoKeys,
  }) async {
    final Map<String, String> sourcePathToArchiveRelative = <String, String>{};
    final Set<String> usedArchiveRelativePaths = <String>{};
    final List<VideoBookRow> rows = await _db.allVideoBooks();
    for (final VideoBookRow row in rows) {
      if (videoKeys != null && !videoKeys.contains(row.bookUid)) continue;
      int index = 0;
      for (final String videoPath in _videoPathsForRow(row)) {
        if (videoPath.isEmpty ||
            sourcePathToArchiveRelative.containsKey(videoPath)) {
          continue;
        }
        final File videoFile = File(videoPath);
        if (!await videoFile.exists()) continue;
        final String relativePath = _videoArchiveRelativePath(
          bookUid: row.bookUid,
          sourcePath: videoPath,
          index: index,
          used: usedArchiveRelativePaths,
        );
        sourcePathToArchiveRelative[videoPath] = relativePath;
        into[p.posix.join(_videosPrefix, relativePath)] = videoPath;
        index++;
      }
    }
    return sourcePathToArchiveRelative;
  }

  static Iterable<String> _videoPathsForRow(VideoBookRow row) sync* {
    yield row.videoPath;
    final String? playlistJson = row.playlistJson;
    if (playlistJson == null || playlistJson.isEmpty) return;
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return;
      for (final dynamic entry in decoded) {
        if (entry is! Map) continue;
        final Object? path = entry['path'];
        if (path is String) yield path;
      }
    } catch (_) {
      return;
    }
  }

  static String _videoArchiveRelativePath({
    required String bookUid,
    required String sourcePath,
    required int index,
    required Set<String> used,
  }) {
    final String folder = _safeArchiveSegment(bookUid);
    final String basename = _safeArchiveSegment(
      _crossPlatformBasename(sourcePath).isEmpty
          ? 'video'
          : _crossPlatformBasename(sourcePath),
    );
    String candidate = p.posix.join(folder, '${index + 1}-$basename');
    int suffix = 2;
    while (used.contains(candidate)) {
      candidate = p.posix.join(folder, '${index + 1}-$suffix-$basename');
      suffix++;
    }
    used.add(candidate);
    return candidate;
  }

  static String _crossPlatformBasename(String path) {
    final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
    return sep >= 0 ? path.substring(sep + 1) : path;
  }

  static String _safeArchiveSegment(String value) {
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'item' : safe;
  }

  /// Streams every file in [archivePathToSource] into a ZIP at [outputPath] on a
  /// background isolate, plus [metaJson] as [metaName]. Uses STORE (no deflate):
  /// epub/audio are already compressed and a full library can be GB-scale, so
  /// streaming-store keeps memory flat and the UI isolate free. A mid-way
  /// failure deletes the half-written archive so it is never mistaken for valid.
  /// 待打包总字节。缺失 / 无权限的源按 0 计，与 worker 里 `existsSync` 跳过同口径；
  /// 恒 ≥1 以免空备份除零（与导入侧 [_totalContentBytes] 同款）。
  static int _totalSourceBytes(Map<String, String> archivePathToSource) {
    int total = 0;
    for (final String source in archivePathToSource.values) {
      try {
        final File file = File(source);
        if (file.existsSync()) total += file.lengthSync();
      } catch (_) {
        // 扫描期被删 / 无权限：worker 同样会跳过它，分母不计它。
      }
    }
    return total > 0 ? total : 1;
  }

  static Future<void> _writeBackupZipInIsolate({
    required String outputPath,
    required String metaName,
    required String metaJson,
    required Map<String, String> archivePathToSource,
    void Function(int deltaBytes)? onBytes,
  }) async {
    // 进度回传口：闭包捕获 SendPort（SendPort 可跨 isolate 传递），Isolate.run 的
    // 错误传播与 crash-safety 一字不改。archive 3.6.1 的 addFile 没有 chunk 级
    // 回调，所以粒度只能到「每个文件写完」——对单个超大视频仍会停一段时间。
    ReceivePort? port;
    SendPort? sendPort;
    if (onBytes != null) {
      port = ReceivePort();
      port.listen((dynamic message) {
        if (message is int) onBytes(message);
      });
      sendPort = port.sendPort;
    }
    try {
      await _runBackupZipWorker(
        outputPath: outputPath,
        metaName: metaName,
        metaJson: metaJson,
        archivePathToSource: archivePathToSource,
        sendPort: sendPort,
      );
    } finally {
      port?.close();
    }
  }

  /// [_writeBackupZipInIsolate] 的 worker，**必须留在这个独立作用域里**。
  ///
  /// Dart 按**作用域**分配 Context，闭包序列化时整个 Context 一起发往子 isolate。
  /// 把 `Isolate.run(...)` 内联回调用方，闭包就会连带捕获那里的 `port`
  /// （`_ReceivePortImpl`，native 句柄）和 `onBytes`（一路捕获到 `AppModel` →
  /// `FushiDatabase` → `DynamicLibrary`）—— 两者都不可发送，spawn 当场抛
  /// `Illegal argument in isolate message`，导出备份 100% 失效（BUG-1929）。
  ///
  /// 本函数的 Context 只有下面五个形参，全部可跨 isolate 传递（String / Map /
  /// SendPort）。**别把它内联回去**，也别在这里引用任何外层变量。
  static Future<void> _runBackupZipWorker({
    required String outputPath,
    required String metaName,
    required String metaJson,
    required Map<String, String> archivePathToSource,
    required SendPort? sendPort,
  }) {
    return Isolate.run(() async {
      final ZipFileEncoder encoder = ZipFileEncoder();
      encoder.create(outputPath);
      try {
        final List<int> metaBytes = utf8.encode(metaJson);
        encoder
            .addArchiveFile(ArchiveFile(metaName, metaBytes.length, metaBytes));
        for (final MapEntry<String, String> entry
            in archivePathToSource.entries) {
          final File file = File(entry.value);
          if (!file.existsSync()) continue;
          final int size = file.lengthSync();
          await encoder.addFile(file, entry.key, ZipFileEncoder.STORE);
          sendPort?.send(size);
        }
        encoder.closeSync();
      } catch (_) {
        encoder.closeSync();
        try {
          final File partial = File(outputPath);
          if (partial.existsSync()) partial.deleteSync();
        } catch (_) {
          // best-effort cleanup; rethrow the real export failure below.
        }
        rethrow;
      }
    });
  }


  /// 逐本盘点词典资源，产出 [_DictionaryPackPlan]（BUG-2193）。
  ///
  /// 资源根不存在 = 这台设备一本词典的文件都没有，所有行都是幽灵。
  Future<_DictionaryPackPlan> _planDictionaryPack(Directory? root) async {
    final List<DictionaryMetaRow> dictionaries =
        await _db.getAllDictionaryMetadata();
    if (root == null || !await root.exists()) {
      return _DictionaryPackPlan(
        packable: const <String>[],
        ghosts: <String>[
          for (final DictionaryMetaRow d in dictionaries) d.name,
        ],
      );
    }
    final List<String> packable = <String>[];
    final List<String> ghosts = <String>[];
    for (final DictionaryMetaRow dictionary in dictionaries) {
      final Directory dictionaryDir = Directory(
        p.join(root.path, dictionary.name),
      );
      if (await _directoryHasFiles(dictionaryDir)) {
        packable.add(dictionary.name);
      } else {
        ghosts.add(dictionary.name);
      }
    }
    return _DictionaryPackPlan(packable: packable, ghosts: ghosts);
  }

  /// 只把 [names] 这几本词典的目录打进 zip（BUG-2193）。
  ///
  /// 顺带修掉旧实现的一个副作用：`_collectTreeFiles` 会把整棵
  /// `dictionaryResources/` 无差别打包，连 `download_temp` / `import_temp` /
  /// `update_temp` / `.pending_delete` 这些运行期临时目录一起塞进备份包白白撑大。
  /// 按词典名枚举天然把它们排除在外。
  static Future<void> _collectDictionaryTrees(
    Directory root,
    List<String> names,
    Map<String, String> into,
  ) async {
    for (final String name in names) {
      await _collectTreeFiles(
        Directory(p.join(root.path, name)),
        p.posix.join(_dictionaryResourcesPrefix, name),
        into,
      );
    }
  }

  /// 从导出副本里删掉 [names] 这几本词典的元数据行（BUG-2193）。
  ///
  /// 与 [_stripDictionaryState] 的区别是**不动词典查询历史、也不清空整表**：
  /// 这里处理的是「个别行没有对应文件」，不是「这次不导出词典」。
  static Future<void> _stripGhostDictionaryRows(
    String dbDirectory,
    List<String> names,
  ) async {
    if (names.isEmpty) return;
    final db = FushiDatabase(dbDirectory);
    try {
      for (final String name in names) {
        await db.deleteDictionaryMeta(name);
      }
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  static Future<bool> _directoryHasFiles(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final FileSystemEntity entity
        in directory.list(recursive: true)) {
      if (entity is File) return true;
    }
    return false;
  }

  /// 导出对话框预填的建议文件名（**纯写侧**）。
  ///
  /// 改名安全的前提是读侧从不按文件名识别备份：导入用的是 `allowedExtensions:
  /// ['zip']`，归档内容识别走 [_findDbEntry]（新条目名 `fushi.db`，旧归档
  /// `hibiki.db` 有回退），云端后端也没有按 `hibiki-backup*` 列举/轮转的逻辑。
  /// 所以用户手上 Hibiki 时代的 `*.hibiki.zip` 老包照样能导入（Never break
  /// userspace），只是今后新导出的包叫 `fushi-backup-*.fushi.zip`。
  String defaultFilename() {
    final String date = FushiTimeFormat.dayKey(DateTime.now());
    return 'fushi-backup-$date.fushi.zip';
  }
}
