/// admin API 的整机备份端点（`/api/admin/backups`）：在运行中的 serve 里做快照。
///
/// - `GET  /api/admin/backups`          列出 `<data>/backups/` 里的备份（`kind`：manual / auto / pre_update）+ 进行中 /
///                                       上次手动失败 + 自动备份的计划（`schedule`）与状态（`status`）+ 还原用的路径；
/// - `POST /api/admin/backups`          后台开始一份**手动**备份（永不被自动删；正文 `{"documents": false}` 跳过
///                                       documents/），立即回 202 + 文件名；已在跑（任何来源）回 409；复习库正在换代迁移回
///                                       409 `srs_migration_running`（提交点会改名出 `srs4.db`、原位封存 `srs.db`，中途拷
///                                       出来的包可能只有封存的旧库）。备份期间迁移不开始，备份完再判定（`ServerSrs.holdForBackup`）；
/// - `GET  /api/admin/backups/schedule` 自动备份的计划 + 状态；
/// - `PUT  /api/admin/backups/schedule` 改计划（`interval` / `time` / `documents` / `maxTotalGb`，缺的项不变），写回配置文件；
/// - `POST /api/admin/backups/run`      立即跑一次自动备份（不看到期、不因「没变化」跳过；之后照常修剪），202 / 409；
/// - `GET  /api/admin/backups/<name>`   下载；
/// - `DELETE /api/admin/backups/<name>` 删除（任何来源；正在写的那份 404）。
///
/// `<name>` 只认三种备份文件名（`server_backup_store.dart`），别的一律 404，也就不可能用 `..` 之类走出备份目录。
/// 还原必须停服后用 CLI（`fushi_server backup restore <file> --yes`），这里不提供。
///
/// 备份里有配置文件（admin_token / 凭据），所以这组端点只在 admin 面上，不进远端 AI
/// 助手的操作目录（见 admin_ops.dart「不描述」）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show kNotEnoughSpaceError;
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/backup/server_backup_service.dart';
import 'package:fushi_server/src/backup/server_backup_store.dart';
import 'package:fushi_server/src/config/server_backup_config.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

const String kAdminBackupsPath = '/api/admin/backups';
const String _kSchedulePath = '$kAdminBackupsPath/schedule';
const String _kRunPath = '$kAdminBackupsPath/run';

class AdminBackups {
  AdminBackups(this.ctx);

  final AdminContext ctx;

  ServerBackupService get _service => ctx.backups;

  /// 进行中的那份（测试用来等它跑完）。
  Future<void>? get pending => _service.pending;

