/// 自动整机备份的状态文件：`<data>/backups/auto_backup_status.json`。
///
/// 放在备份目录里：备份目录不进备份包，还原一份旧包不会把旧的状态也带回来；文件名不是备份文件名，
/// 列表 / 下载 / 删除都看不见它。只记时刻、文件名、大小、原因与一个指纹哈希——不记配置内容、路径以外的
/// 任何凭据。
///
/// `runningSinceMs` 在一次自动 / 更新前备份开始时写下、结束时清掉：下次进程启动时还在 = 上次写到一半
/// 进程没了（被杀 / 断电），记成「中断」，清掉半截文件，这一时段不再重跑（见 fushi_core `backup_schedule.dart`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/backup/server_backup_store.dart';
import 'package:path/path.dart' as p;

/// 状态文件名（在 `<data>/backups/` 下）。
const String kServerBackupStatusFileName = 'auto_backup_status.json';

/// 跳过原因：数据与上次成功那份相比没变（算「满足」，到下个时段才再看）。
const String kServerBackupSkipUnchanged = 'unchanged';

/// 跳过原因：复习库正在换代迁移（不算满足，下次检查重试）。
const String kServerBackupSkipSrsMigration = 'srs_migration_running';

/// 失败原因：上次运行写到一半进程没了。
const String kServerBackupErrorInterrupted = 'interrupted';

class ServerBackupStatus {
  const ServerBackupStatus({
    this.runningSinceMs,
    this.runningName,
    this.runningKind,
    this.lastSuccessAtMs,
    this.lastSuccessName,
    this.lastSuccessBytes,
    this.lastFailureAtMs,
    this.lastError,
    this.lastSkippedAtMs,
    this.lastSkipReason,
    this.lastSatisfiedAtMs,
    this.lastInterruptedAtMs,
    this.fingerprint,
    this.lastPrunedCount,
    this.preUpdateAtMs,
    this.preUpdateName,
    this.preUpdateError,
  });

  factory ServerBackupStatus.fromJson(Map<String, Object?> j) {
    int? i(String k) => j[k] is int ? j[k]! as int : null;
    String? s(String k) => j[k] is String ? j[k]! as String : null;
    return ServerBackupStatus(
      runningSinceMs: i('runningSinceMs'),
      runningName: s('runningName'),
      runningKind: s('runningKind'),
      lastSuccessAtMs: i('lastSuccessAtMs'),
      lastSuccessName: s('lastSuccessName'),
      lastSuccessBytes: i('lastSuccessBytes'),
      lastFailureAtMs: i('lastFailureAtMs'),
      lastError: s('lastError'),
      lastSkippedAtMs: i('lastSkippedAtMs'),
      lastSkipReason: s('lastSkipReason'),
      lastSatisfiedAtMs: i('lastSatisfiedAtMs'),
      lastInterruptedAtMs: i('lastInterruptedAtMs'),
      fingerprint: s('fingerprint'),
      lastPrunedCount: i('lastPrunedCount'),
      preUpdateAtMs: i('preUpdateAtMs'),
      preUpdateName: s('preUpdateName'),
      preUpdateError: s('preUpdateError'),
    );
  }

  /// 正在跑的自动 / 更新前备份的开始时刻（null = 没在跑）。
  final int? runningSinceMs;
  final String? runningName;

  /// [ServerBackupKind.wire]。
  final String? runningKind;

  /// 上次成功的自动备份。
  final int? lastSuccessAtMs;
  final String? lastSuccessName;
  final int? lastSuccessBytes;

  /// 上次失败的自动备份（[lastError] 是一行原因；`interrupted` = 写到一半进程没了）。
  final int? lastFailureAtMs;
  final String? lastError;

  /// 上次跳过（[kServerBackupSkipUnchanged] / [kServerBackupSkipSrsMigration]）。
  final int? lastSkippedAtMs;
  final String? lastSkipReason;

  /// 上次「满足」（成功或没变化跳过）：到期判定只看它。
  final int? lastSatisfiedAtMs;

  /// 上次被打断的那次运行的开始时刻。
  final int? lastInterruptedAtMs;

  /// 上次成功时的数据指纹（sha1 十六进制，见 `ServerBackupService.fingerprint`）。
  final String? fingerprint;

  /// 上次成功后按保留规则删掉了几份。
  final int? lastPrunedCount;

