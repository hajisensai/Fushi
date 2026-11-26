/// 书库消失哨兵（BUG-5492）。与设计系统无关的纯存储逻辑。
///
/// 书库根（documents 根）里放一个隐藏哨兵文件 [LibrarySentinel.sentinelFileName]，内部
/// support 根里记一份「应有的哨兵 token + 上次见到它的时间 + 书库各顶层目录的条目数」
/// （[LibrarySentinel.recordFileName]）。support 根在 Android 上是 `/data/user/0/<包名>/files`，
/// 文件管理器、电脑 USB、手机清理工具都碰不到；书库根若在外部 `Android/data/...`，能被
/// 它们整树删掉，而 Fushi 拦不住（反馈 cH-HbP8XkQ、MXX0xhQDgt）。
///
/// 每次冷启动（书库根判定、散书合并、沙箱重定位都跑完之后）调 [LibrarySentinel.check]：
///  - 没有记录 → 布防（写哨兵与记录）；
///  - 哨兵 token 与记录一致 → 正常，刷新「上次见到」与条目数；
///  - 哨兵不在 / token 不同，且书库条目数比上次少 → 判定「书库被外部清空过」，把现场
///    （上次见到的时间、前后条目数、路径）记成 [LibraryVanishIncident] 留在记录里，等首页
///    提示用户上传日志；然后重新布防；
///  - 哨兵不在但条目数没少（恢复备份、iOS 容器搬家这类合法整树重写）→ 只重新布防。
///
/// **只判定、只写哨兵与记录，绝不删除或改动任何书库文件。**
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 一次「书库被外部清空」的现场。
class LibraryVanishIncident {
  const LibraryVanishIncident({
    required this.detectedAt,
    required this.lastSeenAt,
    required this.previousRoot,
    required this.currentRoot,
    required this.previousCounts,
    required this.currentCounts,
    required this.sentinelState,
  });

  /// 本次启动发现的时间。
  final DateTime detectedAt;

  /// 上一次启动时哨兵还在的时间：书库是在这之后、[detectedAt] 之前没的。
  final DateTime lastSeenAt;

  /// 上次见到哨兵时的书库根 / 本次的书库根（不同 = 书库根判定换过位置）。
  final String previousRoot;
  final String currentRoot;

  /// 书库各顶层目录的直接条目数（上次 / 本次）。
  final Map<String, int> previousCounts;
  final Map<String, int> currentCounts;

  /// `missing`：哨兵文件不在；`foreign`：在，但 token 不是记录里那个。
  final String sentinelState;

  int get previousTotal => LibrarySentinel.totalOf(previousCounts);
  int get currentTotal => LibrarySentinel.totalOf(currentCounts);

  Map<String, Object?> toJson() => <String, Object?>{
    'detectedAt': detectedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt.toIso8601String(),
    'previousRoot': previousRoot,
    'currentRoot': currentRoot,
    'previousCounts': previousCounts,
    'currentCounts': currentCounts,
    'sentinelState': sentinelState,
  };

  static LibraryVanishIncident? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final DateTime? detectedAt = DateTime.tryParse('${raw['detectedAt']}');
    final DateTime? lastSeenAt = DateTime.tryParse('${raw['lastSeenAt']}');
    if (detectedAt == null || lastSeenAt == null) return null;
    return LibraryVanishIncident(
      detectedAt: detectedAt,
      lastSeenAt: lastSeenAt,
      previousRoot: '${raw['previousRoot'] ?? ''}',
      currentRoot: '${raw['currentRoot'] ?? ''}',
      previousCounts: LibrarySentinel._countsFromJson(raw['previousCounts']),
      currentCounts: LibrarySentinel._countsFromJson(raw['currentCounts']),
      sentinelState: '${raw['sentinelState'] ?? 'missing'}',
    );
  }

  /// 一行诊断（进数据位置取证环与反馈正文）。
  String describe() {
    final List<String> dropped = <String>[
      for (final MapEntry<String, int> e in previousCounts.entries)
        if (e.value > (currentCounts[e.key] ?? 0))
          '${e.key} ${e.value}→${currentCounts[e.key] ?? 0}',
    ];
    return '书库哨兵$sentinelState：上次见到 ${lastSeenAt.toIso8601String()}'
        '（$previousRoot），本次 ${detectedAt.toIso8601String()}（$currentRoot）；'
        '条目 $previousTotal→$currentTotal；'
        '${dropped.isEmpty ? '' : '减少：${dropped.join('，')}'}';
  }
}

