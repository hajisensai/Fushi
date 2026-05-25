import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

  final _auth = GoogleDriveAuth.instance;
  final _dio = Dio(BaseOptions(
    baseUrl: 'https://www.googleapis.com',
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));

  void clearCache() {
    _rootFolderId = null;
    _titleToFolderId.clear();
  }

  void restoreCache({String? rootFolderId, FolderCache? titleToFolderId}) {
    _rootFolderId = rootFolderId;
    if (titleToFolderId != null) {
      _titleToFolderId.addAll(titleToFolderId);
    }
  }

  String? get cachedRootFolderId => _rootFolderId;
  FolderCache get cachedFolderIds => Map.unmodifiable(_titleToFolderId);

  // ── Core request wrapper ──────────────────────────────────────────

  Future<Response<dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Options? options,
    bool retry = true,
  }) async {
    final accessToken = await _auth.getAccessToken();
    final opts = (options ?? Options()).copyWith(
      method: method,
      headers: {
        ...?options?.headers,
        'Authorization': 'Bearer $accessToken',
      },
    );

    try {
      return await _dio.request(
        path,
        queryParameters: queryParameters,
        data: data,
        options: opts,
      );
    } on DioError catch (e) {
      final status = e.response?.statusCode;

      if (status == 401 && retry) {
        final newToken = await _auth.refreshAccessToken();
        opts.headers!['Authorization'] = 'Bearer $newToken';
        try {
          return await _dio.request(
            path,
            queryParameters: queryParameters,
            data: data,
            options: opts,
          );
        } on DioError catch (retryErr) {
          final retryStatus = retryErr.response?.statusCode;
          if (retryStatus != null && retryStatus >= 400) {
            throw GoogleDriveError('Retry failed: $retryStatus',
                statusCode: retryStatus);
          }
          rethrow;
        }
      }

      if (status != null && status >= 400) {
        String message = 'Request failed with status $status';
        final responseData = e.response?.data;
        if (responseData is Map<String, dynamic>) {
          final error = responseData['error'];
          if (error is Map<String, dynamic>) {
            message = error['message'] as String? ?? message;
          }
        }
        throw GoogleDriveError(message, statusCode: status);
      }
      rethrow;
    }
  }

  // ── Folder operations ─────────────────────────────────────────────

  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    final response = await _request('GET', '/drive/v3/files', queryParameters: {
      'q':
          "trashed=false and mimeType='application/vnd.google-apps.folder' and name = 'ttu-reader-data'",
      'fields': 'files(id, name)',
    });

    final list = DriveFileList.fromJson(response.data as Map<String, dynamic>);
    if (list.files.isNotEmpty) {
      _rootFolderId = list.files.first.id;
      return _rootFolderId!;
    }

    final createResponse = await _request('POST', '/drive/v3/files',
        data: {
          'name': 'ttu-reader-data',
          'mimeType': 'application/vnd.google-apps.folder',
        },
        options: Options(contentType: Headers.jsonContentType));

    final created = createResponse.data as Map<String, dynamic>;
    _rootFolderId = created['id'] as String;
    return _rootFolderId!;
  }

  Future<List<DriveFile>> listBooks(String rootFolder) async {
    final response = await _request('GET', '/drive/v3/files', queryParameters: {
      'q':
          "trashed=false and '$rootFolder' in parents and mimeType='application/vnd.google-apps.folder'",
      'fields': 'files(id, name)',
    });
    return DriveFileList.fromJson(response.data as Map<String, dynamic>).files;
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

    final searchResponse =
        await _request('GET', '/drive/v3/files', queryParameters: {
      'q':
          '''trashed=false and '$rootFolder' in parents and mimeType='application/vnd.google-apps.folder' and name="$sanitized"''',
      'fields': 'files(id, name)',
    });

    final searchResult =
        DriveFileList.fromJson(searchResponse.data as Map<String, dynamic>);

    if (searchResult.files.isNotEmpty) {
      final id = searchResult.files.first.id;
      _titleToFolderId[sanitized] = id;
      return id;
    }

    final createResponse = await _request('POST', '/drive/v3/files',
        data: {
          'name': sanitized,
          'mimeType': 'application/vnd.google-apps.folder',
          'parents': [rootFolder],
        },
        options: Options(contentType: Headers.jsonContentType));

    final folderId =
        (createResponse.data as Map<String, dynamic>)['id'] as String;
    _titleToFolderId[sanitized] = folderId;

    if (coverData != null) {
      try {
        await _uploadCoverImage(folderId: folderId, coverData: coverData);
      } catch (_) {
        // Non-fatal: cover upload failure doesn't block sync
      }
    }

    return folderId;
  }

  // ── Sync file operations ──────────────────────────────────────────

  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final response = await _request('GET', '/drive/v3/files', queryParameters: {
      'q':
          "trashed=false and '$folderId' in parents and mimeType != 'application/vnd.google-apps.folder'",
      'fields': 'files(id, name)',
    });

    final files =
        DriveFileList.fromJson(response.data as Map<String, dynamic>).files;

    return DriveSyncFiles(
      progress: _findByPrefix(files, 'progress_'),
      statistics: _findByPrefix(files, 'statistics_'),
      audioBook: _findByPrefix(files, 'audioBook_'),
    );
  }

  Future<TtuProgress> getProgressFile(String fileId) async {
    final response = await _request('GET', '/drive/v3/files/$fileId',
        queryParameters: {'alt': 'media'});
    return TtuProgress.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final response = await _request('GET', '/drive/v3/files/$fileId',
        queryParameters: {'alt': 'media'});
    return (response.data as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final response = await _request('GET', '/drive/v3/files/$fileId',
        queryParameters: {'alt': 'media'});
    return TtuAudioBook.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    final timestamp = (progress.lastBookmarkModified).toInt();
    final fileName = progressFileName(timestamp, progress.progress);
    await _uploadSyncFile(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      jsonData: progress.toJson(),
    );
  }

  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    final fileName = statisticsFileName(stats);
    await _uploadSyncFile(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      jsonData: stats.map((s) => s.toJson()).toList(),
    );
  }

  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _uploadSyncFile(
      folderId: folderId,
      fileId: fileId,
      fileName: fileName,
      jsonData: audioBook.toJson(),
    );
  }

  // ── Private helpers ───────────────────────────────────────────────

  Future<void> _uploadSyncFile({
    required String folderId,
    required String? fileId,
    required String fileName,
    required dynamic jsonData,
  }) async {
    final boundary = 'hibiki_sync_${DateTime.now().millisecondsSinceEpoch}';
    final contentBytes = _jsonBytes(jsonData);

    final Map<String, dynamic> metadata;
    final String url;
    final String method;

    if (fileId != null) {
      url = '/upload/drive/v3/files/$fileId';
      method = 'PATCH';
      metadata = {'name': fileName};
    } else {
      url = '/upload/drive/v3/files';
      method = 'POST';
      metadata = {
        'name': fileName,
        'parents': [folderId]
      };
    }

    final metadataBytes = _jsonBytes(metadata);

    final body = <int>[
      ...'--$boundary\r\n'.codeUnits,
      ...'Content-Type: application/json; charset=UTF-8\r\n\r\n'.codeUnits,
      ...metadataBytes,
      ...'\r\n--$boundary\r\n'.codeUnits,
      ...'Content-Type: application/json\r\n\r\n'.codeUnits,
      ...contentBytes,
      ...'\r\n--$boundary--\r\n'.codeUnits,
    ];

    await _request(
      method,
      url,
      queryParameters: {'uploadType': 'multipart'},
      data: Stream.value(Uint8List.fromList(body)),
      options: Options(
        contentType: 'multipart/related; boundary=$boundary',
        headers: {'Content-Length': body.length},
      ),
    );
  }

  Future<void> _uploadCoverImage({
    required String folderId,
    required Uint8List coverData,
  }) async {
    final format = detectCoverFormat(coverData);
    final fileName = 'cover_1_6.${format.extension}';
    final boundary = 'hibiki_cover_${DateTime.now().millisecondsSinceEpoch}';

    final metadata = _jsonBytes({
      'name': fileName,
      'parents': [folderId]
    });

    final body = <int>[
      ...'--$boundary\r\n'.codeUnits,
      ...'Content-Type: application/json; charset=UTF-8\r\n\r\n'.codeUnits,
      ...metadata,
      ...'\r\n--$boundary\r\n'.codeUnits,
      ...'Content-Type: ${format.mimeType}\r\n\r\n'.codeUnits,
      ...coverData,
      ...'\r\n--$boundary--\r\n'.codeUnits,
    ];

    await _request(
      'POST',
      '/upload/drive/v3/files',
      queryParameters: {'uploadType': 'multipart'},
      data: Stream.value(Uint8List.fromList(body)),
      options: Options(
        contentType: 'multipart/related; boundary=$boundary',
        headers: {'Content-Length': body.length},
      ),
    );
  }

  static DriveFile? _findByPrefix(List<DriveFile> files, String prefix) {
    for (final f in files) {
      if (f.name.startsWith(prefix)) return f;
    }
    return null;
  }

  static Uint8List _jsonBytes(dynamic data) {
    final str = data is String ? data : jsonEncode(data);
    return Uint8List.fromList(utf8.encode(str));
  }
}
