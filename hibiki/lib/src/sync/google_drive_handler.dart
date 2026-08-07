import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:fushi/src/sync/google_drive_auth.dart';
import 'package:fushi/src/sync/google_drive_sync_space.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:fushi/src/sync/sync_transient_error.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';

class GoogleDriveError implements Exception {
  GoogleDriveError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  bool get isStaleCacheError => statusCode == 404;

  /// 瞬时后端故障：超时/限流/网关抖动，轮内重试一次通常即成功（与 Google Drive
  /// API 官方退避重试建议的状态码集一致，BUG-1023）。**显式排除 507 Insufficient
  /// Storage**——配额耗尽不是瞬时问题，重试无益，须继续走 skip 路径而非空转重试。
  bool get isTransientError =>
      statusCode == 408 || // Request Timeout
      statusCode == 429 || // Too Many Requests（限流）
      statusCode == 500 || // Internal Server Error
      statusCode == 502 || // Bad Gateway
      statusCode == 503 || // Service Unavailable
      statusCode == 504; // Gateway Timeout

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

class GoogleDriveHandler with SyncFolderCache, SyncBackendFileTrioMixin {
  GoogleDriveHandler._();
  static final GoogleDriveHandler instance = GoogleDriveHandler._();

  drive.DriveApi? _cachedApi;

  /// 当前 Drive 存储空间 + scope。默认隐藏 appDataFolder；「Hoshi 兼容模式」开启时
  /// 切到可见 My Drive / `ttu-reader-data`（见 [GoogleDriveSyncSpace]）。所有
  /// `files.list` 的 `spaces`、根文件夹的 parent/名字都从这里取，消除散落分支。
  GoogleDriveSyncSpace _space = GoogleDriveSyncSpace.appData;

  GoogleDriveSyncSpace get syncSpace => _space;

  /// 切换存储空间。变更时清缓存：根/书文件夹 id 与 DriveApi 句柄都归属旧空间，换空间后
  /// 若复用会拿旧空间的 folderId 打新空间的请求，必须重建（[clearCache] 覆写会连
  /// `_cachedApi` 一起清）。
  void setSyncSpace(GoogleDriveSyncSpace space) {
    if (space.id == _space.id) return;
    _space = space;
    clearCache();
  }

  // 缓存字段（rootFolderIdCache / folderIdCache）+ restoreCache /
  // cachedRootFolderId / cachedFolderIds / cacheBookFolderIds / evictFolderId
  // 收敛进 [SyncFolderCache] mixin（恒等 folderId，无尾斜杠规范化）。clearCache 额外
  // 清掉本地缓存的 DriveApi 句柄，故覆写并 super 调用。
  @override
  void clearCache() {
    super.clearCache();
    _cachedApi = null;
  }

  // ── API client ────────────────────────────────────────────────────

  Future<drive.DriveApi> _api() async {
    if (_cachedApi != null) return _cachedApi!;
    final client = await GoogleDriveAuth.instance.getAuthClient();
    _cachedApi = drive.DriveApi(client);
    return _cachedApi!;
  }

  /// Every Drive request funnels through here. Wraps [_callOnce] (which owns the
  /// auth-refresh single retry) in a bounded transient-error retry-with-backoff:
  /// a `SocketException` / timeout (信号灯超时) on any op — folder ensure, list,
  /// JSON download, overwrite-by-name upload — recovers in place instead of
  /// throwing raw past `_wrapErrors` and abandoning the whole sync round with
  /// zero retries (BUG-864). Permanent errors (auth / scope / 4xx) are not
  /// transient, so [retryTransientSync] re-throws them immediately without
  /// burning attempts; the retried ops are all idempotent so a repeat is safe.
  Future<T> _call<T>(Future<T> Function(drive.DriveApi api) fn) {
    return retryTransientSync<T>(() => _callOnce<T>(fn));
  }

  Future<T> _callOnce<T>(Future<T> Function(drive.DriveApi api) fn) async {
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
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    return _call((api) async {
      final list = await api.files.list(
        // 隐藏 appDataFolder 空间下必须显式带 spaces；可见 My Drive 模式用 'drive'
        // （[GoogleDriveSyncSpace]，TODO-836）。
        spaces: _space.spaces,
        q: "trashed=false and mimeType='application/vnd.google-apps.folder' "
            "and name='${_space.rootFolderName}'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        rootFolderIdCache = list.files!.first.id!;
        return rootFolderIdCache!;
      }

      final created = await api.files.create(
        drive.File()
          ..name = _space.rootFolderName
          ..mimeType = 'application/vnd.google-apps.folder'
          // parent 别名：appDataFolder（隐藏空间根）或 root（My Drive 根），把同步
          // 根锚进当前空间（[GoogleDriveSyncSpace.rootParent]）。
          ..parents = [_space.rootParent],
      );
      rootFolderIdCache = created.id!;
      return rootFolderIdCache!;
    });
  }

