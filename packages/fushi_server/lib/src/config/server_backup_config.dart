/// `fushi_server.yaml` 的 `backup:` 段：服务端自动整机备份的计划（spec
/// `docs/specs/2026-11-25-auto-backup-restore-points.md` 第 4B 期，D14 / D15）。
///
/// ```yaml
/// backup:
///   interval: daily      # off | daily | every3Days | weekly（与 app 的自动备份同名）
///   time: "04:00"        # 服务端本地时间的偏好时刻；错过了（停着机）下次启动补跑
///   documents: false     # 自动备份带不带 documents/（书 / 封面 / 有声书 / 下载）
///   max_total_gb: 5      # 自动备份总大小上限（0 = 不限）；最新一份永远留
/// ```
///
/// 没写这一段 = 默认值（每日 04:00、不带 documents、5 GB）：自动备份默认开（D14）。
library;

import 'package:fushi_server/src/server_language.dart';

/// 自动备份间隔（名字与 app `AutoBackupInterval` 一致）。
enum ServerBackupInterval {
  off(0),
  daily(1),
  every3Days(3),
  weekly(7);

  const ServerBackupInterval(this.days);

  /// 间隔天数；[off] 为 0。
  final int days;

  /// 解析 yaml / admin API 的值；空 = null（调用方取默认），不认识的报错。
  static ServerBackupInterval? tryParse(Object? raw) {
    final String s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return null;
    for (final ServerBackupInterval v in values) {
      if (v.name == s) return v;
    }
    throw FormatException(
      tr(
        'backup.interval 只能是 off / daily / every3Days / weekly，实际 "$s"',
        'backup.interval must be off / daily / every3Days / weekly, got "$s"',
      ),
    );
  }
}

class ServerBackupConfig {
  const ServerBackupConfig({
    this.interval = ServerBackupInterval.daily,
    this.minuteOfDay = kDefaultMinuteOfDay,
    this.includeDocuments = false,
    this.maxTotalGb = kDefaultMaxTotalGb,
  });

  /// 默认偏好时刻 04:00（服务端通常整夜开着，这个点最闲）。
  static const int kDefaultMinuteOfDay = 4 * 60;

  /// 默认总大小上限（GB），同 app 定时还原点（D3 / D15）。
  static const int kDefaultMaxTotalGb = 5;

  factory ServerBackupConfig.fromYaml(Object? raw) {
    if (raw is! Map) return const ServerBackupConfig();
    const ServerBackupConfig d = ServerBackupConfig();
    final Object? docs = raw['documents'];
    return ServerBackupConfig(
      interval: ServerBackupInterval.tryParse(raw['interval']) ?? d.interval,
      minuteOfDay: parseTime(raw['time']) ?? d.minuteOfDay,
      includeDocuments: docs == true || '$docs'.toLowerCase() == 'true',
      maxTotalGb: parseMaxTotalGb(raw['max_total_gb']) ?? d.maxTotalGb,
    );
  }

  final ServerBackupInterval interval;

  /// 偏好时刻：当天第几分钟（0–1439），服务端本地时间。
  final int minuteOfDay;

  /// 自动备份带上 documents/（手动备份另有自己的选项）。
  final bool includeDocuments;

  /// 自动备份总大小上限（GB）；0 = 不限。
  final int maxTotalGb;

  bool get enabled => interval != ServerBackupInterval.off;

  /// 保留策略用的字节上限（null = 不限）。
  int? get maxTotalBytes =>
      maxTotalGb <= 0 ? null : maxTotalGb * 1024 * 1024 * 1024;

  /// `HH:MM`。
  String get time =>
      '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:'
      '${(minuteOfDay % 60).toString().padLeft(2, '0')}';

  ServerBackupConfig copyWith({
    ServerBackupInterval? interval,
    int? minuteOfDay,
    bool? includeDocuments,
    int? maxTotalGb,
  }) => ServerBackupConfig(
    interval: interval ?? this.interval,
    minuteOfDay: minuteOfDay ?? this.minuteOfDay,
    includeDocuments: includeDocuments ?? this.includeDocuments,
    maxTotalGb: maxTotalGb ?? this.maxTotalGb,
  );

  /// admin API / CLI 看到的形状。
  Map<String, Object?> toJson() => <String, Object?>{
    'interval': interval.name,
    'time': time,
    'documents': includeDocuments,
    'maxTotalGb': maxTotalGb,
  };

  /// `HH:MM`（24 小时制）→ 当天第几分钟；空 = null，格式不对报错。
  static int? parseTime(Object? raw) {
    final String s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return null;
    final RegExpMatch? m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    final int? h = m == null ? null : int.parse(m.group(1)!);
    final int? min = m == null ? null : int.parse(m.group(2)!);
    if (h == null || min == null || h > 23 || min > 59) {
      throw FormatException(
        tr(
          'backup.time 要写成 HH:MM（00:00–23:59），实际 "$s"',
          'backup.time must be HH:MM (00:00-23:59), got "$s"',
        ),
      );
    }
    return h * 60 + min;
  }

  /// 非负整数 GB；空 = null，别的报错。
  static int? parseMaxTotalGb(Object? raw) {
    if (raw == null || '$raw'.trim().isEmpty) return null;
    final int? v = raw is int ? raw : int.tryParse('$raw'.trim());
    if (v == null || v < 0 || v > 1024 * 1024) {
      throw FormatException(
        tr(
          'backup.max_total_gb 要是非负整数（0 = 不限），实际 "$raw"',
          'backup.max_total_gb must be a non-negative integer (0 = no limit), got "$raw"',
        ),
      );
    }
    return v;
  }

  void writeYaml(StringBuffer b, String Function(String) q) {
    b.writeln('backup:');
    b.writeln('  interval: ${q(interval.name)}');
    b.writeln('  time: ${q(time)}');
    b.writeln('  documents: $includeDocuments');
    b.writeln('  max_total_gb: $maxTotalGb');
  }

  @override
  bool operator ==(Object other) =>
      other is ServerBackupConfig &&
      other.interval == interval &&
      other.minuteOfDay == minuteOfDay &&
      other.includeDocuments == includeDocuments &&
      other.maxTotalGb == maxTotalGb;

  @override
  int get hashCode =>
      Object.hash(interval, minuteOfDay, includeDocuments, maxTotalGb);
}