  Future<shelf.Response?> route(
    String method,
    String path,
    shelf.Request request,
  ) async {
    if (path == kAdminBackupsPath) {
      if (method == 'GET') return _list();
      if (method == 'POST') return _startManual(request);
      return null;
    }
    if (path == _kSchedulePath) {
      if (method == 'GET') return _jsonResponse(_scheduleJson());
      if (method == 'PUT') return _putSchedule(request);
      return null;
    }
    if (path == _kRunPath) {
      if (method == 'POST') return _runNow();
      return null;
    }
    if (!path.startsWith('$kAdminBackupsPath/')) return null;
    if (method != 'GET' && method != 'DELETE') return null;
    final String name = Uri.decodeComponent(
      path.substring(kAdminBackupsPath.length + 1),
    );
    final File file = File(p.join(_service.dir.path, name));
    if (!isServerBackupFileName(name) ||
        name == _service.running ||
        !file.existsSync()) {
      return _jsonResponse(<String, Object?>{'error': 'not found'}, 404);
    }
    if (method == 'DELETE') {
      if (!await _service.delete(name)) {
        return _jsonResponse(<String, Object?>{'error': 'not found'}, 404);
      }
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

  Map<String, Object?> _scheduleJson() => <String, Object?>{
    'schedule': ctx.config.backup.toJson(),
    'status': _service.status.toJson(),
    'running': _service.running,
    'runningKind': _service.runningKind?.wire,
  };

  Future<shelf.Response> _list() async {
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    for (final ServerBackupEntry e in _service.list()) {
      final File f = File(p.join(_service.dir.path, e.name));
      DateTime? modified;
      try {
        modified = f.statSync().modified;
      } on FileSystemException {
        modified = null;
      }
      items.add(<String, Object?>{
        ...e.toJson(),
        'modifiedAt': modified?.toUtc().toIso8601String(),
      });
    }
    return _jsonResponse(<String, Object?>{
      ..._scheduleJson(),
      'lastError': _service.lastManualError,
      'items': items,
      // WebUI 拼还原命令用（还原要停服，只能走 CLI）。
      'backupsDir': _service.dir.path,
      'configFile': ctx.configFile.path,
    });
  }

  Future<shelf.Response> _startManual(shelf.Request request) async {
    final String raw = await request.readAsString();
    final Object? body = raw.trim().isEmpty ? null : jsonDecode(raw);
    final Object? docs = body is Map ? body['documents'] : null;
    if (docs != null && docs is! bool) {
      throw const FormatException('documents must be a boolean');
    }
    final ServerBackupStart start = _service.startManual(
      includeDocuments: docs as bool? ?? true,
    );
    // 动笔之前的空间检查不过：507（Insufficient Storage），不让调用方以为在写、过一会儿才在列表里看到失败。
    final String? early = await start.preflight;
    if (early == kNotEnoughSpaceError) {
      return _jsonResponse(<String, Object?>{
        'error': kNotEnoughSpaceError,
        'message':
            'Not enough free disk space for this backup; free some space '
            '(or delete old backups) and try again',
      }, 507);
    }
    return adminBackupStartResponse(start, running: _service.running);
  }

  Future<shelf.Response> _runNow() async => adminBackupStartResponse(
    _service.startAutomatic(force: true),
    running: _service.running,
  );

  Future<shelf.Response> _putSchedule(shelf.Request request) async {
    final Object? body = jsonDecode(await request.readAsString());
    if (body is! Map) throw const FormatException('JSON object body required');
    final ServerBackupConfig current = ctx.config.backup;
    final Object? docs = body['documents'];
    if (docs != null && docs is! bool) {
      throw const FormatException('documents must be a boolean');
    }
    final Object? gb = body['maxTotalGb'];
    if (gb != null && gb is! int) {
      throw const FormatException('maxTotalGb must be an integer');
    }
    final ServerBackupConfig next = current.copyWith(
      interval: ServerBackupInterval.tryParse(body['interval']),
      minuteOfDay: ServerBackupConfig.parseTime(body['time']),
      includeDocuments: docs as bool?,
      maxTotalGb: ServerBackupConfig.parseMaxTotalGb(gb),
    );
    if (next != current) {
      await ctx.updateConfig(ctx.config.copyWith(backup: next));
    }
    return _jsonResponse(_scheduleJson());
  }
}

/// 「开始一份备份」的回执 → HTTP 回应（202 / 409 + 原因）。[running] = 正在写的那份（busy 时回给调用方）。
shelf.Response adminBackupStartResponse(
  ServerBackupStart start, {
  required String? running,
}) {
  switch (start.refusal) {
    case null:
      return _jsonResponse(<String, Object?>{'name': start.name}, 202);
    case ServerBackupRefusal.srsMigration:
      return _jsonResponse(<String, Object?>{
        'error': 'srs_migration_running',
      }, 409);
    case ServerBackupRefusal.busy:
      return _jsonResponse(<String, Object?>{
        'error': 'backup in progress',
        'running': running,
      }, 409);
    // 「立即跑」是强制的，走不到这两条；照实回，免得哪天换了调用方把「关着 / 没到期」报成「在跑」。
    case ServerBackupRefusal.disabled:
      return _jsonResponse(<String, Object?>{
        'error': 'automatic_backup_disabled',
      }, 409);
    case ServerBackupRefusal.notDue:
      return _jsonResponse(<String, Object?>{
        'error': 'automatic_backup_not_due',
      }, 409);
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
