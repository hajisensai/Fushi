import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'ctl_paths.dart';

/// 控制通道发现文件的内容：app 进程写、CLI 读。
class CtlEndpoint {
  const CtlEndpoint({
    required this.port,
    required this.token,
    required this.pid,
    required this.startedAt,
    this.appVersion,
  });

  /// 127.0.0.1 上的监听端口（每次启动随机）。
  final int port;

  /// 每次启动新生成的随机 token；请求以 `Authorization: Bearer <token>` 携带。
  final String token;

  /// 写文件的 app 进程 pid——只用来避免旧实例退出时删掉新实例的文件。
  final int pid;

  /// 写入时刻（毫秒）。
  final int startedAt;

  final String? appVersion;

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: port);

  Map<String, Object?> toJson() => <String, Object?>{
    'port': port,
    'token': token,
    'pid': pid,
    'startedAt': startedAt,
    if (appVersion != null) 'appVersion': appVersion,
  };

  /// 解析失败（字段缺失 / 类型不对）返回 null，调用方按「app 未运行」处理。
  static CtlEndpoint? tryParse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final Object? port = decoded['port'];
    final Object? token = decoded['token'];
    final Object? pid = decoded['pid'];
    final Object? startedAt = decoded['startedAt'];
    final Object? appVersion = decoded['appVersion'];
    if (port is! int || port <= 0 || port > 65535) return null;
    if (token is! String || token.isEmpty) return null;
    if (pid is! int || startedAt is! int) return null;
    return CtlEndpoint(
      port: port,
      token: token,
      pid: pid,
      startedAt: startedAt,
      appVersion: appVersion is String ? appVersion : null,
    );
  }
}

/// 新 token：32 字节安全随机数的 base64url（无填充）。
String generateCtlToken({Random? random}) {
  final Random rng = random ?? Random.secure();
  final List<int> bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 当前进程 pid（给同名字段遮住 `dart:io` 顶层 `pid` 的类用）。
int currentProcessId() => pid;

File ctlEndpointFile(String stateDir) =>
    File(p.join(stateDir, kCtlEndpointFileName));

/// 读发现文件；不存在或内容坏了都返回 null。
Future<CtlEndpoint?> readCtlEndpoint(String stateDir) async {
  final File file = ctlEndpointFile(stateDir);
  try {
    if (!await file.exists()) return null;
    return CtlEndpoint.tryParse(await file.readAsString());
  } on FileSystemException {
    return null;
  }
}

/// 原子写发现文件（同目录临时文件 + rename，读侧不会读到半截 JSON）。
///
/// POSIX 上目录收紧到 700、文件 600：token 等于本机控制权，不能让同机其它用户读到。
/// Windows 的 `%LOCALAPPDATA%` 本身就是按用户 ACL 隔离的。
Future<File> writeCtlEndpoint(String stateDir, CtlEndpoint endpoint) async {
  final Directory dir = Directory(stateDir);
  await dir.create(recursive: true);
  if (!Platform.isWindows) await _chmod('700', dir.path);
  final File target = ctlEndpointFile(stateDir);
  final File temp = File('${target.path}.${endpoint.pid}.tmp');
  await temp.writeAsString(jsonEncode(endpoint.toJson()), flush: true);
  if (!Platform.isWindows) await _chmod('600', temp.path);
  return temp.rename(target.path);
}

/// 删除发现文件——仅当它仍属于 [ownerPid]（新实例已接管时不动它的文件）。
Future<void> deleteCtlEndpointIfOwned(String stateDir, int ownerPid) async {
  final CtlEndpoint? current = await readCtlEndpoint(stateDir);
  if (current == null || current.pid != ownerPid) return;
  try {
    await ctlEndpointFile(stateDir).delete();
  } on FileSystemException {
    // 已被删掉：目标状态已达成。
  }
}

Future<void> _chmod(String mode, String path) async {
  final ProcessResult result = await Process.run('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException('chmod $mode failed: ${result.stderr}', path);
  }
}