/// [LibrarySentinel.check] 的结论。
enum LibrarySentinelStatus {
  /// 第一次布防（没有记录 / 记录坏了）。
  armed,

  /// 哨兵在、token 对得上。
  intact,

  /// 哨兵没了但条目数没少：合法整树重写，已重新布防。
  rearmed,

  /// 哨兵没了且条目数变少：书库被外部清空过（[LibrarySentinelResult.incident]）。
  vanished,

  /// 读写哨兵 / 记录出错，什么都没改。
  error,
}

class LibrarySentinelResult {
  const LibrarySentinelResult(this.status, {this.incident, this.error});

  final LibrarySentinelStatus status;
  final LibraryVanishIncident? incident;
  final Object? error;
}

/// 见文件头。
class LibrarySentinel {
  const LibrarySentinel._();

  /// 书库根里的哨兵文件名（隐藏文件，内容是一个随机 token）。
  static const String sentinelFileName = AppPaths.librarySentinelFileName;

  /// support 根里的记录文件名。
  static const String recordFileName = 'library_sentinel.json';

  /// 计条目数的顶层目录：Fushi 自有顶层项去掉不算书库证据的运行目录。
  static Set<String> get countedTopLevelNames => AppPaths
      .fushiOwnedDocumentsEntries
      .difference(AppPaths.libraryEvidenceIgnoredEntries);

  static int totalOf(Map<String, int> counts) =>
      counts.values.fold<int>(0, (int a, int b) => a + b);

