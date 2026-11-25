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

/// [AutoBackupStatus.lastError] 的错误码：上次运行写到一半进程就没了（被系统杀掉 / 崩溃 /
/// 用户退出），下次启动从「开始」标记认出来。界面按码给本地化文案，其余错误是原文。
const String kAutoBackupErrorInterrupted = 'interrupted';

/// [AutoBackupStatus.lastError] 的错误码：自定义文件夹不在（外接盘没插、网络盘没挂上…）。
const String kAutoBackupErrorFolderUnavailable = 'folder_unavailable';

/// 用户文件夹（第三期）里副本的复制状态。与定时备份本身的结局分开记：本机还原点写好了、只是没复制
/// 进文件夹，不算备份失败。
class AutoBackupMirrorStatus {
  const AutoBackupMirrorStatus({
    this.target,
    this.pointId,
    this.atMs,
    this.error,
    this.errorAtMs,
    this.pendingId,
  });

  /// 上次复制成功 / 失败的那个文件夹（[AutoBackupMirrorFolder.key]）。
  final String? target;

  /// 已经完整复制进 [target] 的最新还原点 id。
  final String? pointId;

  /// [pointId] 复制好的时刻。
  final int? atMs;

  /// 上次复制失败的原因（错误码见 [kAutoBackupErrorFolderUnavailable]，其余是原文）；成功后清掉。
  final String? error;
  final int? errorAtMs;

  /// 正在复制的还原点 id：复制开始时落下、结束时清掉。下次还在 = 上次复制到一半进程就没了，文件夹里
  /// 那份半截副本按这个 id 精确清掉（别的设备在同一个文件夹里写的半截副本不碰），然后补复制。
  final String? pendingId;

  /// [pointId] 已经在文件夹 [folderKey] 里了。
  bool holds(String folderKey, String? id) =>
      id != null && target == folderKey && pointId == id;

  /// 上次对文件夹 [folderKey] 复制 [id] 时明确失败过（不是被打断）。
  bool failedFor(String folderKey) => target == folderKey && error != null;

  Map<String, Object?> toJson() => <String, Object?>{
    'target': ?target,
    'pointId': ?pointId,
    'atMs': ?atMs,
    'error': ?error,
    'errorAtMs': ?errorAtMs,
    'pendingId': ?pendingId,
  };

