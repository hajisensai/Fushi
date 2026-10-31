import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_root_migration.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// [FtpSyncBackend.listChildren] 逐个 MDTM 的文件数上限：超过就不取（每个文件一次往返）。
const int kFtpListMdtmLimit = 50;

/// MDTM 应答正文 → UTC 毫秒。
///
/// RFC 3659 §3：`213 YYYYMMDDHHMMSS[.sss]`，时间**一律 UTC**。[message] 可以带也可以不带
/// 开头的 `213 `（ftpconnect 的 [FTPReply.message] 是整行）。格式不符或日期非法返回 null。
int? ftpMdtmReplyToMs(String message) {
  final RegExpMatch? m = _kMdtmReply.firstMatch(message.trim());
  if (m == null) return null;
  final String d = m.group(1)!;
  final int year = int.parse(d.substring(0, 4));
  final int month = int.parse(d.substring(4, 6));
  final int day = int.parse(d.substring(6, 8));
  final int hour = int.parse(d.substring(8, 10));
  final int minute = int.parse(d.substring(10, 12));
  final int second = int.parse(d.substring(12, 14));
  final String frac = m.group(2) ?? '';
  final int millis = frac.isEmpty
      ? 0
      : int.parse(frac.padRight(3, '0').substring(0, 3));
  final DateTime t = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    millis,
  );
  // DateTime.utc 会把越界字段进位（13 月 → 次年 1 月），进位了说明原串非法。
  if (t.year != year ||
      t.month != month ||
      t.day != day ||
      t.hour != hour ||
      t.minute != minute ||
      t.second != second) {
    return null;
  }
  return t.millisecondsSinceEpoch;
}

final RegExp _kMdtmReply = RegExp(r'^(?:213[ -])?\s*(\d{14})(?:\.(\d+))?$');

