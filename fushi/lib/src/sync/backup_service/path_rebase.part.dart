part of '../backup_service.dart';

// 备份包落地后的路径 rebase 族（B1 从 BackupService 拆出）：全是无状态函数，
// 只被 restoreBackup / mergeRestoreBackup 调用。

/// Rebases every stored absolute path carried by the backup DB (which points
/// at the SOURCE device's roots) onto THIS device's roots, in the fixed
/// content → fonts → local-audio → videos order shared by the overwrite and
/// merge imports. Custom-font config and local-audio DB paths are content
/// too (their files come from the backup). Each underlying rebase is a no-op
/// when the meta carries no matching source root (legacy backup) or the new
/// root is null — e.g. a keep-settings import whose preserved local paths
/// aren't under the source root, or an unticked import category.
Future<void> _rebaseAllPaths({
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
String _resolveExtractDirOnDevice(
    String rebased, String bookKey, String newBooksRoot) {
  if (rebased.isNotEmpty && Directory(rebased).existsSync()) return rebased;
  if (bookKey.isEmpty) return rebased;
  final String byKey = p.join(newBooksRoot, bookKey);
  if (Directory(byKey).existsSync()) return byKey;
  return rebased;
}

Future<void> _rebaseContentPaths({
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
        await db.updateAudiobookPaths(
          a.bookKey,
          audioRoot: a.audioRoot == null
              ? null
              : rebasePath(a.audioRoot!, oldAudio, newAudiobooksRoot),
          audioPathsJson: _rebaseAudioPathsJson(
              a.audioPathsJson, oldAudio, newAudiobooksRoot, a.bookKey),
          alignmentPath:
              rebasePath(a.alignmentPath, oldAudio, newAudiobooksRoot),
        );
      }
      // BUG-1575: srt_books carries its OWN copy of the audio paths and was
      // never rebased here, while the merge engine inserts its rows column
      // for column (audio_paths_json / audio_root / srt_path / cover_path all
      // verbatim from the source device). Result on a cross-root import: the
      // paired `audiobooks` row resolved but the `srt_book` row still pointed
      // at the SOURCE root, so the shelf saw a broken audiobook -- subtitles
      // (parsed cues live in `audio_cues`, no path) but no audio.
      //
      // All four columns live under ONE directory `<audiobooksRoot>/<uid>`
      // (see SyncAssetPackageService.importAudioDatabasePackage and
      // kPathRebaseColumns), so cover_path is rebased against the AUDIOBOOKS
      // root first. It still falls back to the books mapping via
      // _rebaseEither, because an epub-backed srt row (bookKey non-empty) may
      // have adopted the epub's cover under the books root.
      for (final SrtBookRow srt in await db.getAllSrtBooks()) {
        await db.updateSrtBookPaths(
          srt.uid,
          audioRoot: srt.audioRoot == null
              ? null
              : rebasePath(srt.audioRoot!, oldAudio, newAudiobooksRoot),
          audioPathsJson: _rebaseAudioPathsJson(
              srt.audioPathsJson, oldAudio, newAudiobooksRoot, srt.uid),
          srtPath: rebasePath(srt.srtPath, oldAudio, newAudiobooksRoot),
          coverPath: srt.coverPath == null
              ? null
              : _rebaseEither(srt.coverPath!, oldAudio, newAudiobooksRoot,
                  oldBooks, newBooksRoot),
        );
      }
    }
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// Rebases every path inside a persisted `audioPathsJson` string list from
/// [oldRoot] onto [newRoot]. A malformed value (corrupt row, not a JSON
/// string-list) must not abort the whole import -- it is returned verbatim
/// and the failure is logged with [rowKey] (review W3). Shared by the
/// `audiobooks` and `srt_books` rebases so the two can never drift.
String? _rebaseAudioPathsJson(
  String? json,
  String oldRoot,
  String newRoot,
  String rowKey,
) {
  if (json == null) return null;
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    return jsonEncode(decoded
        .whereType<String>()
        .map((String s) => rebasePath(s, oldRoot, newRoot))
        .toList());
  } catch (e) {
    debugPrint(
        'BackupService: skipped rebasing audioPathsJson for $rowKey: $e');
    return json;
  }
}

/// Rebases the imported DB's stored custom-font paths from the backup's
/// [BackupMeta.fontsRoot] onto this device's [newFontsRoot]. The canonical
/// `font_catalog` carries paths, while `font_targets` only carries catalog
/// ids/order/enabled rows; legacy shadow lists also carry paths. Every stored
/// file-font path is rebased (system fonts and unrelated paths untouched).
/// No-op when either root is null.
Future<void> _rebaseFontPaths({
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
Future<void> _rebaseLocalAudioPaths({
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
      (String body) => normalizeAudioSourceConfigsJson(body, newLocalAudioRoot),
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
Future<void> _normalizePrefInPlace(
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
void _warnLoopbackAudioSources(String? rawConfigs) {
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

Future<void> _rebaseVideoPaths({
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

String _rebaseVideoPath(
  String oldPath,
  Map<String, String> sourcePathToArchiveRelative,
  String newVideosRoot,
) {
  final String? relativePath = sourcePathToArchiveRelative[oldPath];
  if (relativePath == null) return oldPath;
  return _reappliedVideoPath(newVideosRoot, relativePath);
}

String? _rebaseVideoPlaylistJson(
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

String _reappliedVideoPath(
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
  final String targetPath = p.normalize(p.join(videosRoot, normalizedRelative));
  final String canonicalRoot = p.canonicalize(videosRoot);
  final String canonicalTarget = p.canonicalize(targetPath);
  if (canonicalTarget != canonicalRoot &&
      !p.isWithin(canonicalRoot, canonicalTarget)) {
    throw FormatException('Invalid backup video path: $archiveRelativePath');
  }
  return targetPath;
}

/// Rebases [path] trying the (oldA -> newA) mapping first, then
/// (oldB -> newB). A cover written under either tree resolves; one not under
/// either is returned unchanged. Either pair may be null (that category was
/// not part of the backup) -- a null pair is simply skipped, so callers do
/// not need a special case for it.
String _rebaseEither(
  String path,
  String? oldA,
  String? newA,
  String? oldB,
  String? newB,
) {
  if (oldA != null && newA != null) {
    final String viaA = rebasePath(path, oldA, newA);
    if (viaA != path) return viaA;
  }
  if (oldB != null && newB != null) {
    return rebasePath(path, oldB, newB);
  }
  return path;
}