  Future<List<SyncFileRef>> listBooks(String rootFolder) async {
    final q = _escapeQuery(rootFolder);
    return _call((api) async {
      final results = <SyncFileRef>[];
      String? pageToken;

      do {
        final list = await api.files.list(
          // `in parents` 子查询默认落可见 Drive 空间，在 appDataFolder 里必须显式
          // 带 spaces 否则返回空（[GoogleDriveSyncSpace]，TODO-836）。
          spaces: _space.spaces,
          q: "trashed=false and '$q' in parents "
              "and mimeType='application/vnd.google-apps.folder'",
          $fields: 'nextPageToken,files(id,name)',
          pageSize: 1000,
          pageToken: pageToken,
        );
        if (list.files != null) {
          results.addAll(list.files!.map(_toSyncFileRef));
        }
        pageToken = list.nextPageToken;
      } while (pageToken != null);

      return results;
    });
  }

  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolder,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final sanitized = requireBookFolderName(bookTitle);

    // 双保险（BUG-202）：命中缓存仅在该 folderId 仍存在且未 trash 时才信任。
    // folderId 是不可变 ID，删后进回收站；陈旧命中会让上传打向 trashed 文件夹
    // 而永不回云。校验失败则丢弃陈旧条目，回退到下面的按名查/建。
    final cachedId = folderIdCache[sanitized];
    if (cachedId != null) {
      if (await _isFolderUsable(cachedId)) {
        return cachedId;
      }
      folderIdCache.remove(sanitized);
    }

    final qRoot = _escapeQuery(rootFolder);
    final qName = _escapeQuery(sanitized);

