import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:hibiki/src/sync/google_drive_auth.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class GoogleDriveError implements Exception {
  GoogleDriveError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  bool get isStaleCacheError => statusCode == 404;

  @override
  String toString() => 'GoogleDriveError($statusCode): $message';
}

/// Whether [error] is an expired/rejected access-token failure that a token
/// refresh + single retry can recover from.
///
/// The catch here must accept BOTH shapes a 401 can take:
/// - [drive.DetailedApiRequestError] with `status == 401` — googleapis turns a
///   plain HTTP 401 response into this.
/// - [auth.AccessDeniedException] — the googleapis_auth `authenticatedClient`
///   intercepts any response carrying a `www-authenticate` header inside its own
///   `send()` (auth_http_utils.dart) and throws this BEFORE googleapis can map
///   it to a [drive.DetailedApiRequestError]. The desktop/mobile clients are
///   plain (non-auto-refreshing), so an expired access token surfaces here as
///   the verbatim `Access was denied (www-authenticate header was: ...
///   error="invalid_token")` message. Catching only the request-error shape
///   meant the refresh-and-retry never fired and the user saw a raw
///   `invalid_token` sync failure ~1h after sign-in (BUG-060).
/// - [auth.ServerRequestFailedException] with `statusCode == 401` — a token the
///   auth service itself rejected during a request.
@visibleForTesting
bool googleDriveErrorIsUnauthorized(Object error) {
  if (error is drive.DetailedApiRequestError) return error.status == 401;
  if (error is auth.AccessDeniedException) return true;
  if (error is auth.ServerRequestFailedException) {
    return error.statusCode == 401;
  }
  return false;
}

/// Whether [error] is a 403 `insufficient_scope` — the access token is valid but
/// its grant lacks the scope the request needs (TODO-836: a user whose old grant
/// only carried `drive.file` after we switched to `drive.appdata`). A token
/// refresh does NOT help: the scope set is fixed at consent time, so refreshing
/// the access token returns the same insufficient scopes. This must be detected
/// BEFORE [googleDriveErrorIsUnauthorized] — the latter returns true for ANY
/// [auth.AccessDeniedException], and a 403 insufficient_scope can arrive in that
/// shape (www-authenticate `error="insufficient_scope"`); letting it reach the
/// 401 refresh+retry path would waste a request that must 403 again.
@visibleForTesting
bool googleDriveErrorIsInsufficientScope(Object error) {
  if (error is drive.DetailedApiRequestError) {
    if (error.status != 403) return false;
    final String m = (error.message ?? '').toLowerCase();
    return m.contains('insufficient_scope') ||
        m.contains('insufficientpermissions') ||
        m.contains('insufficient permission');
  }
  if (error is auth.AccessDeniedException) {
    return error.toString().toLowerCase().contains('insufficient_scope');
  }
  return false;
}

typedef FolderCache = Map<String, String>;

class GoogleDriveHandler {
  GoogleDriveHandler._();
  static final GoogleDriveHandler instance = GoogleDriveHandler._();

  String? _rootFolderId;
  final FolderCache _titleToFolderId = {};
  drive.DriveApi? _cachedApi;

  void clearCache() {
    _rootFolderId = null;
    _titleToFolderId.clear();
    _cachedApi = null;
  }

  /// 按 folderId 反查并逐出书名→folderId 缓存里所有指向 [folderId] 的条目。
  /// 删除某本书的远端文件夹后调用，消除「书名仍映射到已删/已 trash folderId」的
  /// 陈旧态（BUG-202）。同一 folderId 理论上只对一个书名，但反查删全保险。
  void evictFolderId(String folderId) {
    _titleToFolderId.removeWhere((_, id) => id == folderId);
  }

  void restoreCache({String? rootFolderId, FolderCache? titleToFolderId}) {
    _rootFolderId = rootFolderId;
    if (titleToFolderId != null) {
      _titleToFolderId.addAll(titleToFolderId);
    }
  }