class FtpSyncBackend extends SyncBackend
    with SyncFolderCache, SyncBackendFileTrioMixin, SyncAssetStoreDefaults {
  FtpSyncBackend._();
  static final FtpSyncBackend instance = FtpSyncBackend._();

  /// The login directory captured via PWD on connect (the user's home, or the
  /// chroot root). Defaults to '/' until connected.
  ///
  /// NOTE: the persisted folder cache (rootFolderId / titleToFolderId) embeds
  /// this home-anchored absolute path. If the same (host, user) ever reports a
  /// different home across sessions, restored cache entries become stale — but
  /// the op then throws a retryable error and SyncManager clears the cache and
  /// reconnects, which re-captures PWD. So it self-heals; it is not persisted
  /// data loss.
  String _homeDir = '/';

  /// Sync root, anchored UNDER the login home — never the raw server root. A
  /// chrooted server reports PWD '/', so this lands at '/$kSyncRootFolderName';
  /// a normal server reports the real home, so the folder lands there instead
  /// of failing at '/'.
  String get _rootPath => ftpRootPath(_homeDir);

  /// Pure helper for [_rootPath]; exposed for testing. [name] 默认新根名，
  /// Fushi 改名迁移探测旧根时传 [kLegacySyncRootFolderName]。
  @visibleForTesting
  static String ftpRootPath(String home, [String name = kSyncRootFolderName]) {
    final String trimmed = home.replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/$name' : '$trimmed/$name';
  }

  /// Normalize a PWD reply into a clean directory path (strip surrounding
  /// quotes and trailing slashes; fall back to '/').
  static String _normalizeFtpDir(String raw) {
    var dir = raw.trim();
    if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
      dir = dir.substring(1, dir.length - 1);
    }
    dir = dir.replaceAll(RegExp(r'/+$'), '');
    return dir.isEmpty ? '/' : dir;
  }

  final _opLock = AsyncMutex();
  FTPConnect? _client;
  String? _host;
  int _port = 21;
  String? _username;
  String? _password;
  bool _useTls = false;
  bool _connected = false;

  // Collision-proof temp-file naming (HBK-AUDIT-087). A millisecond timestamp
  // is not unique: two ops in the same ms — or a second isolate/app instance
  // sharing systemTemp — produce identical paths and clobber each other's
  // in-flight transfer. The secure-random token + per-instance counter make
  // the name unique regardless of clock resolution or concurrent callers.
  static final Random _tempRng = Random.secure();
  int _tempCounter = 0;

  /// Build a collision-proof temp path under [Directory.systemTemp] for the
  /// given [prefix]/[extension]. Combines a per-instance counter with a
  /// secure-random suffix so concurrent or sub-millisecond callers never
  /// collide (HBK-AUDIT-087).
  File _uniqueTempFile(String prefix, String extension) {
    final int seq = _tempCounter++;
    final int token = _tempRng.nextInt(1 << 32);
    final String name =
        'fushi_${prefix}_${seq}_${token.toRadixString(16)}$extension';
    return File('${Directory.systemTemp.path}/$name');
  }

  // ── Auth ──────────────────────────────────────────────────────────

  /// Normalize stored credentials for an FTP login. Only the host is truly
  /// required; an empty/null username means anonymous FTP (`anonymous` with an
  /// empty password), and a server that needs a username but no password is
  /// honored too. Centralized so [testConnection] and [_connect] behave
  /// identically instead of the old split where the widget test passed empty
  /// creds through but [_connect] hard-rejected them (BUG-1016).
  @visibleForTesting
  static ({String user, String pass}) ftpLoginCredentials(
    String? username,
    String? password,
  ) {
    final String user = (username == null || username.isEmpty)
        ? 'anonymous'
        : username;
    return (user: user, pass: password ?? '');
  }

  @override
  Future<bool> get isAuthenticated async => _host != null;

  @override
  Future<String?> get currentEmail async => _username;

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    final host = await repo.getFtpHost();
    final port = await repo.getFtpPort();
    final user = await repo.getFtpUsername();
    final pass = await repo.getFtpPassword();
    final tls = await repo.isFtpTlsEnabled();

    if (host == null || user == null || pass == null) {
      throw SyncAuthError('FTP credentials not configured');
    }

    _host = host;
    _port = port;
    _username = user;
    _password = pass;
    _useTls = tls;

    await _connect();
    await _disconnect();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    await _disconnect();
    _host = null;
    _username = null;
    _password = null;
    _useTls = false;
    _port = 21;
    clearCache();
    await repo.setFtpHost(null);
    await repo.setFtpUsername(null);
    await repo.setFtpPassword(null);
    await repo.setFtpTlsEnabled(false);
    await repo.setFtpPort(21);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final host = await repo.getFtpHost();
    final user = await repo.getFtpUsername();
    final pass = await repo.getFtpPassword();

    if (host == null || user == null || pass == null) return false;

    _host = host;
    _port = await repo.getFtpPort();
    _username = user;
    _password = pass;
    _useTls = await repo.isFtpTlsEnabled();
    return true;
  }

  @override
  Future<void> refreshAuth() async {
    // FTP uses username/password, no token refresh needed.
  }

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() => _opLock.withLock(() async {
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    await _ensureConnected();
    try {
      // Fushi 改名迁移三段（找新根 → 旧根 RNFR/RNTO 改名 → 新建）。稳态
      // 仍是一次 checkFolderExistence，与旧实现同价；旧根探测仅在新根缺席
      // 时发生。结果经 rootFolderIdCache 记忆化。
      final String? existing = await migrateLegacySyncRoot<String>(
        find: (String name) async {
          final String candidate = ftpRootPath(_homeDir, name);
          return await _client!.checkFolderExistence(candidate)
              ? candidate
              : null;
        },
        renameLegacy: (String legacyPath) async {
          // RNFR/RNTO 对目录整树改名。库只回 bool，false 必须抛出——迁移
          // 失败要留痕并降级为新建新根，不能静默当成功。
          final bool renamed = await _client!.rename(legacyPath, _rootPath);
          if (!renamed) {
            throw SyncBackendError(
              'FTP rename failed: $legacyPath -> $_rootPath',
            );
          }
          return _rootPath;
        },
        onRenameError: (Object e, StackTrace st) => ErrorLogService.instance
            .log('FtpSyncBackend.migrateLegacyRoot', e, st),
      );
      if (existing == null) {
        final created = await _client!.makeDirectory(_rootPath);
        if (!created) {
          throw SyncBackendError('Failed to create root folder: $_rootPath');
        }
      }
      await _client!.changeDirectory(_homeDir);
      rootFolderIdCache = _rootPath;
      return _rootPath;
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError(
        'Failed to find/create root folder: $e',
        isRetryable: true,
      );
    }
  });

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(rootFolderId);
          final entries = await _client!.listDirectoryContent();
          return entries
              .where((e) => e.type == FTPEntryType.dir)
              .map(
                (e) => SyncFileRef(id: '$rootFolderId/${e.name}', name: e.name),
              )
              .toList();
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to list books: $e', isRetryable: true);
        }
      });

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) => _opLock.withLock(() async {
    final sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      return folderIdCache[sanitized]!;
    }

    final folderPath = '$rootFolderId/$sanitized';
    await _ensureConnected();
    try {
      final exists = await _client!.checkFolderExistence(folderPath);
      if (!exists) {
        await _client!.changeDirectory(rootFolderId);
        final created = await _client!.makeDirectory(sanitized);
        if (!created) {
          throw SyncBackendError('Failed to create book folder: $folderPath');
        }
      }
      await _client!.changeDirectory(_homeDir);
      folderIdCache[sanitized] = folderPath;

      final Uint8List? coverData = await readCoverData?.call();
      if (coverData != null) {
        try {
          final format = detectCoverFormat(coverData);
          final coverName = 'cover_1_6.${format.extension}';
          await _client!.changeDirectory(folderPath);
          final coverExists = await _client!.existFile(coverName);
          if (!coverExists) {
            final tmpFile = await _writeTempFile(coverData, 'cover');
            try {
              await _client!.uploadFile(tmpFile, sRemoteName: coverName);
            } finally {
              await _deleteTempFile(tmpFile);
            }
          }
          await _client!.changeDirectory(_homeDir);
        } catch (_) {
          // Cover upload is best-effort.
        }
      }

      return folderPath;
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError(
        'Failed to ensure book folder: $e',
        isRetryable: true,
      );
    }
  });

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(folderId);
          final entries = await _client!.listDirectoryContent();
          final files = entries
              .where((e) => e.type == FTPEntryType.file)
              .map((e) => SyncFileRef(id: '$folderId/${e.name}', name: e.name))
              .toList();

          return SyncFileTrio(
            progress: findSyncFileByPrefix(files, 'progress_'),
            statistics: findSyncFileByPrefix(files, 'statistics_'),
            audioBook: findSyncFileByPrefix(files, 'audioBook_'),
          );
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError(
            'Failed to list sync files: $e',
            isRetryable: true,
          );
        }
      });

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出 FTP 的下载原语（已加锁的 temp-file → utf8 → jsonDecode）。
  @override
  Future<Object?> readJsonById(String fileId) => _downloadJson(fileId);

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) => _opLock.withLock(() async {
    await _ensureConnected();
    final fileName = progressFileName(
      progress.lastBookmarkModified,
      progress.progress,
    );
    await _uploadJsonImpl(folderId, fileName, progress.toJson());
    // Upload-then-delete: keep the old file until the new one is uploaded
    // so a failed upload never loses the only copy (HBK-AUDIT-048).
    if (fileId != null) await _deleteRemoteFileImpl(fileId);
  });

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) => _opLock.withLock(() async {
    await _ensureConnected();
    final fileName = statisticsFileName(stats);
    await _uploadJsonImpl(
      folderId,
      fileName,
      stats.map((s) => s.toJson()).toList(),
    );
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteRemoteFileImpl(fileId);
  });

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) => _opLock.withLock(() async {
    await _ensureConnected();
    final fileName = audioBookFileName(
      audioBook.lastAudioBookModified,
      audioBook.playbackPositionSec,
    );
    await _uploadJsonImpl(folderId, fileName, audioBook.toJson());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteRemoteFileImpl(fileId);
  });

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    SyncTransferProgress? onProgress,
  }) => _opLock.withLock(() async {
    await _ensureConnected();
    try {
      await _client!.changeDirectory(folderId);
      await _client!.uploadFile(
        file,
        sRemoteName: fileName,
        onProgress: onProgress != null
            ? (percent, received, total) =>
                  onProgress(percent / 100.0, received)
            : null,
      );
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError(
        'Failed to upload content file: $e',
        isRetryable: true,
      );
    }
  });

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    SyncTransferProgress? onProgress,
  }) => _opLock.withLock(() async {
    await _ensureConnected();
    final dir = _parentPath(fileId);
    final name = _fileName(fileId);
    try {
      await _client!.changeDirectory(dir);
      await _client!.downloadFile(
        name,
        destination,
        onProgress: onProgress != null
            ? (percent, received, total) =>
                  onProgress(percent / 100.0, received)
            : null,
      );
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError(
        'Failed to download content file: $e',
        isRetryable: true,
      );
    }
  });

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(folderId);
          final exists = await _client!.existFile(fileName);
          if (!exists) return null;
          return SyncFileRef(id: '$folderId/$fileName', name: fileName);
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError(
            'Failed to find content file: $e',
            isRetryable: true,
          );
        }
      });

  // ── Generic asset store (SyncAssetStore) ──────────────────────────
  //
  // Ids are home-anchored absolute FTP paths: a namespace's id is the folder
  // path under [_rootPath], and an asset's id is `'<folderId>/<name>'`. All
  // direct-client operations take [_opLock] and call [_ensureConnected] (same
  // shape as findOrCreateRootFolder / ensureBookFolder / listBooks). Methods
  // that merely delegate to an already-locking public op (uploadContentFile /
  // downloadContentFile / findContentFile / _downloadJson) must NOT re-wrap in
  // [_opLock] — AsyncMutex is non-reentrant and would deadlock.

  @override
  Future<String> ensureNamespace(String name) =>
      _ensureFolderAt(_rootPath, name);

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _ensureFolderAt(parentId, name);

  /// Ensure a child folder [name] exists under [parentId] and return its
  /// home-anchored absolute path `'<parentId>/<name>'`. Mirrors the
  /// create-if-missing path of ensureBookFolder (checkFolderExistence →
  /// changeDirectory(parent) → makeDirectory(name)).
  Future<String> _ensureFolderAt(String parentId, String name) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final folderPath = '$parentId/$name';
        try {
          final exists = await _client!.checkFolderExistence(folderPath);
          if (!exists) {
            await _client!.changeDirectory(parentId);
            final created = await _client!.makeDirectory(name);
            if (!created) {
              throw SyncBackendError('Failed to create folder: $folderPath');
            }
          }
          await _client!.changeDirectory(_homeDir);
          return folderPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError(
            'Failed to ensure folder: $e',
            isRetryable: true,
          );
        }
      });

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(namespaceId);
          final entries = await _client!.listDirectoryContent();
          // 修改时间不用 LIST / MLSD 的日期：LIST 对新文件只精确到分钟、时区不定，ftpconnect
          // 对 MLSD 的 modify 也按本机时区解析。改为逐个 MDTM（RFC 3659：秒级、UTC）。
          // 每个文件一次控制连接往返，目录大时跳过（调用方需要单个文件的时间时走
          // [findAsset]，它总会 MDTM）。
          final List<FTPEntry> files = entries
              .where((FTPEntry e) => e.type == FTPEntryType.file)
              .toList();
          final Map<String, int?> mtimes = <String, int?>{};
          if (files.length <= kFtpListMdtmLimit) {
            for (final FTPEntry f in files) {
              mtimes[f.name] = await _mdtmMs(f.name);
            }
          }
          return entries
              .map(
                (e) => AssetEntry(
                  id: '$namespaceId/${e.name}',
                  name: e.name,
                  isFolder: e.type == FTPEntryType.dir,
                  modifiedAt: mtimes[e.name],
                ),
              )
              .toList();
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError(
            'Failed to list children: $e',
            isRetryable: true,
          );
        }
      });

  /// 与默认实现同样按名查找，另用 MDTM 补上服务器修改时间（SRS 同步的服务器时间）。
  /// 先走已加锁的 [findContentFile]（经 super），再单独取锁发 MDTM：AsyncMutex 不可重入。
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final AssetEntry? found = await super.findAsset(namespaceId, name);
    if (found == null) return null;
    final int? mtime = await _opLock.withLock(() async {
      await _ensureConnected();
      try {
        return await _mdtmMs(found.id);
      } catch (e) {
        if (e is SyncBackendError || e is SyncAuthError) rethrow;
        _resetConnection();
        throw SyncBackendError(
          'Failed to read modification time: $e',
          isRetryable: true,
        );
      }
    });
    return AssetEntry(id: found.id, name: found.name, modifiedAt: mtime);
  }

  /// 发 `MDTM <path>`（调用方须持 [_opLock] 且已连接）。服务器不支持 / 文件不存在
  /// （非 213 应答）返回 null。
  Future<int?> _mdtmMs(String path) async {
    // FTPReply 不在 ftpconnect 的公开导出里，按推断类型取用（code/message 是无类型 getter）。
    final reply = await _client!.sendCustomCommand('MDTM $path');
    if (reply.code != 213) return null;
    final Object? message = reply.message;
    return message is String ? ftpMdtmReplyToMs(message) : null;
  }

  @override
  Future<Object?> getJsonAsset(String assetId) {
    // Delegates to the already-locking _downloadJson (temp-file → utf8 →
    // jsonDecode); do not re-wrap.
    return _downloadJson(assetId);
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) => _opLock.withLock(() async {
    await _ensureConnected();
    // _uploadJsonImpl writes utf8(jsonEncode(...)) to a temp file and
    // uploads to `'<namespaceId>/<name>'` (same path as updateProgressFile).
    await _uploadJsonImpl(namespaceId, name, json);
  });

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        // 用户显式删除：真实失败（网络/权限/协议）必须抛出，否则 UI 会把失败
        // 误报为「已删除」。ftpconnect 的 deleteFile/deleteEmptyDirectory 只返回
        // bool 且无法区分 not-found 与真失败，所以这里不静默任何失败——宁可抛真
        // 错也不静默成功。连接类错误按本文件惯例转成 retryable 供 SyncManager 重连。
        try {
          if (isFolder) {
            await _deleteDirRecursive(id);
          } else {
            await _deleteFileStrict(id);
          }
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError(
            'Failed to delete asset: $e',
            isRetryable: true,
          );
        }
      });

  /// 删除单个 FTP 文件 [fileId]，删除失败（含目标不存在）抛 [SyncBackendError]。
  /// 与吞错的 [_deleteRemoteFileImpl]（upload-then-delete 清理用）区分：本方法供
  /// 用户显式删除路径使用，必须让失败可见。
  Future<void> _deleteFileStrict(String fileId) async {
    final String dir = _parentPath(fileId);
    final String name = _fileName(fileId);
    await _client!.changeDirectory(dir);
    final bool ok = await _client!.deleteFile(name);
    if (!ok) {
      throw SyncBackendError('Failed to delete file: $fileId');
    }
  }

  /// 递归删除 FTP 目录 [path]：先删子文件、递归删子目录，最后删空目录本身。
  /// 任一子项删除失败都会抛出，整体中断——绝不因单个子项失败而静默成功。
  Future<void> _deleteDirRecursive(String path) async {
    await _client!.changeDirectory(path);
    final List<FTPEntry> entries = await _client!.listDirectoryContent();
    for (final FTPEntry e in entries) {
      if (e.name == '.' || e.name == '..') continue;
      final String childId = '$path/${e.name}';
      if (e.type == FTPEntryType.dir) {
        await _deleteDirRecursive(childId);
      } else {
        await _deleteFileStrict(childId);
      }
    }
    // 回到父目录再删空目录本身。
    await _client!.changeDirectory(_parentPath(path));
    final bool ok = await _client!.deleteEmptyDirectory(_fileName(path));
    if (!ok) {
      throw SyncBackendError('Failed to delete directory: $path');
    }
  }

  // ── Cache ─────────────────────────────────────────────────────────
  //
  // 缓存字段 + 六个 cache 方法收敛进 [SyncFolderCache] mixin（恒等 folderId，无尾
  // 斜杠规范化）。

  // ── Credentials ───────────────────────────────────────────────────

  /// Wipe stored credentials from the repository without clearing
  /// in-memory connection state. Call [signOut] for full cleanup.
  Future<void> clearCredentials(SyncRepository repo) async {
    await repo.setFtpHost(null);
    await repo.setFtpUsername(null);
    await repo.setFtpPassword(null);
    await repo.setFtpTlsEnabled(false);
    await repo.setFtpPort(21);
  }

  // ── Test connection ───────────────────────────────────────────────

  /// Verify FTP credentials without persisting any state.
  static Future<void> testConnection({
    required String host,
    required int port,
    required String username,
    required String password,
    required bool useTls,
  }) async {
    final ({String user, String pass}) creds = ftpLoginCredentials(
      username,
      password,
    );
    final client = FTPConnect(
      host,
      port: port,
      user: creds.user,
      pass: creds.pass,
      securityType: useTls ? SecurityType.ftps : SecurityType.ftp,
      timeout: 15,
    );
    try {
      final ok = await client.connect();
      if (!ok) throw SyncAuthError('FTP authentication failed');
      await client.disconnect();
    } on FTPConnectException catch (e) {
      throw SyncBackendError('FTP connection failed: ${e.message}');
    } catch (e) {
      if (e is SyncAuthError || e is SyncBackendError) rethrow;
      throw SyncBackendError('FTP connection failed: $e');
    }
  }

  // ── Connection management ─────────────────────────────────────────

  Future<void> _connect() async {
    if (_host == null) {
      throw SyncAuthError('FTP credentials not set');
    }
    final ({String user, String pass}) creds = ftpLoginCredentials(
      _username,
      _password,
    );
    _client = FTPConnect(
      _host!,
      port: _port,
      user: creds.user,
      pass: creds.pass,
      securityType: _useTls ? SecurityType.ftps : SecurityType.ftp,
      timeout: 30,
    );
    try {
      final ok = await _client!.connect();
      if (!ok) {
        _client = null;
        throw SyncAuthError('FTP authentication failed');
      }
      _connected = true;
      // Anchor all paths under the login directory rather than the raw server
      // root. Best-effort: if PWD fails, fall back to '/' (legacy behavior).
      try {
        _homeDir = _normalizeFtpDir(await _client!.currentDirectory());
      } catch (_) {
        _homeDir = '/';
      }
    } on FTPConnectException catch (e) {
      _client = null;
      _connected = false;
      throw SyncBackendError('FTP connection failed: ${e.message}');
    }
  }

  Future<void> _disconnect() async {
    if (_client != null && _connected) {
      try {
        await _client!.disconnect();
      } catch (_) {
        // Best-effort disconnect.
      }
    }
    _client = null;
    _connected = false;
  }

  Future<void> _ensureConnected() async {
    if (_client != null && _connected) return;
    await _connect();
  }

  /// Drop the current connection handle without network I/O. Called when an
  /// operation fails on a possibly-dead control socket (FTP servers close
  /// idle connections) so the next [_ensureConnected] reconnects instead of
  /// reusing a stale socket. Pairs with throwing a retryable error so the
  /// SyncManager retry reconnects within the same sync.
  void _resetConnection() {
    final stale = _client;
    _client = null;
    _connected = false;
    // Best-effort close the (possibly half-open) control socket so its file
    // descriptor is released. Fire-and-forget: the connection may be dead and
    // disconnect() could block, so we never await it here.
    if (stale != null) {
      unawaited(stale.disconnect().then<void>((_) {}, onError: (_) {}));
    }
  }

  // ── Private helpers ───────────────────────────────────────────────

  Future<dynamic> _downloadJson(String fileId) => _opLock.withLock(() async {
    await _ensureConnected();
    final dir = _parentPath(fileId);
    final name = _fileName(fileId);
    final tmpFile = _uniqueTempFile('ftp_dl', '.json');
    try {
      await _client!.changeDirectory(dir);
      final ok = await _client!.downloadFile(name, tmpFile);
      if (!ok) {
        throw SyncBackendError(
          'Failed to download: $fileId',
          isRetryable: true,
        );
      }
      final content = await tmpFile.readAsString(encoding: utf8);
      return jsonDecode(content);
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError('Failed to download JSON: $e', isRetryable: true);
    } finally {
      await _deleteTempFile(tmpFile);
    }
  });

  Future<void> _uploadJsonImpl(
    String folderId,
    String fileName,
    dynamic data,
  ) async {
    final bytes = utf8.encode(jsonEncode(data));
    final tmpFile = await _writeTempFile(bytes, 'ftp_ul');
    try {
      await _client!.changeDirectory(folderId);
      final ok = await _client!.uploadFile(tmpFile, sRemoteName: fileName);
      if (!ok) {
        throw SyncBackendError('Failed to upload: $folderId/$fileName');
      }
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError('Failed to upload JSON: $e', isRetryable: true);
    } finally {
      await _deleteTempFile(tmpFile);
    }
  }

  Future<void> _deleteRemoteFileImpl(String fileId) async {
    final dir = _parentPath(fileId);
    final name = _fileName(fileId);
    try {
      await _client!.changeDirectory(dir);
      await _client!.deleteFile(name);
    } catch (e) {
      // Deletion failure is non-fatal for update operations.
    }
  }

  /// Write [bytes] to a uniquely-named temp file and return it.
  Future<File> _writeTempFile(List<int> bytes, String prefix) async {
    final file = _uniqueTempFile(prefix, '.tmp');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _deleteTempFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* best-effort: failure is non-critical here */
    }
  }

  /// Extract the parent directory from an FTP path.
  static String _parentPath(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  /// Extract the file name from an FTP path.
  static String _fileName(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return path;
    return path.substring(idx + 1);
  }
}