    return _call((api) async {
      final list = await api.files.list(
        spaces: _space.spaces, // [GoogleDriveSyncSpace]: 当前空间（appdata/drive）。
        q: "trashed=false and '$qRoot' in parents "
            "and mimeType='application/vnd.google-apps.folder' "
            "and name='$qName'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        final id = list.files!.first.id!;
        folderIdCache[sanitized] = id;
        return id;
      }

      final created = await api.files.create(
        drive.File()
          ..name = sanitized
          ..mimeType = 'application/vnd.google-apps.folder'
          ..parents = [rootFolder],
      );

      final folderId = created.id!;
      folderIdCache[sanitized] = folderId;

      final Uint8List? coverData = await readCoverData?.call();
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
        spaces: _space.spaces, // [GoogleDriveSyncSpace]: 当前空间（appdata/drive）。
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
  /// mimeType. SyncFileRef carries no mimeType, so we map straight from the
  /// raw `drive.File` here instead of widening SyncFileRef.
  Future<List<AssetEntry>> listChildrenRaw(String parentId) async {
    final qParent = _escapeQuery(parentId);
    return _call((api) async {
      final results = <AssetEntry>[];
      String? pageToken;

      do {
        final list = await api.files.list(
          spaces: _space.spaces, // [GoogleDriveSyncSpace]: 当前空间（appdata/drive）。
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

  /// 一次列举整个同步空间：不按 parent 逐个查，而是一次把空间里所有非回收站条目
  /// 连同它们的 `parents` 拉下来，本地按 parent 归位。
  ///
  /// Drive 的配额与延迟都是**按请求**算的，一次 1000 条分页远比 500 次单 parent 查询
  /// 便宜。字段只取 id/name/parents/mimeType——不要内容、不要时间戳，因为同步方向本来
  /// 就只看文件名（progress 的时间戳与分数编码在名字里）。
  Future<RemoteListingSnapshot?> snapshotListing(String rootFolder) async {
    // 只在隐藏的 App Data 空间启用。那个空间按 app 隔离，里面除了 Hibiki 自己的同步
    // 数据什么都没有，所以「列出空间里的全部文件」等价于「列出同步根下的全部文件」。
    //
    // 「与 Hoshi/ッツ 共享」开关打开时空间是用户**可见的 My Drive**（完整 drive
    // scope）。在那里做同一件事就成了列举用户的整个云盘——几万个文件、几十次分页、
    // 白白烧掉配额，而其中与同步有关的可能只有几十个。Drive 的 `q` 又没有「递归在某
    // 文件夹下」的写法，凑不出一个既便宜又只覆盖同步根的查询。
    //
    // 这正是 `snapshotListing` 允许返回 null 的意义：拿不到**廉价**的全貌就不硬拿，
    // 共享模式照旧逐本列举。
    if (_space.id != GoogleDriveSyncSpace.appData.id) return null;

    try {
      return await _call((api) async {
        final Map<String, String> folderNameById = <String, String>{};
        final List<
                ({String id, String name, List<String> parents, bool isFolder})>
            all =
            <({String id, String name, List<String> parents, bool isFolder})>[];

        String? pageToken;
        do {
          final list = await api.files.list(
            // appDataFolder 里不显式带 spaces 会返回空（[GoogleDriveSyncSpace]，
            // TODO-836）——与 listBooks 同一约束。
            spaces: _space.spaces,
            q: 'trashed=false',
            $fields: 'nextPageToken,files(id,name,parents,mimeType)',
            pageSize: 1000,
            pageToken: pageToken,
          );
          for (final f in list.files ?? const []) {
            final String? id = f.id;
            final String? name = f.name;
            if (id == null || name == null) continue;
            final bool isFolder =
                f.mimeType == 'application/vnd.google-apps.folder';
            final List<String> parents = f.parents ?? const <String>[];
            if (isFolder) folderNameById[id] = name;
            all.add((id: id, name: name, parents: parents, isFolder: isFolder));
          }
          pageToken = list.nextPageToken;
        } while (pageToken != null);

        // 同步根的直接子文件夹先登记，空文件夹才能与「不存在的文件夹」区分开。
        final Set<String> topFolderIds = <String>{};
        final RemoteListingBuilder builder = RemoteListingBuilder();
        for (final e in all) {
          if (!e.isFolder) continue;
          if (!e.parents.contains(rootFolder)) continue;
          topFolderIds.add(e.id);
          builder.addFolder(e.name);
        }

        for (final e in all) {
          for (final String parent in e.parents) {
            if (!topFolderIds.contains(parent)) continue;
            builder.addEntry(
              parentName: folderNameById[parent] ?? '',
              name: e.name,
              id: e.id,
              isFolder: e.isFolder,
            );
          }
        }
        return builder.build();
      });
    } catch (e) {
      debugPrint('[drive] snapshotListing failed, falling back: $e');
      return null;
    }
  }

  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final q = _escapeQuery(folderId);
    return _call((api) async {
      final list = await api.files.list(
        spaces: _space.spaces, // [GoogleDriveSyncSpace]: 当前空间（appdata/drive）。
        q: "trashed=false and '$q' in parents "
            "and mimeType!='application/vnd.google-apps.folder'",
        $fields: 'files(id,name)',
      );

      final files = list.files?.map(_toSyncFileRef).toList() ?? [];
      return SyncFileTrio(
        progress: _findByPrefix(files, 'progress_'),
        statistics: _findByPrefix(files, 'statistics_'),
        audioBook: _findByPrefix(files, 'audioBook_'),
      );
    });
  }

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出 Google Drive 的下载原语（size-capped fullMedia GET + jsonDecode）。
  @override
  Future<Object?> readJsonById(String fileId) => _downloadJson(fileId);

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

      await writeSyncStreamToFile(
        source: media.stream,
        destination: destination,
        totalBytes: totalSize,
        onProgress: onProgress,
        onCleanupError: (e) =>
            debugPrint('[sync] failed to clean up temp file: $e'),
      );
    });
  }

  Future<SyncFileRef?> findContentFile(
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

  Future<SyncFileRef?> _findFile(String folderId, String fileName) async {
    final qFolder = _escapeQuery(folderId);
    final qName = _escapeQuery(fileName);
    return _call((api) async {
      final list = await api.files.list(
        spaces: _space.spaces, // [GoogleDriveSyncSpace]: 当前空间（appdata/drive）。
        q: "trashed=false and '$qFolder' in parents and name='$qName'",
        $fields: 'files(id,name)',
      );
      if (list.files != null && list.files!.isNotEmpty) {
        return _toSyncFileRef(list.files!.first);
      }
      return null;
    });
  }

  Future<String?> _findFileId(String folderId, String fileName) async {
    final file = await _findFile(folderId, fileName);
    return file?.id;
  }

  static String _guessContentType(String fileName) =>
      guessSyncContentType(fileName);

  static String _escapeQuery(String value) => value.replaceAll("'", "\\'");

  static SyncFileRef _toSyncFileRef(drive.File f) =>
      SyncFileRef(id: f.id!, name: f.name!);

  static SyncFileRef? _findByPrefix(List<SyncFileRef> files, String prefix) {
    for (final f in files) {
      if (f.name.startsWith(prefix)) return f;
    }
    return null;
  }
}
