import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:hibiki/src/sync/google_drive_auth.dart';
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

  void restoreCache({String? rootFolderId, FolderCache? titleToFolderId}) {
    _rootFolderId = rootFolderId;
    if (titleToFolderId != null) {
      _titleToFolderId.addAll(titleToFolderId);
    }
  }

  String? get cachedRootFolderId => _rootFolderId;
  FolderCache get cachedFolderIds => Map.unmodifiable(_titleToFolderId);

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
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 401) {
        _cachedApi = null;
        try {
          return await fn(await _api());
        } on drive.DetailedApiRequestError catch (retry) {
          throw GoogleDriveError(retry.message ?? 'Retry failed',
              statusCode: retry.status);
        }
      }
      throw GoogleDriveError(e.message ?? 'API error', statusCode: e.status);
    } on GoogleDriveAuthError {
      rethrow;
    }
  }

  // ── Folder operations ─────────────────────────────────────────────

  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    return _call((api) async {
      final list = await api.files.list(
        q: "trashed=false and mimeType='application/vnd.google-apps.folder' "
            "and name='ttu-reader-data'",
        $fields: 'files(id,name)',
      );

      if (list.files != null && list.files!.isNotEmpty) {
        _rootFolderId = list.files!.first.id!;
        return _rootFolderId!;
      }

      final created = await api.files.create(
        drive.File()
          ..name = 'ttu-reader-data'
          ..mimeType = 'application/vnd.google-apps.folder',
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

    if (_titleToFolderId.containsKey(sanitized)) {
      return _titleToFolderId[sanitized]!;
    }

    final qRoot = _escapeQuery(rootFolder);
    final qName = _escapeQuery(sanitized);

    return _call((api) async {
      final list = await api.files.list(
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
          assert(() {
            // ignore: avoid_print
            print('Cover upload failed: $e');
            return true;
          }());
        }
      }

      return folderId;
    });
  }

  // ── Sync file operations ──────────────────────────────────────────

  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final q = _escapeQuery(folderId);
    return _call((api) async {
      final list = await api.files.list(
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

  Future<dynamic> _downloadJson(String fileId) async {
    return _call((api) async {
      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes));
    });
  }

  Future<void> _uploadJson({
    required String folderId,
    required String? fileId,
    required String fileName,
    required dynamic data,
  }) async {
    final bytes = utf8.encode(jsonEncode(data));
    final media = drive.Media(
      Stream.value(bytes),
      bytes.length,
      contentType: 'application/json',
    );

    await _call((api) async {
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
