/// mDNS 广播：`_fushi-sync._tcp`，TXT `id=<deviceId>` [`tls=1`]。
///
/// app 用 bonsoir 插件；服务端不能依赖插件，Linux 上最稳的是交给 avahi
/// （`avahi-publish -s <name> _fushi-sync._tcp <port> id=… tls=1`，NAS / 桌面发行版
/// 几乎都自带）。没有 avahi 时只打一行 warning——客户端手动输 IP 的路径本来就有，
/// 广播缺失不影响配对与服务。macOS 用 `dns-sd -R`；Windows 桌面运行服务端不广播。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';

class LanAdvertiser {
  LanAdvertiser({
    required this.deviceName,
    required this.deviceId,
    required this.port,
    required this.tlsEnabled,
  });

  /// 与 app `LanDiscoveryService.serviceType` 同值（冻结）。
  static const String serviceType = '_fushi-sync._tcp';
  static const String attributeId = 'id';
  static const String attributeTls = 'tls';

  final String deviceName;
  final String deviceId;
  final int port;
  final bool tlsEnabled;
  Process? _process;

  bool get isAdvertising => _process != null;

  Future<void> start() async {
    if (_process != null) return;
    final List<String> txt = <String>[
      '$attributeId=$deviceId',
      if (tlsEnabled) '$attributeTls=1',
    ];
    final List<List<String>> candidates = <List<String>>[
      if (Platform.isLinux)
        <String>['avahi-publish', '-s', deviceName, serviceType, '$port', ...txt],
      if (Platform.isMacOS)
        <String>['dns-sd', '-R', deviceName, serviceType, 'local', '$port', ...txt],
    ];
    for (final List<String> cmd in candidates) {
      try {
        _process = await Process.start(cmd.first, cmd.sublist(1));
        _process!.stderr.drain<void>();
        _process!.stdout.drain<void>();
        engineLog.logDiagnostic('LanAdvertiser', 'advertising via ${cmd.first}');
        return;
      } on ProcessException catch (e) {
        engineLog.logDiagnostic('LanAdvertiser', '${cmd.first} unavailable: ${e.message}');
      }
    }
    engineLog.logDiagnostic(
      'LanAdvertiser',
      'no mDNS publisher available (install avahi-utils on Linux); peers must '
          'enter the host address manually',
    );
  }

  Future<void> stop() async {
    final Process? proc = _process;
    _process = null;
    proc?.kill();
  }
}