  /// 上次更新前备份：时刻、文件名（成功时）、失败原因（失败时；更新照样进行，D16）。
  final int? preUpdateAtMs;
  final String? preUpdateName;
  final String? preUpdateError;

  ServerBackupStatus copyWith({
    int? Function()? runningSinceMs,
    String? Function()? runningName,
    String? Function()? runningKind,
    int? lastSuccessAtMs,
    String? lastSuccessName,
    int? lastSuccessBytes,
    int? lastFailureAtMs,
    String? lastError,
    int? lastSkippedAtMs,
    String? lastSkipReason,
    int? lastSatisfiedAtMs,
    int? lastInterruptedAtMs,
    String? fingerprint,
    int? lastPrunedCount,
    int? preUpdateAtMs,
    String? Function()? preUpdateName,
    String? Function()? preUpdateError,
  }) => ServerBackupStatus(
    runningSinceMs: runningSinceMs == null
        ? this.runningSinceMs
        : runningSinceMs(),
    runningName: runningName == null ? this.runningName : runningName(),
    runningKind: runningKind == null ? this.runningKind : runningKind(),
    lastSuccessAtMs: lastSuccessAtMs ?? this.lastSuccessAtMs,
    lastSuccessName: lastSuccessName ?? this.lastSuccessName,
    lastSuccessBytes: lastSuccessBytes ?? this.lastSuccessBytes,
    lastFailureAtMs: lastFailureAtMs ?? this.lastFailureAtMs,
    lastError: lastError ?? this.lastError,
    lastSkippedAtMs: lastSkippedAtMs ?? this.lastSkippedAtMs,
    lastSkipReason: lastSkipReason ?? this.lastSkipReason,
    lastSatisfiedAtMs: lastSatisfiedAtMs ?? this.lastSatisfiedAtMs,
    lastInterruptedAtMs: lastInterruptedAtMs ?? this.lastInterruptedAtMs,
    fingerprint: fingerprint ?? this.fingerprint,
    lastPrunedCount: lastPrunedCount ?? this.lastPrunedCount,
    preUpdateAtMs: preUpdateAtMs ?? this.preUpdateAtMs,
    preUpdateName: preUpdateName == null ? this.preUpdateName : preUpdateName(),
    preUpdateError: preUpdateError == null
        ? this.preUpdateError
        : preUpdateError(),
  );

  /// 清掉「在跑」标记。
  ServerBackupStatus notRunning() => copyWith(
    runningSinceMs: () => null,
    runningName: () => null,
    runningKind: () => null,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'runningSinceMs': runningSinceMs,
    'runningName': runningName,
    'runningKind': runningKind,
    'lastSuccessAtMs': lastSuccessAtMs,
    'lastSuccessName': lastSuccessName,
    'lastSuccessBytes': lastSuccessBytes,
    'lastFailureAtMs': lastFailureAtMs,
    'lastError': lastError,
    'lastSkippedAtMs': lastSkippedAtMs,
    'lastSkipReason': lastSkipReason,
    'lastSatisfiedAtMs': lastSatisfiedAtMs,
    'lastInterruptedAtMs': lastInterruptedAtMs,
    'fingerprint': fingerprint,
    'lastPrunedCount': lastPrunedCount,
    'preUpdateAtMs': preUpdateAtMs,
    'preUpdateName': preUpdateName,
    'preUpdateError': preUpdateError,
  };

  /// 读 [backupsDir] 里的状态；没有 / 坏了 = 空状态（坏文件不挡备份，下次写入覆盖）。
  static ServerBackupStatus load(Directory backupsDir) {
    final File f = File(p.join(backupsDir.path, kServerBackupStatusFileName));
    try {
      if (!f.existsSync()) return const ServerBackupStatus();
      final Object? j = jsonDecode(f.readAsStringSync());
      if (j is Map) {
        return ServerBackupStatus.fromJson(j.cast<String, Object?>());
      }
    } on Object {
      // 坏文件：当作没有。
    }
    return const ServerBackupStatus();
  }

  /// 原子写入（临时文件 + 改名）。
  Future<void> save(Directory backupsDir) async {
    await backupsDir.create(recursive: true);
    final File f = File(p.join(backupsDir.path, kServerBackupStatusFileName));
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}

/// [ServerBackupKind] 的 wire 名 → 枚举（不认识 = null）。
ServerBackupKind? serverBackupKindFromWire(String? wire) {
  for (final ServerBackupKind k in ServerBackupKind.values) {
    if (k.wire == wire) return k;
  }
  return null;
}