  String? get cachedRootFolderId => _rootFolderId;
  FolderCache get cachedFolderIds => Map.unmodifiable(_titleToFolderId);

  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final f in folders) {
      _titleToFolderId[f.name] = f.id;
    }
  }

  // ── API client ────────────────────────────────────────────────────

  Future<drive.DriveApi> _api() async {
    if (_cachedApi != null) return _cachedApi!;
    final client = await GoogleDriveAuth.instance.getAuthClient();
    _cachedApi = drive.DriveApi(client);
    return _cachedApi!;
  }

  Future<T> _call<T>(Future<T> Function(drive.DriveApi api) fn) async {
    try {
      return await fn(await _api());
    } on GoogleDriveAuthError {
      rethrow;
    } catch (e) {
      if (googleDriveErrorIsInsufficientScope(e)) {
        // TODO-836: the grant is missing drive.appdata (an old drive.file-only
        // token). Refreshing the access token cannot add a scope, so do NOT
        // retry — throw a stable 403 marker the backend turns into a
        // SyncAuthError to trigger signOut + re-consent. Checked before the
        // unauthorized branch: a 403 insufficient_scope can arrive as an
        // AccessDeniedException, which googleDriveErrorIsUnauthorized would
        // otherwise route into the pointless refresh+retry path.
        throw GoogleDriveError(
            'insufficient_scope: re-consent required (scope upgraded to '
            'drive.appdata)',
            statusCode: 403);
      }
      if (!googleDriveErrorIsUnauthorized(e)) {
        if (e is drive.DetailedApiRequestError) {
          throw GoogleDriveError(e.message ?? 'API error',
              statusCode: e.status);
        }
        rethrow;
      }
      // Expired/rejected access token: the cached client carries a stale token.
      // Drop it, refresh, and retry once with a freshly-tokened client. The
      // expiry can arrive as either a DetailedApiRequestError(401) or an
      // auth.AccessDeniedException (www-authenticate 401), so both reach here
      // via googleDriveErrorIsUnauthorized (BUG-060).
      _cachedApi = null;
      await GoogleDriveAuth.instance.refreshAuth();
      try {
        return await fn(await _api());
      } on GoogleDriveAuthError {
        rethrow;
      } catch (retry) {
        // The refreshed token was also rejected — drop the cached api so the
        // next call rebuilds it instead of reusing the poisoned client
        // (HBK-AUDIT-168).
        _cachedApi = null;
        if (googleDriveErrorIsInsufficientScope(retry)) {
          // Same as the initial path (TODO-836): a refreshed token still can't
          // gain a scope, so surface the stable 403 marker rather than a
          // generic retry failure. Kept symmetric with the pre-retry check.
          throw GoogleDriveError(
              'insufficient_scope: re-consent required (scope upgraded to '
              'drive.appdata)',
              statusCode: 403);
        }
        if (retry is drive.DetailedApiRequestError) {
          throw GoogleDriveError(retry.message ?? 'Retry failed',
              statusCode: retry.status);
        }
        if (googleDriveErrorIsUnauthorized(retry)) {
          throw GoogleDriveError(retry.toString(), statusCode: 401);
        }
        rethrow;
      }
    }
  }

  // ── Folder operations ─────────────────────────────────────────────

  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    return _call((api) async {
      final list = await api.files.list(
        // TODO-836: query the hidden App Data space, not the visible Drive.
        spaces: 'appDataFolder',
        q: "trashed=false and mimeType='application/vnd.google-apps.folder' "
            "and name='$kSyncRootFolderName'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        _rootFolderId = list.files!.first.id!;
        return _rootFolderId!;
      }

      final created = await api.files.create(
        drive.File()
          ..name = kSyncRootFolderName
          ..mimeType = 'application/vnd.google-apps.folder'
          // TODO-836: 'appDataFolder' is the reserved alias for the App Data
          // space root; this anchors the sync root inside the hidden space.
          ..parents = ['appDataFolder'],
      );
      _rootFolderId = created.id!;
      return _rootFolderId!;
    });
  }

  Future<List<DriveFile>> listBooks(String rootFolder) async {
    final q = _escapeQuery(rootFolder);
    return _call((api) async {
      final results = <DriveFile>[];
      String? pageToken;

      do {
        final list = await api.files.list(
          // TODO-836: subqueries with `in parents` still default to the visible
          // Drive space and return EMPTY in appDataFolder unless spaces is set.
          spaces: 'appDataFolder',
          q: "trashed=false and '$q' in parents "
              "and mimeType='application/vnd.google-apps.folder'",
          $fields: 'nextPageToken,files(id,name)',
          pageSize: 1000,
          pageToken: pageToken,
        );
        if (list.files != null) {
          results.addAll(list.files!.map(_toDriveFile));
        }
        pageToken = list.nextPageToken;
      } while (pageToken != null);

      return results;
    });
  }

  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolder,
    Uint8List? coverData,
  }) async {
    final sanitized = sanitizeTtuFilename(bookTitle);

    // 双保险（BUG-202）：命中缓存仅在该 folderId 仍存在且未 trash 时才信任。
    // folderId 是不可变 ID，删后进回收站；陈旧命中会让上传打向 trashed 文件夹
    // 而永不回云。校验失败则丢弃陈旧条目，回退到下面的按名查/建。
    final cachedId = _titleToFolderId[sanitized];
    if (cachedId != null) {
      if (await _isFolderUsable(cachedId)) {
        return cachedId;
      }
      _titleToFolderId.remove(sanitized);
    }

    final qRoot = _escapeQuery(rootFolder);
    final qName = _escapeQuery(sanitized);

    return _call((api) async {
      final list = await api.files.list(
        spaces: 'appDataFolder', // TODO-836: search the App Data space.
        q: "trashed=false and '$qRoot' in parents "
            "and mimeType='application/vnd.google-apps.folder' "
            "and name='$qName'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        final id = list.files!.first.id!;
        _titleToFolderId[sanitized] = id;
        return id;
      }

      final created = await api.files.create(
        drive.File()
          ..name = sanitized
          ..mimeType = 'application/vnd.google-apps.folder'
          ..parents = [rootFolder],
      );

      final folderId = created.id!;
      _titleToFolderId[sanitized] = folderId;

      if (coverData != null) {
        try {
          await _uploadCover(api, folderId: folderId, coverData: coverData);
        } catch (e) {
          // HBK-AUDIT-089: 与 sync 模块其余文件统一用 debugPrint，
          // 避免 release 构建里残留 print 写平台日志。
          debugPrint('Cover upload failed: $e');
        }
      }

      return folderId;
    });
  }

  // ── Generic asset-store primitives ─────────────────────────────────

  static const _folderMimeType = 'application/vnd.google-apps.folder';

  /// Ensure a child folder named [name] exists under [parentId]; return its id.
  Future<String> ensureChildFolder(String parentId, String name) async {
    final qParent = _escapeQuery(parentId);
    final qName = _escapeQuery(name);

    return _call((api) async {
      final list = await api.files.list(
        spaces: 'appDataFolder', // TODO-836: search the App Data space.
        q: "trashed=false and '$qParent' in parents "
            "and mimeType='$_folderMimeType' "
            "and name='$qName'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        return list.files!.first.id!;
      }

      final created = await api.files.create(
        drive.File()
          ..name = name
          ..mimeType = _folderMimeType
          ..parents = [parentId],
      );
      return created.id!;
    });
  }

  /// List all direct children (files + folders) under [parentId] as
  /// [AssetEntry]s, with [AssetEntry.isFolder] derived from the Drive
  /// mimeType. DriveFile carries no mimeType, so we map straight from the
  /// raw `drive.File` here instead of widening DriveFile.
  Future<List<AssetEntry>> listChildrenRaw(String parentId) async {
    final qParent = _escapeQuery(parentId);
    return _call((api) async {
      final results = <AssetEntry>[];
      String? pageToken;

      do {
        final list = await api.files.list(
          spaces: 'appDataFolder', // TODO-836: search the App Data space.
          q: "'$qParent' in parents and trashed=false",
          $fields: 'nextPageToken,files(id,name,mimeType,size)',
          pageSize: 1000,
          pageToken: pageToken,
        );
        if (list.files != null) {
          for (final f in list.files!) {
            results.add(AssetEntry(
              id: f.id!,
              name: f.name!,
              isFolder: f.mimeType == _folderMimeType,
              sizeBytes: f.size != null ? int.tryParse(f.size!) : null,
            ));
          }
        }
        pageToken = list.nextPageToken;
      } while (pageToken != null);

      return results;
    });
  }

  /// Download and JSON-decode the content of [fileId]; null on empty.
  Future<Object?> downloadJsonById(String fileId) async {
    return _downloadJson(fileId);
  }

  /// Upsert a JSON file named [name] under [parentId] (utf8 of jsonEncode).
  Future<void> uploadJsonInFolder(
    String parentId,
    String name,
    Object? json,
  ) async {
    final existingId = await _findFileId(parentId, name);
    await _uploadJson(
      folderId: parentId,
      fileId: existingId,
      fileName: name,
      data: json,
    );
  }

  // ── Sync file operations ──────────────────────────────────────────

  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final q = _escapeQuery(folderId);
    return _call((api) async {
      final list = await api.files.list(
        spaces: 'appDataFolder', // TODO-836: search the App Data space.
        q: "trashed=false and '$q' in parents "
            "and mimeType!='application/vnd.google-apps.folder'",
        $fields: 'files(id,name)',
      );

      final files = list.files?.map(_toDriveFile).toList() ?? [];
      return DriveSyncFiles(
        progress: _findByPrefix(files, 'progress_'),
        statistics: _findByPrefix(files, 'statistics_'),
        audioBook: _findByPrefix(files, 'audioBook_'),
      );
    });
  }

  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _uploadJson(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      data: progress.toJson(),
    );
  }

  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    final fileName = statisticsFileName(stats);
    await _uploadJson(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      data: stats.map((s) => s.toJson()).toList(),
    );
  }

  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _uploadJson(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      data: audioBook.toJson(),
    );
  }

  // ── Private helpers ───────────────────────────────────────────────

  static const _maxDownloadSize = 10 * 1024 * 1024; // 10 MB

  Future<dynamic> _downloadJson(String fileId) async {
    return _call((api) async {
      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final builder = BytesBuilder(copy: false);
      await for (final chunk in media.stream) {
        builder.add(chunk);
        if (builder.length > _maxDownloadSize) {
          throw GoogleDriveError('Response too large');
        }
      }
      return jsonDecode(utf8.decode(builder.takeBytes()));
    });
  }

  Future<void> _uploadJson({
    required String folderId,
    required String? fileId,
    required String fileName,
    required dynamic data,
  }) async {
    final bytes = utf8.encode(jsonEncode(data));

    await _call((api) async {
      final media = drive.Media(
        Stream.value(bytes),
        bytes.length,
        contentType: 'application/json',
      );

      if (fileId != null) {
        await api.files.update(
          drive.File()..name = fileName,
          fileId,
          uploadMedia: media,
        );
      } else {
        await api.files.create(
          drive.File()
            ..name = fileName
            ..parents = [folderId],
          uploadMedia: media,
        );
      }
    });
  }

  Future<void> _uploadCover(
    drive.DriveApi api, {
    required String folderId,
    required Uint8List coverData,
  }) async {
    final format = detectCoverFormat(coverData);
    final fileName = 'cover_1_6.${format.extension}';
    final media = drive.Media(
      Stream.value(coverData),
      coverData.length,
      contentType: format.mimeType,
    );

    await api.files.create(
      drive.File()
        ..name = fileName
        ..parents = [folderId],
      uploadMedia: media,
    );
  }

  // ── Content file operations ────────────────────────────────────────

  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final length = await file.length();
    final contentType = _guessContentType(fileName);

    final existingId = await _findFileId(folderId, fileName);

    await _call((api) async {
      int bytesUploaded = 0;
      final stream = file.openRead().map((chunk) {
        bytesUploaded += chunk.length;
        onProgress?.call(length > 0 ? bytesUploaded / length : 0);
        return chunk;
      });
      final media = drive.Media(stream, length, contentType: contentType);

      // Content assets (EPUBs, dictionary / audiobook / local-audio packages)
      // can be hundreds of MB to multiple GB (a 5.8 GB local-audio DB was seen
      // in the wild). The default upload is a SINGLE multipart POST of the whole
      // file: on a flaky link any blip drops the connection (→ timeout) and the
      // _call retry restarts the stream from byte 0, so a large upload never
      // completes; a multi-GB upload can also outlive the ~1h access-token
      // lifetime mid-request → 401. Resumable chunked upload fixes all three:
      // each chunk is retried with backoff and the token is refreshed between
      // chunks, so progress is never lost to a single hiccup (BUG-087).
      final drive.ResumableUploadOptions uploadOptions =
          drive.ResumableUploadOptions(
        numberOfAttempts: 5,
        chunkSize: 8 * 1024 * 1024,
      );

      if (existingId != null) {
        await api.files.update(
          drive.File()..name = fileName,
          existingId,
          uploadMedia: media,
          uploadOptions: uploadOptions,
        );
      } else {
        await api.files.create(
          drive.File()
            ..name = fileName
            ..parents = [folderId],
          uploadMedia: media,
          uploadOptions: uploadOptions,
        );
      }
    });
  }

  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    await _call((api) async {
      final metadata = await api.files.get(
        fileId,
        $fields: 'size',
      ) as drive.File;
      final totalSize =
          metadata.size != null ? int.tryParse(metadata.size!) : null;

      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final sink = destination.openWrite();
      int bytesDownloaded = 0;
      bool success = false;
      try {
        await for (final chunk in media.stream) {
          sink.add(chunk);
          bytesDownloaded += chunk.length;
          if (totalSize != null && totalSize > 0) {
            onProgress?.call(bytesDownloaded / totalSize);
          }
        }
        success = true;
      } finally {
        await sink.close();
        if (!success) {
          try {
            destination.deleteSync();
          } catch (e) {
            debugPrint('[sync] failed to clean up temp file: $e');
          }
        }
      }
    });
  }

  Future<DriveFile?> findContentFile(
    String folderId,
    String fileName,
  ) async {
    return _findFile(folderId, fileName);
  }

  /// 永久删除 [fileId]（文件或文件夹；文件夹递归删内容）。不存在时 Drive 返回 404，
  /// 由调用方按幂等吞掉（`GoogleDriveError.isStaleCacheError`）。
  Future<void> deleteFile(String fileId) async {
    await _call<void>((api) => api.files.delete(fileId));
  }

  /// 该 [folderId] 是否仍可用作书文件夹：存在且未 trash。
  /// 用于 `ensureBookFolder` 校验缓存命中（BUG-202）。404/已删/已 trash → false，
  /// 调用方据此丢弃陈旧缓存条目并重新按名查/建。其它错误（网络/权限）保守返回
  /// true，不因瞬时故障误删缓存。
  Future<bool> _isFolderUsable(String folderId) async {
    try {
      return await _call((api) async {
        final file = await api.files.get(
          folderId,
          $fields: 'id,trashed',
        ) as drive.File;
        return file.trashed != true;
      });
    } on GoogleDriveError catch (e) {
      if (e.isStaleCacheError) return false; // 404：已不存在。
      return true; // 其它错误保守信任缓存，避免瞬时故障误删。
    } catch (_) {
      return true;
    }
  }

  Future<DriveFile?> _findFile(String folderId, String fileName) async {
    final qFolder = _escapeQuery(folderId);
    final qName = _escapeQuery(fileName);
    return _call((api) async {
      final list = await api.files.list(
        spaces: 'appDataFolder', // TODO-836: search the App Data space.
        q: "trashed=false and '$qFolder' in parents and name='$qName'",
        $fields: 'files(id,name)',
      );
      if (list.files != null && list.files!.isNotEmpty) {
        return _toDriveFile(list.files!.first);
      }
      return null;
    });
  }

  Future<String?> _findFileId(String folderId, String fileName) async {
    final file = await _findFile(folderId, fileName);
    return file?.id;
  }

  static String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.m4b') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  static String _escapeQuery(String value) => value.replaceAll("'", "\\'");

  static DriveFile _toDriveFile(drive.File f) =>
      DriveFile(id: f.id!, name: f.name!);

  static DriveFile? _findByPrefix(List<DriveFile> files, String prefix) {
    for (final f in files) {
      if (f.name.startsWith(prefix)) return f;
    }
    return null;
  }
}
