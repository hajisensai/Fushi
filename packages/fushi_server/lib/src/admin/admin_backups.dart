/// admin API 的整机备份端点（`/api/admin/backups`）：在运行中的 serve 里做快照。
///
/// - `GET  /api/admin/backups`          列出 `<data>/backups/` 里的备份 + 进行中 / 上次失败；
/// - `POST /api/admin/backups`          后台开始一份（正文 `{"documents": false}` 跳过
///                                       documents/），立即回 202 + 文件名；已在跑回 409；
/// - `GET  /api/admin/backups/<name>`   下载；
/// - `DELETE /api/admin/backups/<name>` 删除。
///
/// 备份里有配置文件（admin_token / 凭据），所以这组端点只在 admin 面上，不进远端 AI
/// 助手的操作目录（见 admin_ops.dart「不描述」）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String kAdminBackupsPath = '/api/admin/backups';

/// admin API 生成的备份文件名（[serverBackupFileName] 的形状）；别的名字一律 404，
/// 也就不可能用 `..` 之类走出备份目录。
final RegExp _backupName = RegExp(
  r'^fushi_server-backup-\d{8}-\d{6}(-\d+)?\.zip$',
);

class AdminBackups {
  AdminBackups(this.ctx, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AdminContext ctx;
  final DateTime Function() _now;

  String? _running;
  Future<void>? _job;
  String? _lastError;

  Directory get _dir =>
      Directory(p.join(ctx.config.dataDir, kServerBackupDirName));

  /// 进行中的那份（测试用来等它跑完）。
  Future<void>? get pending => _job;

  Future<shelf.Response?> route(
    String method,
    String path,
    shelf.Request request,
  ) async {
    if (path == kAdminBackupsPath) {
      if (method == 'GET') return _list();
      if (method == 'POST') return _start(request);
      return null;
    }
    if (!path.startsWith('$kAdminBackupsPath/')) return null;
    final String name = Uri.decodeComponent(
      path.substring(kAdminBackupsPath.length + 1),
    );
    if (method != 'GET' && method != 'DELETE') return null;
    final File file = File(p.join(_dir.path, name));
    if (!_backupName.hasMatch(name) || name == _running || !file.existsSync()) {
      return _jsonResponse(<String, Object?>{'error': 'not found'}, 404);
    }
    if (method == 'DELETE') {
      await file.delete();
      return _jsonResponse(const <String, Object?>{'ok': true});
    }
    return shelf.Response.ok(
      file.openRead(),
      headers: <String, String>{
        'Content-Type': 'application/zip',
        'Content-Length': '${file.lengthSync()}',
        'Content-Disposition': 'attachment; filename="$name"',
        'Cache-Control': 'no-store',
      },
    );
  }

  Future<shelf.Response> _list() async {
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    if (_dir.existsSync()) {
      for (final FileSystemEntity e in _dir.listSync()) {
        final String name = p.basename(e.path);
        if (e is! File || !_backupName.hasMatch(name) || name == _running) {
          continue;
        }
        final FileStat st = e.statSync();
        items.add(<String, Object?>{
          'name': name,
          'bytes': st.size,
          'modifiedAt': st.modified.toUtc().toIso8601String(),
        });
      }
    }
    items.sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          (b['name']! as String).compareTo(a['name']! as String),
    );
    return _jsonResponse(<String, Object?>{
      'running': _running,
      'lastError': _lastError,
      'items': items,
    });
  }

  Future<shelf.Response> _start(shelf.Request request) async {
    if (_running != null) {
      return _jsonResponse(<String, Object?>{
        'error': 'backup in progress',
        'running': _running,
      }, 409);
    }
    final String raw = await request.readAsString();
    final Object? body = raw.trim().isEmpty ? null : jsonDecode(raw);
    final Object? docs = body is Map ? body['documents'] : null;
    if (docs != null && docs is! bool) {
      throw const FormatException('documents must be a boolean');
    }
    String name = serverBackupFileName(_now());
    for (int i = 2; File(p.join(_dir.path, name)).existsSync(); i++) {
      name = serverBackupFileName(_now()).replaceFirst('.zip', '-$i.zip');
    }
    _running = name;
    _lastError = null;
    _job = _run(name, includeDocuments: docs as bool? ?? true);
    return _jsonResponse(<String, Object?>{'name': name}, 202);
  }

  Future<void> _run(String name, {required bool includeDocuments}) async {
    try {
      await createServerBackup(
        db: ctx.db,
        dataDir: ctx.config.dataDir,
        configFile: ctx.configFile,
        output: File(p.join(_dir.path, name)),
        includeDocuments: includeDocuments,
      );
    } catch (e, stack) {
      _lastError = '$e';
      engineLog.log('AdminBackups.create', e, stack);
    } finally {
      _running = null;
    }
  }
}

shelf.Response _jsonResponse(Map<String, Object?> body, [int status = 200]) =>
    shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );
