/// `<data>/backups/` 里的整机备份：三种来源各一个文件名前缀，保留规则按来源分开（D15 / D16）。
///
/// ```
/// fushi_server-backup-<本地 yyyyMMdd-HHmmss>[-n].zip       手动（WebUI「立即备份」/ ctl / admin API）：永不自动删
/// fushi_server-auto-<…>[-n].zip                            自动（计划任务）：分层保留 + 总大小上限
/// fushi_server-pre_update-<…>[-n].zip                      远程更新换包之前：留最新 3 份
/// ```
///
/// 名字只有这三种形状（[isServerBackupFileName]）：admin API 的下载 / 删除只认它们，`..`、分隔符、
/// NTFS 备用数据流之类走不出备份目录。时刻取文件名里的本地时间（不读 zip、不信 mtime——拷贝 /
/// 同步工具会改 mtime）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart'
    show
        BackupRetentionPolicy,
        kRestorePointKeepPreUpdate,
        kRestorePointScheduledRetention,
        planBackupRetention;
import 'package:path/path.dart' as p;

/// 备份来源。[prefix] 是文件名里的那一段，[wire] 是 admin API / CLI 里的名字。
enum ServerBackupKind {
  manual('backup', 'manual'),
  auto('auto', 'auto'),
  preUpdate('pre_update', 'pre_update');

  const ServerBackupKind(this.prefix, this.wire);

  final String prefix;
  final String wire;
}

/// 每种来源的文件名：`fushi_server-<prefix>-<8 位日期>-<6 位时刻>[-n].zip`。
final RegExp _kBackupFileName = RegExp(
  r'^fushi_server-(backup|auto|pre_update)-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})(?:-(\d{1,4}))?\.zip$',
);

/// 更新前备份留最新几份（与 app 的更新前还原点同一个数，D16）。
const int kServerPreUpdateBackupsKept = kRestorePointKeepPreUpdate;

/// [name] 是不是本目录认的备份文件名（三种来源之一）。
bool isServerBackupFileName(String name) => _kBackupFileName.hasMatch(name);

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// [kind] 在本地时刻 [t] 的文件名（不带序号）。
String serverBackupFileNameFor(ServerBackupKind kind, DateTime t) =>
    'fushi_server-${kind.prefix}-${_stamp(t.toLocal())}.zip';

/// [dir] 里还没被占用的 [kind] 文件名：同一秒已有就加 `-2`、`-3`……（`.partial` 也算占用）。
String nextServerBackupFileName(
  Directory dir,
  ServerBackupKind kind,
  DateTime t,
) {
  final String base = serverBackupFileNameFor(kind, t);
  bool taken(String n) =>
      File(p.join(dir.path, n)).existsSync() ||
      File(p.join(dir.path, '$n.partial')).existsSync();
  if (!taken(base)) return base;
  for (int i = 2; ; i++) {
    final String n = base.replaceFirst(RegExp(r'\.zip$'), '-$i.zip');
    if (!taken(n)) return n;
  }
}

/// 一份备份文件。
class ServerBackupEntry {
  const ServerBackupEntry({
    required this.name,
    required this.kind,
    required this.createdAt,
    required this.bytes,
  });

  final String name;
  final ServerBackupKind kind;

  /// 文件名里的本地时刻。
  final DateTime createdAt;
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'kind': kind.wire,
    'bytes': bytes,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// 解析文件名；不是备份文件名 → null。
({ServerBackupKind kind, DateTime createdAt})? parseServerBackupFileName(
  String name,
) {
  final RegExpMatch? m = _kBackupFileName.firstMatch(name);
  if (m == null) return null;
  final ServerBackupKind kind = ServerBackupKind.values.firstWhere(
    (ServerBackupKind k) => k.prefix == m.group(1),
  );
  int g(int i) => int.parse(m.group(i)!);
  return (kind: kind, createdAt: DateTime(g(2), g(3), g(4), g(5), g(6), g(7)));
}

/// 列出 [dir] 里的备份，新 → 旧（同一时刻按名字倒序，`-2` 排在原名前）。[skip] 里的名字（正在写的）不列。
List<ServerBackupEntry> listServerBackups(
  Directory dir, {
  Set<String> skip = const <String>{},
}) {
  final List<ServerBackupEntry> out = <ServerBackupEntry>[];
  if (!dir.existsSync()) return out;
  for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    final String name = p.basename(e.path);
    if (skip.contains(name)) continue;
    final ({ServerBackupKind kind, DateTime createdAt})? parsed =
        parseServerBackupFileName(name);
    if (parsed == null) continue;
    final int bytes;
    try {
      bytes = e.lengthSync();
    } on FileSystemException {
      continue; // 列目录与读大小之间被删了
    }
    out.add(
      ServerBackupEntry(
        name: name,
        kind: parsed.kind,
        createdAt: parsed.createdAt,
        bytes: bytes,
      ),
    );
  }
  out.sort((ServerBackupEntry a, ServerBackupEntry b) {
    final int byTime = b.createdAt.compareTo(a.createdAt);
    if (byTime != 0) return byTime;
    return _seq(b.name).compareTo(_seq(a.name));
  });
  return out;
}

int _seq(String name) {
  final String? s = _kBackupFileName.firstMatch(name)?.group(8);
  return s == null ? 1 : int.parse(s);
}

/// 自动备份的保留：与 app 定时还原点同一套（D3 / D15：最新一份永远留，48 小时全留，之后 7 天每天、
/// 4 周每周、3 个月每月各留最新一份），总大小上限换成服务端设置的 [maxTotalBytes]（null = 不限）。
BackupRetentionPolicy serverAutoBackupRetention(int? maxTotalBytes) {
  const BackupRetentionPolicy k = kRestorePointScheduledRetention;
  return BackupRetentionPolicy(
    keepMinimum: k.keepMinimum,
    keepAllWithin: k.keepAllWithin,
    dailyDays: k.dailyDays,
    weeklyWeeks: k.weeklyWeeks,
    monthlyMonths: k.monthlyMonths,
    maxTotalBytes: maxTotalBytes,
  );
}

/// 规划要删的备份（[newestFirst] 必须是 [listServerBackups] 的顺序）。
///
/// - 手动备份：永不删。
/// - 自动备份：[serverAutoBackupRetention]；[protect] 里的名字（刚写好的那份）不删。
/// - 更新前备份：只留最新 [kServerPreUpdateBackupsKept] 份（[protect] 照样不删）。
List<ServerBackupEntry> planServerBackupPrune(
  List<ServerBackupEntry> newestFirst, {
  required DateTime now,
  required int? maxTotalBytes,
  Set<String> protect = const <String>{},
}) {
  final List<ServerBackupEntry> auto = <ServerBackupEntry>[
    for (final ServerBackupEntry e in newestFirst)
      if (e.kind == ServerBackupKind.auto) e,
  ];
  final List<ServerBackupEntry> preUpdate = <ServerBackupEntry>[
    for (final ServerBackupEntry e in newestFirst)
      if (e.kind == ServerBackupKind.preUpdate) e,
  ];
  return <ServerBackupEntry>[
    ...planBackupRetention<ServerBackupEntry>(
      auto,
      timestampOf: (ServerBackupEntry e) => e.createdAt,
      now: now,
      policy: serverAutoBackupRetention(maxTotalBytes),
      sizeOf: (ServerBackupEntry e) => e.bytes,
      protect: (ServerBackupEntry e) => protect.contains(e.name),
    ),
    for (int i = kServerPreUpdateBackupsKept; i < preUpdate.length; i++)
      if (!protect.contains(preUpdate[i].name)) preUpdate[i],
  ];
}
