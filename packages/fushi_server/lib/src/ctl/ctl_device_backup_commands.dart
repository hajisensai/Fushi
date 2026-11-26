/// `fushi_server ctl device-backups …`：已配对设备复制到本服务器的自动备份（admin 端点见
/// admin_device_backups.dart）。
///
/// - `device-backups [ls]`                      按设备列出（`--json` 看全量）；
/// - `device-backups rm <设备键> <还原点 id>`    删一份；
/// - `device-backups rm <设备键> --yes`          删这台设备的全部（不可撤销，要 `--yes`）。
///
/// 下载走 `GET /api/admin/device-backups/<设备键>/<id>`（WebUI 的下载链接，或 curl 带 Bearer）。
library;

import 'package:fushi_server/src/ctl/admin_client.dart' show adminPathSegment;
import 'package:fushi_server/src/ctl/ctl_srs_commands.dart' show CtlSrsRequest;
import 'package:fushi_server/src/server_language.dart';

const String _root = '/api/admin/device-backups';

/// `ctl` 动作名。
const String kCtlDeviceBackupsAction = 'device-backups';

/// 把 `device-backups <sub> <args…>` 翻成一个请求；用法不对时写 [err] 并返回 null。单请求的载体与
/// srs 那组同形，复用 [CtlSrsRequest]。
CtlSrsRequest? parseCtlDeviceBackupsAction(
  String sub,
  List<String> args, {
  required bool yes,
  required StringSink err,
}) {
  switch (sub) {
    case '' || 'ls':
      return const CtlSrsRequest('GET', _root, render: _renderDeviceBackups);
    case 'rm' when args.length == 2:
      return CtlSrsRequest(
        'DELETE',
        '$_root/${adminPathSegment(args[0])}/${adminPathSegment(args[1])}',
        render: _renderDeleted,
      );
    case 'rm' when args.length == 1:
      if (!yes) {
        err.writeln(
          tr(
            '删除这台设备复制来的全部备份不可撤销，确认请加 --yes',
            'Deleting every backup this device copied cannot be undone; add --yes to confirm',
          ),
        );
        return null;
      }
      return CtlSrsRequest(
        'DELETE',
        '$_root/${adminPathSegment(args[0])}',
        render: _renderDeleted,
      );
  }
  err.writeln(
    tr(
      '用法: fushi_server ctl device-backups [ls] | device-backups rm <设备键> <id> | '
          'device-backups rm <设备键> --yes',
      'Usage: fushi_server ctl device-backups [ls] | device-backups rm <device key> <id> | '
          'device-backups rm <device key> --yes',
    ),
  );
  return null;
}

void _renderDeleted(Object? response, StringSink out) =>
    out.writeln(tr('已删除', 'Deleted'));

String _bytes(Object? n) {
  double v = n is num ? n.toDouble() : 0;
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String _time(Object? ms) => ms is int
    ? DateTime.fromMillisecondsSinceEpoch(
        ms,
      ).toLocal().toIso8601String().substring(0, 19).replaceFirst('T', ' ')
    : '—';

/// 设备报上来的文本（设备名、应用版本、id）进终端前去掉控制字符：一台设备不能借名字里的
/// ESC 序列改写管理员的终端（清屏、伪造行、改标题）。换行 / 制表也换成空格，一台设备只占一行。
String _plain(Object? v) => '${v ?? ''}'.replaceAll(
  RegExp('[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]'),
  ' ',
);

void _renderDeviceBackups(Object? response, StringSink out) {
  final Object? devices = response is Map ? response['devices'] : null;
  if (devices is! List || devices.isEmpty) {
    out.writeln(tr('（还没有设备复制过备份）', '(no device has copied a backup here yet)'));
    return;
  }
  for (final Object? d in devices) {
    if (d is! Map) continue;
    final Object? name = d['name'];
    final int incomplete = d['incomplete'] is int ? d['incomplete'] as int : 0;
    out.writeln(
      '${_plain(name ?? d['device'])}  [${_plain(d['device'])}]  '
      '${tr('${d['count']} 份', d['count'] == 1 ? '1 copy' : '${d['count']} copies')}  ${_bytes(d['bytes'])}'
      '${incomplete > 0 ? tr('  另有 $incomplete 份没传完或已损坏', '  $incomplete more unfinished or damaged') : ''}',
    );
    final Object? copies = d['copies'];
    if (copies is! List) continue;
    for (final Object? c in copies) {
      if (c is! Map) continue;
      final Object? version = c['appVersion'];
      out.writeln(
        '  ${_plain(c['id'])}  ${_time(c['createdAtMs'])}  ${_bytes(c['bytes'])}'
        '${version == null ? '' : '  Fushi ${_plain(version)}'}',
      );
    }
  }
}