  static AutoBackupMirrorStatus fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return const AutoBackupMirrorStatus();
    int? i(String k) => raw[k] is int ? raw[k]! as int : null;
    String? s(String k) => raw[k] is String ? raw[k]! as String : null;
    return AutoBackupMirrorStatus(
      target: s('target'),
      pointId: s('pointId'),
      atMs: i('atMs'),
      error: s('error'),
      errorAtMs: i('errorAtMs'),
      pendingId: s('pendingId'),
    );
  }

  /// 开始把 [id] 复制进 [folderKey]。换了文件夹时之前的记录作废。
  AutoBackupMirrorStatus started({
    required String folderKey,
    required String id,
  }) => target == folderKey
      ? AutoBackupMirrorStatus(
          target: target,
          pointId: pointId,
          atMs: atMs,
          error: error,
          errorAtMs: errorAtMs,
          pendingId: id,
        )
      : AutoBackupMirrorStatus(target: folderKey, pendingId: id);

  AutoBackupMirrorStatus succeeded({
    required String folderKey,
    required String id,
    required int atMs,
  }) => AutoBackupMirrorStatus(target: folderKey, pointId: id, atMs: atMs);

  AutoBackupMirrorStatus failed({
    required String folderKey,
    required String error,
    required int atMs,
  }) => AutoBackupMirrorStatus(
    target: folderKey,
    pointId: target == folderKey ? pointId : null,
    atMs: target == folderKey ? this.atMs : null,
    error: error,
    errorAtMs: atMs,
  );
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
    this.runningSinceMs,
    this.lastInterruptedMs,
    this.missingData = const <String>[],
    this.mirror = const AutoBackupMirrorStatus(),
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

  /// 「开始」标记：开始写定时还原点时落下，成功 / 失败时清掉。启动时还在 = 上次写到一半进程
  /// 就没了（[interrupted]）。
  final int? runningSinceMs;

  /// 上次被打断的那次运行的开始时刻：到期判定据此等到下一个时段再试，不在每次启动都重跑、
  /// 每次都在同一处被杀。
  final int? lastInterruptedMs;

  /// 上次成功的那份里因为读不了而没带的数据类别（`BackupCategory.name`，现在只有复习库还在等升级
  /// 时的 `srs`）。状态行据此说明。
  final List<String> missingData;

  /// 用户文件夹里副本的复制状态（第三期）。
  final AutoBackupMirrorStatus mirror;

  DateTime? get lastSatisfied => lastSatisfiedMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastSatisfiedMs!);

  DateTime? get lastSuccess => lastSuccessMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastSuccessMs!);

  DateTime? get lastInterrupted => lastInterruptedMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastInterruptedMs!);

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
    if (runningSinceMs != null) 'runningSinceMs': runningSinceMs,
    if (lastInterruptedMs != null) 'lastInterruptedMs': lastInterruptedMs,
    if (missingData.isNotEmpty) 'missingData': missingData,
    if (mirror.toJson().isNotEmpty) 'mirror': mirror.toJson(),
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
      runningSinceMs: i('runningSinceMs'),
      lastInterruptedMs: i('lastInterruptedMs'),
      missingData: <String>[
        if (raw['missingData'] case final List<Object?> list)
          for (final Object? v in list)
            if (v is String) v,
      ],
      mirror: AutoBackupMirrorStatus.fromJson(raw['mirror']),
    );
  }

  /// 换掉复制状态，其余不动。
  AutoBackupStatus withMirror(AutoBackupMirrorStatus next) => AutoBackupStatus(
    lastAttemptMs: lastAttemptMs,
    lastResult: lastResult,
    lastSuccessMs: lastSuccessMs,
    lastSuccessPointId: lastSuccessPointId,
    lastSuccessBytes: lastSuccessBytes,
    lastSatisfiedMs: lastSatisfiedMs,
    lastError: lastError,
    fingerprint: fingerprint,
    runningSinceMs: runningSinceMs,
    lastInterruptedMs: lastInterruptedMs,
    missingData: missingData,
    mirror: next,
  );

  /// 开始写定时还原点：落「开始」标记，其余不动。
  AutoBackupStatus started({required int atMs}) => AutoBackupStatus(
    lastAttemptMs: lastAttemptMs,
    lastResult: lastResult,
    lastSuccessMs: lastSuccessMs,
    lastSuccessPointId: lastSuccessPointId,
    lastSuccessBytes: lastSuccessBytes,
    lastSatisfiedMs: lastSatisfiedMs,
    lastError: lastError,
    fingerprint: fingerprint,
    runningSinceMs: atMs,
    lastInterruptedMs: lastInterruptedMs,
    missingData: missingData,
    mirror: mirror,
  );

  /// 成功：记下指纹、点 id、大小，这一期满足。
  AutoBackupStatus succeeded({
    required int atMs,
    required String pointId,
    required int bytes,
    required String fingerprint,
    List<String> missingData = const <String>[],
  }) => AutoBackupStatus(
    lastAttemptMs: atMs,
    lastResult: AutoBackupResult.success,
    lastSuccessMs: atMs,
    lastSuccessPointId: pointId,
    lastSuccessBytes: bytes,
    lastSatisfiedMs: atMs,
    fingerprint: fingerprint,
    missingData: missingData,
    mirror: mirror,
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
    missingData: missingData,
    mirror: mirror,
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
        lastInterruptedMs: lastInterruptedMs,
        missingData: missingData,
        mirror: mirror,
      );

  /// 启动时发现「开始」标记还在：记成失败（[kAutoBackupErrorInterrupted]），清标记，记下被
  /// 打断的时刻（到期判定等到下一个时段）。
  AutoBackupStatus interrupted() => AutoBackupStatus(
    lastAttemptMs: runningSinceMs ?? lastAttemptMs,
    lastResult: AutoBackupResult.failed,
    lastSuccessMs: lastSuccessMs,
    lastSuccessPointId: lastSuccessPointId,
    lastSuccessBytes: lastSuccessBytes,
    lastSatisfiedMs: lastSatisfiedMs,
    lastError: kAutoBackupErrorInterrupted,
    fingerprint: fingerprint,
    lastInterruptedMs: runningSinceMs,
    missingData: missingData,
    mirror: mirror,
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
