import 'dart:convert';

import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/models/local_audio_manager.dart';

// 备份导入 / 数据目录迁移共用的路径改写原语（纯函数，不依赖 BackupService 本体）：
// 存储层的 DataRootMigrator 与同步层的 BackupService 都经这里改写落库路径。

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
///
/// Separator handling of the rebased sub-path follows the TARGET root:
/// - a POSIX target ([newRoot] has no `\`) gets every `\` of the sub-path
///   turned into `/`. On POSIX `\` is an ordinary file-name character, so
///   keeping the source's separators turned a Windows backup merged on Android
///   into `/data/.../audiobooks\<dir>\a.m4b` — ONE literal file name that never
///   exists — and every imported audiobook / book / font path silently failed
///   to resolve (BUG-3811, feedback XDtB1kYT0C).
/// - a Windows target (`\` in [newRoot]) keeps the source sub-path verbatim:
///   Windows accepts both separators, and leaving the bytes alone keeps
///   same-device callers (`DataRootMigrator`) byte-for-byte unchanged.
/// Derived from [newRoot] rather than `Platform`, so this stays a pure function
/// with the same result on every host.
String rebasePath(String oldPath, String oldRoot, String newRoot) {
  String stripTrailing(String s) =>
      (s.endsWith('/') || s.endsWith('\\')) ? s.substring(0, s.length - 1) : s;
  // Normalize separators for the prefix comparison. We slice the path rather
  // than rebuild via p.join (which would apply the HOST's separator, not the
  // target root's).
  final String nrOld = stripTrailing(oldRoot.replaceAll('\\', '/'));
  final String npOld = oldPath.replaceAll('\\', '/');
  if (npOld == nrOld) return stripTrailing(newRoot);
  // Require a separator boundary so "/a/books_extra" is not treated as under
  // "/a/books". replaceAll preserves length, so nrOld.length indexes the
  // original oldPath correctly.
  if (!npOld.startsWith('$nrOld/')) return oldPath;
  final String target = stripTrailing(newRoot);
  final bool posixTarget = !target.contains('\\');
  final String suffix = (posixTarget ? npOld : oldPath).substring(
    nrOld.length,
  ); // keeps leading sep
  return target + suffix;
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
String rebaseFontListJson(
  String json,
  String oldRoot,
  String newRoot, {
  String Function(String path)? rewritePath,
}) {
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
String rebaseFontCatalogJson(
  String json,
  String oldRoot,
  String newRoot, {
  String Function(String path)? rewritePath,
}) {
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
      return <String, dynamic>{...row, 'path': rewrite(path)};
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
