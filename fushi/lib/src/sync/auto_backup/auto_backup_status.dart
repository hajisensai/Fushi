/// 自动备份的运行状态与「有没有变化」指纹。
///
/// 状态存在默认还原点目录下的 [kAutoBackupStatusFileName]（文件，不在库里）：从还原点「替换」
/// 主库之后它照样在，不会跟着库回到过去而误判「从没备份过」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart' show kRestorePointsDirName;
import 'package:path/path.dart' as p;

/// 状态文件名（默认还原点目录下）。
const String kAutoBackupStatusFileName = 'auto_backup_status.json';

/// 一次运行的结局。
enum AutoBackupResult {
  /// 建好了一个定时还原点。
  success,

  /// 到期了，但上次备份之后数据没变：没建新点，算这一期已经满足。
  skipped,

  /// 失败（原因在 [AutoBackupStatus.lastError]）；下次到期检查再试，不重试循环。
  failed,
}

/// 状态文件的内容（不可变）。
class AutoBackupStatus {
  const AutoBackupStatus({
    this.lastAttemptMs,
    this.lastResult,
    this.lastSuccessMs,
    this.lastSuccessPointId,
    this.lastSuccessBytes,
    this.lastSatisfiedMs,
    this.lastError,
    this.fingerprint,
  });

  final int? lastAttemptMs;
  final AutoBackupResult? lastResult;
  final int? lastSuccessMs;
  final String? lastSuccessPointId;
  final int? lastSuccessBytes;

  /// 上次「这一期已满足」（成功或没变化跳过）的时刻：到期判定只看它。
  final int? lastSatisfiedMs;
  final String? lastError;

  /// 上次成功时的数据指纹（[computeAutoBackupFingerprint]）。
  final String? fingerprint;

  DateTime? get lastSatisfied => lastSatisfiedMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastSatisfiedMs!);

  DateTime? get lastSuccess => lastSuccessMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastSuccessMs!);

  bool get lastRunFailed => lastResult == AutoBackupResult.failed;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': 1,
    'lastAttemptMs': lastAttemptMs,
    'lastResult': lastResult?.name,
    'lastSuccessMs': lastSuccessMs,
    'lastSuccessPointId': lastSuccessPointId,
    'lastSuccessBytes': lastSuccessBytes,
    'lastSatisfiedMs': lastSatisfiedMs,
    'lastError': lastError,
    'fingerprint': fingerprint,
  };

  static AutoBackupStatus fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return const AutoBackupStatus();
    int? i(String k) => raw[k] is int ? raw[k]! as int : null;
    String? s(String k) => raw[k] is String ? raw[k]! as String : null;
    AutoBackupResult? result;
    for (final AutoBackupResult r in AutoBackupResult.values) {
      if (r.name == raw['lastResult']) result = r;
    }
    return AutoBackupStatus(
      lastAttemptMs: i('lastAttemptMs'),
      lastResult: result,
      lastSuccessMs: i('lastSuccessMs'),
      lastSuccessPointId: s('lastSuccessPointId'),
      lastSuccessBytes: i('lastSuccessBytes'),
      lastSatisfiedMs: i('lastSatisfiedMs'),
      lastError: s('lastError'),
      fingerprint: s('fingerprint'),
    );
  }

  /// 成功：记下指纹、点 id、大小，这一期满足。
  AutoBackupStatus succeeded({
    required int atMs,
    required String pointId,
    required int bytes,
    required String fingerprint,
  }) => AutoBackupStatus(
    lastAttemptMs: atMs,
    lastResult: AutoBackupResult.success,
    lastSuccessMs: atMs,
    lastSuccessPointId: pointId,
    lastSuccessBytes: bytes,
    lastSatisfiedMs: atMs,
    fingerprint: fingerprint,
  );

  /// 没变化跳过：成功记录不动，这一期满足。
  AutoBackupStatus skipped({required int atMs}) => AutoBackupStatus(
    lastAttemptMs: atMs,
    lastResult: AutoBackupResult.skipped,
    lastSuccessMs: lastSuccessMs,
    lastSuccessPointId: lastSuccessPointId,
    lastSuccessBytes: lastSuccessBytes,
    lastSatisfiedMs: atMs,
    fingerprint: fingerprint,
  );

  /// 失败：这一期不算满足，下次到期检查再试。
  AutoBackupStatus failed({required int atMs, required String error}) =>
      AutoBackupStatus(
        lastAttemptMs: atMs,
        lastResult: AutoBackupResult.failed,
        lastSuccessMs: lastSuccessMs,
        lastSuccessPointId: lastSuccessPointId,
        lastSuccessBytes: lastSuccessBytes,
        lastSatisfiedMs: lastSatisfiedMs,
        lastError: error,
        fingerprint: fingerprint,
      );
}

/// 状态文件路径（默认还原点目录）。
String autoBackupStatusPath(String dbDirectory) =>
    p.join(dbDirectory, kRestorePointsDirName, kAutoBackupStatusFileName);

/// 读状态；没有 / 坏了返回空状态。
AutoBackupStatus readAutoBackupStatus(String dbDirectory) {
  final File f = File(autoBackupStatusPath(dbDirectory));
  if (!f.existsSync()) return const AutoBackupStatus();
  try {
    return AutoBackupStatus.fromJson(jsonDecode(f.readAsStringSync()));
  } on Object {
    return const AutoBackupStatus();
  }
}

/// 写状态（临时名 + 改名）。
void writeAutoBackupStatus(String dbDirectory, AutoBackupStatus status) {
  final String path = autoBackupStatusPath(dbDirectory);
  Directory(p.dirname(path)).createSync(recursive: true);
  final File tmp = File('$path.tmp');
  tmp.writeAsStringSync(jsonEncode(status.toJson()), flush: true);
  tmp.renameSync(path);
}

/// 「上次备份之后有没有变化」的廉价指纹：[files] 每个文件的大小 + 修改时刻，[directories]
/// 每个目录下（递归）全部文件的条数、总大小、最新修改时刻，再拼上 [contentSignature]
/// （内容设置变了指纹就变）。不读文件内容；在后台 isolate 里遍历目录。
///
/// 只要求「没变 ⇒ 指纹相同」足够可靠（主库 / 复习库每次写入都会动 `-wal` 的修改时刻）；指纹
/// 变了而数据其实没变，最多多备份一次。
Future<String> computeAutoBackupFingerprint({
  required List<String> files,
  required List<String> directories,
  required String contentSignature,
}) => Isolate.run<String>(() {
  final StringBuffer out = StringBuffer(contentSignature);
  for (final String path in files) {
    final FileStat st = FileStat.statSync(path);
    out.write(
      st.type == FileSystemEntityType.notFound
          ? '|$path:-'
          : '|$path:${st.size}:${st.modified.millisecondsSinceEpoch}',
    );
  }
  for (final String path in directories) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      out.write('|$path/:-');
      continue;
    }
    int count = 0;
    int bytes = 0;
    int newest = 0;
    try {
      for (final FileSystemEntity e in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File) continue;
        final FileStat st = e.statSync();
        count++;
        bytes += st.size;
        final int ms = st.modified.millisecondsSinceEpoch;
        if (ms > newest) newest = ms;
      }
    } on FileSystemException {
      // 遍历中途被删 / 无权限：照已数到的写，最多多备份一次。
    }
    out.write('|$path/:$count:$bytes:$newest');
  }
  return out.toString();
});
