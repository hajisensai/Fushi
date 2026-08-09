import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/fushi_time_format.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

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
  /// stored flat in the support/database directory alongside `fushi.db`. The
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
  /// `mined_sentences` and `favorite_words`. Stripped from the DB copy when
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
  /// flat alongside `fushi.db`. Captured so import can rebase the stored
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

  /// 备份归档里主库条目名 = 活库文件名（fushi_core 单一真相源）。写侧（导出/
  /// bak/临时提取路径）一律用它；读老归档（Fushi 时代备份 / 迁移压缩包，条目名
  /// `fushi.db`）经 [_findDbEntry] 做 legacy 回退（Never break userspace）。
  static const String _dbName = fushiDatabaseFileName;
  static const String _metaName = 'backup_meta.json';
  static const String _dictionaryResourcesPrefix = 'dictionaryResources';

  /// 书树条目在归档里的前缀。写侧一律用它；读侧经 [archiveBooksPrefix] 对旧
  /// Fushi 归档（前缀 `hoshi_books`）做 legacy 回退（Never break userspace，
  /// 同 [_dbName] 的 `_findDbEntry` 先例）。
  static const String _booksPrefix = 'fushi_books';

  /// 旧 Fushi 时代备份/迁移归档的书树前缀（W2-7 读侧回退输入；旧字面量只
  /// 允许活在读旧归档的回退里）。
  static const String _legacyBooksPrefix = 'hoshi_books';
  static const String _audiobooksPrefix = 'audiobooks';
  static const String _fontsPrefix = 'custom_fonts';
  static const String _videosPrefix = 'videos';
  static const String _localAudioPrefix = 'localAudio';

  /// Preference key (in the `preferences` table) whose JSON value is the
  /// local-audio library list `[{path, displayName, enabled, sources}]`. The
  /// `path` of each entry points at a `local_audio_*.db` file in the support
  /// directory and is rebased onto this device's root on import (TODO-941).
  static const String _localAudioDbsPrefKey = 'local_audio_dbs';
  static const String _audioSourceConfigsPrefKey = 'audio_source_configs';

  /// Matches a packed local-audio database file (and its `-wal`/`-shm`
  /// siblings). Only these are packed from the support directory so the export
  /// never sweeps in `fushi.db` or other unrelated support files.
  static final RegExp _localAudioFileName =
      RegExp(r'^local_audio_\d+\.db(-wal|-shm)?$');

  /// Matches ONLY a packed local-audio database file (not its `-wal`/`-shm`
  /// siblings), for counting distinct local-audio databases in a summary.
  static final RegExp _localAudioDbOnly = RegExp(r'^local_audio_\d+\.db$');

  /// Persisted preference key (ReaderSettings prefix included) whose JSON
  /// value is the canonical catalog `{version, fonts:[{id, name, path}]}`.
  static const String _fontCatalogPrefKey = 'src:reader_fushi:font_catalog';

  /// Persisted legacy shadow preference keys (ReaderSettings prefix included)
  /// whose JSON value is a font list `[{name, path, enabled}]`. These remain
  /// import-compatible while `font_catalog` is the canonical model.
  static const List<String> _legacyFontPrefKeys = <String>[
    'src:reader_fushi:custom_fonts',
    'src:reader_fushi:app_ui_fonts',
    'src:reader_fushi:dict_fonts',
    'src:reader_fushi:video_sub_fonts',
  ];

  /// Preference key holding the favorite-sentence JSON list (mirrors
  /// `FavoriteSentenceRepository._key` / `BackupMergeEngine`). It is CONTENT
  /// (favorite sentences travel / merge as content), so the `settings` category
  /// strip must never delete it.
  static const String _favoriteSentencesPrefKey = 'favorite_sentences';

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
  /// both directions silently worked before the v71 graph existed, but now
  /// fails with `foreign_keys=ON`.
  static const List<String> _deviceLocalTables = <String>[
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
    'fushi_paired_peers',
    'sync_baselines',
    'fushi_paired_peers',
  ];

  static const List<String> _deviceLocalTablesParentFirst = <String>[
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
  /// table, so a wholesale DELETE is safe.
  static const List<String> _statisticsTables = <String>[
    'reading_statistics',
    'reading_hourly_logs',
    'video_watch_statistics',
    'video_hourly_logs',
    'mining_statistics',
    'lookup_mining_counters',
    'mined_sentences',
    'favorite_words',
  ];

  /// The four profile-layer tables in CHILD-first order, so a DELETE sweep of
  /// the `profiles` category (TODO-1193) never trips an enforced FK to
  /// `profiles`. The reverse of [_settingsLayerTables] (which is parent-first
  /// for INSERT).
  static const List<String> _profilesLayerTablesChildFirst = <String>[
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
  static final String settingsPrefPredicate = _buildSettingsPrefPredicate();

  static String _buildSettingsPrefPredicate() {
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
        'AND key NOT IN ($notIn)';
  }

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
    return "key NOT LIKE 'audiobook_pos_%' AND key NOT IN ($notIn)";
  }

  /// Sidecar file holding this device's sync config across an import. Written
  /// BEFORE the destructive DB overwrite so a crash mid-import is recoverable
  /// (a startup sweep re-applies it). Deleted once the import completes.
  static const String _preserveSidecar = '$_dbName.sync-preserve.json';

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
  Future<BackupContentSummary> summarizeBackupFile(String zipPath) async {
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
          'BackupService.summarizeBackupFile failed for $zipPath: $e\n$st');
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
      debugPrint('BackupService._peekContentRowCounts failed: $e\n$st');
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

  /// Builds the export "what's inside" summary from the live DB + this device's
  /// content roots (TODO-1358). Counts are the natural unit per category; a root
  /// this service was built without counts as zero. Reads only counts, so it is
  /// cheap even on a large library.
  Future<BackupContentSummary> summarizeLiveContent() async {
    final int books = (await _db.getAllEpubBooks()).length;
    final int audiobooks = (await _db.getAllAudiobooks()).length;
    final int videos = (await _db.allVideoBooks()).length;
    final int dictionaries = (await _db.getAllDictionaryMetadata()).length;
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
  /// without that root. The database (`fushi.db`) is always included
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
  Future<BackupMeta> createBackup(
    String outputPath, {
    Set<BackupCategory>? categories,
    Set<String>? bookKeys,
    Set<String>? videoKeys,
  }) async {
    bool wants(BackupCategory c) =>
        categories == null || categories.contains(c);
    final tmpDir = await Directory.systemTemp.createTemp('fushi_backup_');
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
      final bool includeDictionary = wants(BackupCategory.dictionary) &&
          await _hasCompleteDictionaryResources(dictionaryResourceRoot);
      // Whether the "book content" category is packed. When it is NOT, the
      // hoshi_books/ tree is skipped below AND the epub_books rows must be
      // stripped from the DB copy — otherwise a restore/merge would insert book
      // records whose content files never travelled = un-openable "ghost" books
      // (TODO-1195 part C). This keeps the switch consistent: a book that isn't
      // packed never appears after import.
      final bool includeBooks = wants(BackupCategory.books);
      await _stripCredentials(tmpDir.path);
      if (!includeDictionary) {
        await _stripDictionaryState(tmpDir.path);
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
        await _collectTreeFiles(
            dictionaryResourceRoot!, _dictionaryResourcesPrefix, files);
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
      await _writeBackupZipInIsolate(
        outputPath: outputPath,
        metaName: _metaName,
        metaJson: metaJson,
        archivePathToSource: files,
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

  /// Whether a Windows OS error code is a transient filesystem-busy condition
  /// that clears once an external handle is released. The recursive delete of
  /// the export's temp dir runs right after [_stripCredentials] /
  /// [_stripDictionaryState] closed their sqlite connections; on Windows the OS
  /// (and Defender / search-indexer scanning the just-written `fushi.db` copy)
  /// can keep a handle open for a brief window after `close()` returns, so the
  /// delete fails with ERROR_ACCESS_DENIED(5), ERROR_SHARING_VIOLATION(32) or
  /// ERROR_DIR_NOT_EMPTY(145, a child file still locked). Same family as the
  /// dictionary-import rename lock (BUG-050).
  static bool _isWindowsTransientFsBusy(int? code) =>
      code == 5 || code == 32 || code == 145;

  /// Pure, dependency-injected core of [_deleteDirectoryIfPresent]: deletes a
  /// directory tree, tolerating both a vanished tree ([PathNotFoundException]:
  /// already cleaned up) and -- on Windows only -- a transient filesystem-busy
  /// error (see [_isWindowsTransientFsBusy]) via a bounded, backing-off retry
  /// that gives the lingering external handle time to release.
  ///
  /// A non-Windows error, or a Windows error that is NOT transient FS-busy, is
  /// rethrown immediately (never swallowed -- a real cleanup failure must
  /// surface). If every attempt hits transient FS-busy the last exception is
  /// rethrown rather than silently leaving the temp tree on disk. POSIX deletes
  /// succeed on the first attempt and never enter the retry branch.
  @visibleForTesting
  static Future<void> deleteDirectoryWithRetry({
    required Future<bool> Function() exists,
    required Future<void> Function() delete,
    required Future<void> Function(int delayMs) sleep,
    required bool isWindows,
    int maxAttempts = 10,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (await exists()) {
          await delete();
        }
        return;
      } on PathNotFoundException {
        // Cleanup is already satisfied if the temp tree vanished between the
        // existence check and deletion.
        return;
      } on FileSystemException catch (e) {
        final int? code = e.osError?.errorCode;
        final bool transient = isWindows && _isWindowsTransientFsBusy(code);
        if (!transient || attempt == maxAttempts) rethrow;
        await sleep(50 * attempt); // backoff: 50ms,100ms,... let handle drop
      }
    }
  }

  /// Retries a directory [rename] that hits a transient Windows filesystem-busy
  /// error (access denied / sharing violation — see [_isWindowsTransientFsBusy])
  /// with a bounded backoff. The content-tree swap renames a freshly-EXTRACTED
  /// `.import-tmp` into place; on Windows an antivirus / indexer scanning the
  /// just-written tree briefly holds handles, so the immediate rename can fail
  /// with `errno 5` (the "备份导入失败: Rename failed … 拒绝访问" the user hit).
  /// A non-Windows error, or a non-transient Windows error, is rethrown at once.
  /// The longer cap than the delete retry (backoff to ~1s/attempt) gives a big
  /// multi-GB tree's scan time to finish.
  @visibleForTesting
  static Future<void> renameDirectoryWithRetry({
    required Future<void> Function() rename,
    required Future<void> Function(int delayMs) sleep,
    required bool isWindows,
    int maxAttempts = 20,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await rename();
        return;
      } on FileSystemException catch (e) {
        final int? code = e.osError?.errorCode;
        final bool transient = isWindows && _isWindowsTransientFsBusy(code);
        if (!transient || attempt == maxAttempts) rethrow;
        // backoff: 100ms,200ms,... capped at 1s → ~15s total over 20 attempts.
        await sleep((100 * attempt).clamp(100, 1000));
      }
    }
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
  /// were still sitting in the exported `fushi.db` under `profile_settings`.
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
      debugPrint('BackupService._reapplyDeviceLocalTablesFromBak: '
          'pre-restore.bak missing — local pairing/baselines could not be '
          'preserved on import.');
      return false;
    }
    late final bool hasSqliteHeader;
    try {
      hasSqliteHeader = await _hasSqliteHeader(bakPath);
    } catch (e, st) {
      debugPrint('BackupService._reapplyDeviceLocalTablesFromBak: '
          'pre-restore.bak could not be inspected: $e\n$st');
      return false;
    }
    if (!hasSqliteHeader) {
      // A few low-level restore callers intentionally swap opaque fixture
      // bytes rather than a Fushi database. Such a snapshot cannot contain
      // device-local rows, so there is nothing to retry or retain.
      debugPrint('BackupService._reapplyDeviceLocalTablesFromBak: '
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
      debugPrint('BackupService._reapplyDeviceLocalTablesFromBak failed: '
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
  static Future<void> _stripExcludedDataCategories(
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
      // Drain the shared tag pool of rows no longer referenced by ANY surviving
      // mapping — the three per-content book mappings AND `collection_tag_mappings`
      // (a tag can label a collection without labelling any book, so this union
      // must include it or a collection-only tag would be wrongly drained).
      // Content mappings for excluded content were FK-cascade-cleared above.
      await db.customStatement(
        'DELETE FROM book_tags WHERE id NOT IN ('
        'SELECT tag_id FROM book_tag_mappings '
        'UNION SELECT tag_id FROM srt_book_tag_mappings '
        'UNION SELECT tag_id FROM video_book_tag_mappings '
        'UNION SELECT tag_id FROM collection_tag_mappings)',
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
      debugPrint('BackupService._reapplyExcludedContentRegistry: '
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
      debugPrint('BackupService._reapplyExcludedContentRegistry failed: '
          '$e\n$st');
    } finally {
      try {
        await db?.close();
      } catch (_) {/* db may have failed to open */}
    }
  }

  /// 归档里主库条目的解析（读侧唯一入口）：新备份条目名是 [_dbName]（fushi.db），
  /// 老 Fushi 时代的备份 / Android 迁移压缩包条目名是
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
  Future<BackupMeta?> validateBackup(String zipPath) async {
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
      debugPrint('BackupService.validateBackup failed for $zipPath: $e\n$st');
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
        // The v71 download graph is device-local even when there are no sync
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
      //     individual files sharing the directory with fushi.db, so they are
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
        debugPrint('BackupService.restoreBackup: device-local tables were not '
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
      debugPrint('BackupService.previewMergeRestore failed: $e\n$st');
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
      debugPrint('BackupService.recoverMergeRestore failed: $e\n$st');
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
      debugPrint('BackupService.recoverPendingRestore: corrupt sidecar: '
          '$e\n$st');
      sidecarStateApplied = true;
    } on TypeError catch (e, st) {
      debugPrint('BackupService.recoverPendingRestore: invalid sidecar shape: '
          '$e\n$st');
      sidecarStateApplied = true;
    } catch (e, st) {
      // Database/filesystem failures are retryable. Keep both artifacts so the
      // next startup can replay the same idempotent operations.
      debugPrint('BackupService.recoverPendingRestore failed: $e\n$st');
      return;
    }

    if (!sidecarStateApplied) return;
    if (shouldReapplyDeviceLocalTables) {
      final bool deviceLocalTablesReapplied =
          await _reapplyDeviceLocalTablesFromBak(dbDirectory, bakPath);
      if (!deviceLocalTablesReapplied) {
        debugPrint('BackupService.recoverPendingRestore: retaining sidecar and '
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
      debugPrint('BackupService._reapplySettingsLayer: pre-restore.bak missing '
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
      debugPrint('BackupService._reapplyExcludedSettingsLayers: '
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
      debugPrint('BackupService._reapplyDictionaryTablesFromBak: '
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
      debugPrint('BackupService._readDeviceLocalPrefs failed: $e\n$st');
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
      await SyncRepository(db).clearFolderCache();
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
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
  static Future<void> _retainBooks(
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
  static Future<void> _retainVideos(
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
  static Future<void> _retainAudiobooks(
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
  /// matching [_localAudioFileName] are packed, so `fushi.db`, sidecars and
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
  static Future<void> _writeBackupZipInIsolate({
    required String outputPath,
    required String metaName,
    required String metaJson,
    required Map<String, String> archivePathToSource,
  }) async {
    await Isolate.run(() async {
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
          await encoder.addFile(file, entry.key, ZipFileEncoder.STORE);
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

  Future<bool> _hasCompleteDictionaryResources(Directory? root) async {
    if (root == null || !await root.exists()) return false;
    final List<DictionaryMetaRow> dictionaries =
        await _db.getAllDictionaryMetadata();
    if (dictionaries.isEmpty) return false;
    for (final DictionaryMetaRow dictionary in dictionaries) {
      final Directory dictionaryDir = Directory(
        p.join(root.path, dictionary.name),
      );
      if (!await _directoryHasFiles(dictionaryDir)) return false;
    }
    return true;
  }

  static Future<bool> _directoryHasFiles(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final FileSystemEntity entity
        in directory.list(recursive: true)) {
      if (entity is File) return true;
    }
    return false;
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
  /// individual files SHARING the directory with `fushi.db`, so they are
  /// written file-by-file rather than via the destructive tree swap. Only file
  /// names matching [_localAudioFileName] are accepted (defense in depth: an
  /// archive entry naming `fushi.db` under `localAudio/` is rejected).
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
      // fushi.db.
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
  /// 否则回退旧前缀 [_legacyBooksPrefix]（旧 Fushi app 导出的备份/迁移归档）。
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

  /// Rebases every stored absolute path carried by the backup DB (which points
  /// at the SOURCE device's roots) onto THIS device's roots, in the fixed
  /// content → fonts → local-audio → videos order shared by the overwrite and
  /// merge imports. Custom-font config and local-audio DB paths are content
  /// too (their files come from the backup). Each underlying rebase is a no-op
  /// when the meta carries no matching source root (legacy backup) or the new
  /// root is null — e.g. a keep-settings import whose preserved local paths
  /// aren't under the source root, or an unticked import category.
  static Future<void> _rebaseAllPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newBooksRoot,
    required String? newAudiobooksRoot,
    required String? newFontsRoot,
    required String? newLocalAudioRoot,
    required String? newVideosRoot,
  }) async {
    await _rebaseContentPaths(
      dbDirectory: dbDirectory,
      meta: meta,
      newBooksRoot: newBooksRoot,
      newAudiobooksRoot: newAudiobooksRoot,
    );
    await _rebaseFontPaths(
      dbDirectory: dbDirectory,
      meta: meta,
      newFontsRoot: newFontsRoot,
    );
    await _rebaseLocalAudioPaths(
      dbDirectory: dbDirectory,
      meta: meta,
      newLocalAudioRoot: newLocalAudioRoot,
    );
    await _rebaseVideoPaths(
      dbDirectory: dbDirectory,
      meta: meta,
      newVideosRoot: newVideosRoot,
    );
  }

  /// Rebases the imported DB's stored absolute content paths from the backup's
  /// source roots ([BackupMeta.booksRoot] / [BackupMeta.audiobooksRoot]) onto
  /// this device's [newBooksRoot] / [newAudiobooksRoot]. No-op for a legacy
  /// backup (meta has no roots). Cover paths can live under EITHER tree (epub
  /// covers in hoshi_books, audiobook covers in audiobooks), so they try both.
  /// EPUB 解包目录在本机的**确定性回退**。
  ///
  /// [rebasePath] 靠「老根前缀」做字符串替换。一旦备份记录的
  /// [BackupMeta.booksRoot] 与行里的真实前缀对不上，前缀匹配会失败并**静默原样
  /// 返回**导出设备的绝对路径——库看着导入成功，每本书却都「找不到书籍文件」。
  /// 真实踩中的形态：跨包名迁移时导出端把书根名写成改名前的旧名（`hoshi_books`），
  /// 而行里是 `fushi_books`，于是 rebase 全程无声失效，四本书的 `extract_dir`
  /// 仍指向老包私有目录 `/data/user/0/<老包名>/...`——那是另一个应用的沙箱，
  /// 新包永远读不到，尽管文件早已解包到本机书根下。
  ///
  /// 解包落点本身是确定的（`<booksRoot>/<bookKey>`），所以不必去猜老根：rebase
  /// 结果在本机不存在、而该确定位置存在时，用后者。**原路径有效时一律不动**，
  /// 普通备份恢复的行为不变。
  static String _resolveExtractDirOnDevice(
      String rebased, String bookKey, String newBooksRoot) {
    if (rebased.isNotEmpty && Directory(rebased).existsSync()) return rebased;
    if (bookKey.isEmpty) return rebased;
    final String byKey = p.join(newBooksRoot, bookKey);
    if (Directory(byKey).existsSync()) return byKey;
    return rebased;
  }

  static Future<void> _rebaseContentPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newBooksRoot,
    required String? newAudiobooksRoot,
  }) async {
    final String? oldBooks = meta.booksRoot;
    final String? oldAudio = meta.audiobooksRoot;
    final bool canBooks = oldBooks != null && newBooksRoot != null;
    final bool canAudio = oldAudio != null && newAudiobooksRoot != null;
    if (!canBooks && !canAudio) return;

    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      if (canBooks) {
        for (final EpubBookRow b in await db.getAllEpubBooks()) {
          await db.updateEpubBookContentPaths(
            b.bookKey,
            epubPath: rebasePath(b.epubPath, oldBooks, newBooksRoot),
            extractDir: _resolveExtractDirOnDevice(
              rebasePath(b.extractDir, oldBooks, newBooksRoot),
              b.bookKey,
              newBooksRoot,
            ),
            coverPath: b.coverPath == null
                ? null
                : _rebaseEither(b.coverPath!, oldBooks, newBooksRoot, oldAudio,
                    newAudiobooksRoot),
          );
        }
      }
      if (canAudio) {
        for (final AudiobookRow a in await db.getAllAudiobooks()) {
          // Rebase each path inside audioPathsJson. A malformed value (corrupt
          // row, not a JSON string-list) must not abort the whole import — keep
          // it as-is and move on (review W3).
          String? rebasedJson = a.audioPathsJson;
          if (a.audioPathsJson != null) {
            try {
              final dynamic decoded = jsonDecode(a.audioPathsJson!);
              if (decoded is List) {
                rebasedJson = jsonEncode(decoded
                    .whereType<String>()
                    .map((s) => rebasePath(s, oldAudio, newAudiobooksRoot))
                    .toList());
              }
            } catch (e) {
              debugPrint('BackupService: skipped rebasing audioPathsJson for '
                  '${a.bookKey}: $e');
            }
          }
          await db.updateAudiobookPaths(
            a.bookKey,
            audioRoot: a.audioRoot == null
                ? null
                : rebasePath(a.audioRoot!, oldAudio, newAudiobooksRoot),
            audioPathsJson: rebasedJson,
            alignmentPath:
                rebasePath(a.alignmentPath, oldAudio, newAudiobooksRoot),
          );
        }
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Rebases the imported DB's stored custom-font paths from the backup's
  /// [BackupMeta.fontsRoot] onto this device's [newFontsRoot]. The canonical
  /// `font_catalog` carries paths, while `font_targets` only carries catalog
  /// ids/order/enabled rows; legacy shadow lists also carry paths. Every stored
  /// file-font path is rebased (system fonts and unrelated paths untouched).
  /// No-op when either root is null.
  static Future<void> _rebaseFontPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newFontsRoot,
  }) async {
    final String? oldFonts = meta.fontsRoot;
    if (oldFonts == null || newFontsRoot == null) return;
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      final Map<String, String> prefs = await db.getAllPrefs();
      final String? catalog = prefs[_fontCatalogPrefKey];
      if (catalog != null) {
        final String rebasedCatalog = rebaseFontCatalogJson(
          catalog,
          oldFonts,
          newFontsRoot,
        );
        if (rebasedCatalog != catalog) {
          await db.setPref(_fontCatalogPrefKey, rebasedCatalog);
        }
      }
      for (final String key in _legacyFontPrefKeys) {
        final String? raw = prefs[key];
        if (raw == null) continue;
        final String rebased = rebaseFontListJson(raw, oldFonts, newFontsRoot);
        if (rebased != raw) await db.setPref(key, rebased);
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Re-homes the imported DB's stored local-audio paths onto THIS device's
  /// support directory [newLocalAudioRoot] by FILENAME, for BOTH the canonical
  /// `local_audio_dbs` pref AND the typed `audio_source_configs` pref (its
  /// localAudio entries). Keeping both in lock-step preserves the
  /// typed-config <-> local_audio_dbs join (AppModel.audioSourceConfigs matches
  /// by path); re-homing only one side would split them and drop the typed
  /// source (TODO-1171). Gated on [BackupMeta.localAudioRoot] being non-null —
  /// i.e. the localAudio category was packed, so the `.db` files actually
  /// crossed over and this device's restored DB is a real, openable database
  /// (a db-only backup carries no audio files, and runtime resolution via
  /// [LocalAudioManager.resolveInternalPath] covers playback there without
  /// touching stored prefs; opening the DB in that isolation case is neither
  /// needed nor safe — mirrors the sibling content/font rebasers). Preserves
  /// each pref's PrefCodec tag (`s:`/`j:` in production, untagged in some
  /// tests). Also logs any loopback remoteAudio source as a cross-machine
  /// hazard so the failure is visible, never silent.
  static Future<void> _rebaseLocalAudioPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newLocalAudioRoot,
  }) async {
    if (meta.localAudioRoot == null || newLocalAudioRoot == null) return;
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      final Map<String, String> prefs = await db.getAllPrefs();
      await _normalizePrefInPlace(
        db,
        prefs,
        _localAudioDbsPrefKey,
        (String body) => normalizeLocalAudioDbsJson(body, newLocalAudioRoot),
      );
      await _normalizePrefInPlace(
        db,
        prefs,
        _audioSourceConfigsPrefKey,
        (String body) =>
            normalizeAudioSourceConfigsJson(body, newLocalAudioRoot),
      );
      _warnLoopbackAudioSources(prefs[_audioSourceConfigsPrefKey]);
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Reads [key] from [prefs], runs the tag-aware [transform] on its stored
  /// value, and writes it back when it changed. No-op when the key is absent or
  /// the value is unchanged.
  static Future<void> _normalizePrefInPlace(
    FushiDatabase db,
    Map<String, String> prefs,
    String key,
    String Function(String storedValue) transform,
  ) async {
    final String? raw = prefs[key];
    if (raw == null) return;
    final String next = transform(raw);
    if (next == raw) return;
    await db.setPref(key, next);
  }

  /// Logs (never silently drops) any imported remoteAudio source that points at
  /// a loopback host — it resolved on the source device but points at THIS new
  /// machine after import, so it needs a manual re-point. The audio-source
  /// management UI surfaces the same hazard as a per-row warning (TODO-1171).
  static void _warnLoopbackAudioSources(String? rawConfigs) {
    if (rawConfigs == null) return;
    try {
      final dynamic decoded = jsonDecode(splitPrefTag(rawConfigs).body);
      if (decoded is! List) return;
      for (final dynamic e in decoded) {
        if (e is! Map) continue;
        if (e['kind'] != AudioSourceKind.remoteAudio.wireName) continue;
        final Object? url = e['url'];
        if (url is String && AudioSourceConfig.isLoopbackAudioUrl(url)) {
          debugPrint(
            '[fushi-audio] imported remote audio source points at a loopback '
            'host and will not resolve on this device until re-pointed: $url',
          );
        }
      }
    } catch (_) {
      // diagnostic only; never abort import on a malformed pref
    }
  }

  static Future<void> _rebaseVideoPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newVideosRoot,
  }) async {
    if (newVideosRoot == null || meta.videoFiles.isEmpty) return;
    final FushiDatabase db = FushiDatabase(dbDirectory);
    try {
      for (final VideoBookRow row in await db.allVideoBooks()) {
        final String videoPath =
            _rebaseVideoPath(row.videoPath, meta.videoFiles, newVideosRoot);
        final String? playlistJson = _rebaseVideoPlaylistJson(
          row.playlistJson,
          meta.videoFiles,
          newVideosRoot,
        );
        if (videoPath == row.videoPath && playlistJson == row.playlistJson) {
          continue;
        }
        await db.customStatement(
          'UPDATE video_books SET video_path = ?, playlist_json = ? '
          'WHERE book_uid = ?',
          <Object?>[videoPath, playlistJson, row.bookUid],
        );
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  static String _rebaseVideoPath(
    String oldPath,
    Map<String, String> sourcePathToArchiveRelative,
    String newVideosRoot,
  ) {
    final String? relativePath = sourcePathToArchiveRelative[oldPath];
    if (relativePath == null) return oldPath;
    return _reappliedVideoPath(newVideosRoot, relativePath);
  }

  static String? _rebaseVideoPlaylistJson(
    String? playlistJson,
    Map<String, String> sourcePathToArchiveRelative,
    String newVideosRoot,
  ) {
    if (playlistJson == null || playlistJson.isEmpty) return playlistJson;
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return playlistJson;
      bool changed = false;
      final List<dynamic> rewritten = decoded.map<dynamic>((dynamic entry) {
        if (entry is! Map) return entry;
        final Map<String, dynamic> row = Map<String, dynamic>.from(entry);
        final Object? path = row['path'];
        if (path is! String) return row;
        final String rebased =
            _rebaseVideoPath(path, sourcePathToArchiveRelative, newVideosRoot);
        if (rebased != path) {
          row['path'] = rebased;
          changed = true;
        }
        return row;
      }).toList();
      return changed ? jsonEncode(rewritten) : playlistJson;
    } catch (_) {
      return playlistJson;
    }
  }

  static String _reappliedVideoPath(
    String videosRoot,
    String archiveRelativePath,
  ) {
    final String relative = archiveRelativePath.replaceAll(r'\', '/');
    final String normalizedRelative = p.posix.normalize(relative);
    if (relative.isEmpty ||
        p.posix.isAbsolute(relative) ||
        normalizedRelative == '..' ||
        normalizedRelative.startsWith('../')) {
      throw FormatException('Invalid backup video path: $archiveRelativePath');
    }
    final String targetPath =
        p.normalize(p.join(videosRoot, normalizedRelative));
    final String canonicalRoot = p.canonicalize(videosRoot);
    final String canonicalTarget = p.canonicalize(targetPath);
    if (canonicalTarget != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      throw FormatException('Invalid backup video path: $archiveRelativePath');
    }
    return targetPath;
  }

  /// Rebases [path] trying the books mapping first, then the audiobooks mapping.
  /// A cover written under either tree resolves; one not under either is
  /// returned unchanged.
  static String _rebaseEither(
    String path,
    String oldBooks,
    String newBooks,
    String? oldAudio,
    String? newAudio,
  ) {
    final String viaBooks = rebasePath(path, oldBooks, newBooks);
    if (viaBooks != path) return viaBooks;
    if (oldAudio != null && newAudio != null) {
      return rebasePath(path, oldAudio, newAudio);
    }
    return path;
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
  /// whole entry. Fushi backups are written STORE (see
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

  String defaultFilename() {
    final String date = FushiTimeFormat.dayKey(DateTime.now());
    return 'fushi-backup-$date.fushi.zip';
  }

  // ── 旧名兼容转发（命名统一 §1-H：备份动词按用户视角统一 create/restore）────
  //
  // 用户视角的「创建备份 / 恢复备份」此前在代码里叫 export/import*，与 DB 内部
  // 子步骤的 restore* 撞词。顶层 API 改名后保留下列 @Deprecated 转发（外部/并行
  // 分支调用点平滑迁移）；内部子步骤已全部 restore*→reapply*，无转发。

  /// 旧名兼容：已改名 [createBackup]。
  @Deprecated('已改名 createBackup（用户视角动词），请改用新名')
  Future<BackupMeta> exportBackup(
    String outputPath, {
    Set<BackupCategory>? categories,
    Set<String>? bookKeys,
    Set<String>? videoKeys,
  }) =>
      createBackup(
        outputPath,
        categories: categories,
        bookKeys: bookKeys,
        videoKeys: videoKeys,
      );

  /// 旧名兼容：已改名 [restoreBackup]。
  @Deprecated('已改名 restoreBackup（用户视角动词），请改用新名')
  static Future<void> importBackupFiles({
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
  }) =>
      restoreBackup(
        dbDirectory: dbDirectory,
        zipPath: zipPath,
        importSettings: importSettings,
        categories: categories,
        dictionaryResourceDirectory: dictionaryResourceDirectory,
        booksRootDirectory: booksRootDirectory,
        audiobooksRootDirectory: audiobooksRootDirectory,
        fontsRootDirectory: fontsRootDirectory,
        videosRootDirectory: videosRootDirectory,
        onProgress: onProgress,
      );

  /// 旧名兼容：已改名 [mergeRestoreBackup]。
  @Deprecated('已改名 mergeRestoreBackup（用户视角动词），请改用新名')
  static Future<void> mergeImportBackupFiles({
    required String dbDirectory,
    required String zipPath,
    Set<BackupCategory>? categories,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
    String? fontsRootDirectory,
    String? videosRootDirectory,
    void Function(double progress)? onProgress,
  }) =>
      mergeRestoreBackup(
        dbDirectory: dbDirectory,
        zipPath: zipPath,
        categories: categories,
        dictionaryResourceDirectory: dictionaryResourceDirectory,
        booksRootDirectory: booksRootDirectory,
        audiobooksRootDirectory: audiobooksRootDirectory,
        fontsRootDirectory: fontsRootDirectory,
        videosRootDirectory: videosRootDirectory,
        onProgress: onProgress,
      );

  /// 旧名兼容：已改名 [summarizeBackupEntries]（入参是归档条目名列表而非
  /// `Archive` 对象，旧名易误导）。
  @Deprecated('已改名 summarizeBackupEntries，请改用新名')
  static BackupContentSummary summarizeBackupArchive(
    Iterable<String> archiveFileNames,
    BackupMeta? meta, {
    int? dbVideoBookCount,
    int? dbAudiobookCount,
  }) =>
      summarizeBackupEntries(
        archiveFileNames,
        meta,
        dbVideoBookCount: dbVideoBookCount,
        dbAudiobookCount: dbAudiobookCount,
      );

  /// 旧名兼容：已改名 [summarizeBackupFile]。
  @Deprecated('已改名 summarizeBackupFile，请改用新名')
  Future<BackupContentSummary> summarizeBackupZip(String zipPath) =>
      summarizeBackupFile(zipPath);

  /// 旧名兼容：已改名 [summarizeLiveContent]（摘要对象是**现库内容**而非任何
  /// 备份文件，与上两者本就不同义，旧名 Export 前缀掩盖了这一点）。
  @Deprecated('已改名 summarizeLiveContent，请改用新名')
  Future<BackupContentSummary> summarizeExportContent() =>
      summarizeLiveContent();

  /// 旧名兼容：已改名 [previewMergeRestore]。
  @Deprecated('已改名 previewMergeRestore，请改用新名')
  static Future<BackupMergePreview?> previewMergeImport({
    required FushiDatabase liveDb,
    required String dbDirectory,
    required String zipPath,
  }) =>
      previewMergeRestore(
        liveDb: liveDb,
        dbDirectory: dbDirectory,
        zipPath: zipPath,
      );

  /// 旧名兼容：已改名 [recoverMergeRestore]。
  @Deprecated('已改名 recoverMergeRestore，请改用新名')
  static Future<bool> recoverMergeImport(String dbDirectory) =>
      recoverMergeRestore(dbDirectory);

  /// 旧名兼容：已改名 [recoverPendingRestore]。
  @Deprecated('已改名 recoverPendingRestore，请改用新名')
  static Future<void> recoverPendingImport(String dbDirectory) =>
      recoverPendingRestore(dbDirectory);
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