  static Map<String, int> _countsFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return <String, int>{};
    return <String, int>{
      for (final MapEntry<String, Object?> e in raw.entries)
        if (e.value is int) e.key: e.value! as int,
    };
  }

  /// [libraryRoot] 下各计数顶层目录的直接条目数（`.nomedia` 与中断复制的半截文件不算）。
  /// 只列一层，不递归：书库再大也只有几十次 `list`。目录不存在 / 列不出来记 0。
  static Future<Map<String, int>> countEntries(Directory libraryRoot) async {
    final Map<String, int> counts = <String, int>{};
    for (final String name in countedTopLevelNames) {
      final Directory dir = Directory(p.join(libraryRoot.path, name));
      int n = 0;
      try {
        if (await dir.exists()) {
          await for (final FileSystemEntity e in dir.list(followLinks: false)) {
            if (AppPaths.isLibraryEvidenceFileName(p.basename(e.path))) n++;
          }
        }
      } on FileSystemException {
        n = 0;
      }
      if (n > 0) counts[name] = n;
    }
    return counts;
  }

  static File _recordFile(Directory supportRoot) =>
      File(p.join(supportRoot.path, recordFileName));

  static File _sentinelFile(Directory libraryRoot) =>
      File(p.join(libraryRoot.path, sentinelFileName));

  static String _newToken() {
    final Random rng = Random.secure();
    return List<String>.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// 临时文件 + 改名，整份替换（崩在半途不会留下半截记录 / 哨兵）。
  static Future<void> _writeAtomic(File target, String content) async {
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target.path);
  }

  static Future<Map<String, Object?>?> _readRecord(
    Directory supportRoot,
  ) async {
    try {
      final File f = _recordFile(supportRoot);
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      return null;
    }
  }

  static Future<String?> _readSentinel(Directory libraryRoot) async {
    final File f = _sentinelFile(libraryRoot);
    if (!await f.exists()) return null;
    return (await f.readAsString()).trim();
  }

  /// 启动期检查（见文件头）。不抛异常：IO 出错返回 [LibrarySentinelStatus.error]。
  static Future<LibrarySentinelResult> check({
    required Directory libraryRoot,
    required Directory supportRoot,
    DateTime? now,
  }) async {
    final DateTime at = now ?? DateTime.now();
    try {
      final Map<String, Object?>? record = await _readRecord(supportRoot);
      final String? sentinel = await _readSentinel(libraryRoot);
      final Map<String, int> counts = await countEntries(libraryRoot);
      final String? token = record?['token'] as String?;
      final LibraryVanishIncident? pending = LibraryVanishIncident.fromJson(
        record?['incident'],
      );

      if (record == null || token == null || token.isEmpty) {
        await _arm(libraryRoot, supportRoot, counts, at, pending);
        return const LibrarySentinelResult(LibrarySentinelStatus.armed);
      }
      if (sentinel == token) {
        await _writeRecord(
          supportRoot,
          token: token,
          root: libraryRoot.path,
          armedAt: '${record['armedAt'] ?? at.toIso8601String()}',
          lastSeenAt: at,
          counts: counts,
          incident: pending,
        );
        return const LibrarySentinelResult(LibrarySentinelStatus.intact);
      }

      final Map<String, int> previous = _countsFromJson(record['counts']);
      if (totalOf(counts) >= totalOf(previous)) {
        await _arm(libraryRoot, supportRoot, counts, at, pending);
        return const LibrarySentinelResult(LibrarySentinelStatus.rearmed);
      }
      final LibraryVanishIncident incident = LibraryVanishIncident(
        detectedAt: at,
        lastSeenAt:
            DateTime.tryParse('${record['lastSeenAt']}') ??
            DateTime.tryParse('${record['armedAt']}') ??
            at,
        previousRoot: '${record['root'] ?? ''}',
        currentRoot: libraryRoot.path,
        previousCounts: previous,
        currentCounts: counts,
        sentinelState: sentinel == null ? 'missing' : 'foreign',
      );
      await _arm(libraryRoot, supportRoot, counts, at, incident);
      return LibrarySentinelResult(
        LibrarySentinelStatus.vanished,
        incident: incident,
      );
    } on Object catch (e) {
      return LibrarySentinelResult(LibrarySentinelStatus.error, error: e);
    }
  }

  /// 换新 token：先写哨兵、再写记录。哨兵写不进去（书库根不可写）就抛，记录保持原样，
  /// 下次启动按旧记录再判一次。
  static Future<void> _arm(
    Directory libraryRoot,
    Directory supportRoot,
    Map<String, int> counts,
    DateTime at,
    LibraryVanishIncident? incident,
  ) async {
    final String token = _newToken();
    await _writeAtomic(_sentinelFile(libraryRoot), token);
    await _writeRecord(
      supportRoot,
      token: token,
      root: libraryRoot.path,
      armedAt: at.toIso8601String(),
      lastSeenAt: at,
      counts: counts,
      incident: incident,
    );
  }

  static Future<void> _writeRecord(
    Directory supportRoot, {
    required String token,
    required String root,
    required String armedAt,
    required DateTime lastSeenAt,
    required Map<String, int> counts,
    required LibraryVanishIncident? incident,
  }) => _writeAtomic(
    _recordFile(supportRoot),
    jsonEncode(<String, Object?>{
      'token': token,
      'root': root,
      'armedAt': armedAt,
      'lastSeenAt': lastSeenAt.toIso8601String(),
      'counts': counts,
      'incident': incident?.toJson(),
    }),
  );

  /// 记录里等用户处理的现场（首页提示读它）；没有返回 null。
  static Future<LibraryVanishIncident?> pendingIncident(
    Directory supportRoot,
  ) async => LibraryVanishIncident.fromJson(
    (await _readRecord(supportRoot))?['incident'],
  );

  /// 用户处理过提示（上传或稍后）后清掉现场，记录其余部分不动。
  static Future<void> clearIncident(Directory supportRoot) async {
    final Map<String, Object?>? record = await _readRecord(supportRoot);
    if (record == null || record['incident'] == null) return;
    record['incident'] = null;
    await _writeAtomic(_recordFile(supportRoot), jsonEncode(record));
  }
}
