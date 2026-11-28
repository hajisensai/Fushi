/// 书库内容对账（BUG-5570）。与设计系统无关的纯存储逻辑。
///
/// 书库消失哨兵（[LibrarySentinel]，BUG-5492）只看书库根里的哨兵文件：哨兵在、token 对得上
/// 就判正常。可书库也会**部分**丢失——整树被清后又部分恢复、外部工具删掉了大部分书目录、
/// 清理工具只扫了 `audiobooks`——这时哨兵还在，数据库行也都在，用户只看到一本本书「缺失」，
/// 启动期什么告警都没有（反馈 1DaVBFXQEI / #4521：94 个解包书目录丢了 82 个、74 个有声书
/// 音频 / 字幕文件丢了）。
///
/// 本模块拿数据库当账本：读出 `epub_books` / `audiobooks` / `srt_books` / `video_books` 里
/// 指向**数据根内受管目录**的路径（[AndroidLibraryDbWitness.libraryRelativeTail] 能取出
/// 数据根内尾段的那些；外部来源、原地播放的视频不算），逐条只做一次 stat，统计「有行、没
/// 文件」的条目。缺失成片（[LibraryContentLoss.isSignificant]）就留下现场
/// （[LibraryContentLoss]，写进 support 根的 [LibraryContentAudit.fileName]），首页请用户
/// 重新扫描 / 从同步恢复 / 带日志反馈。
///
/// 存储暂时不可读不是缺失：
///  - 书库根不存在或列不出来（外部卷未挂载、权限被收回）→ [LibraryContentAuditStatus.rootUnreadable]，
///    什么都不判；
///  - 某个顶层受管目录（`fushi_books`、`audiobooks` …）存在却列不出来 → 它下面的条目记作
///    「不可读」，不算缺失；顶层目录整个不在（书库根本身可读）才是真缺失。
///  - 一条路径按库里原样的绝对路径、和把尾段接到本次书库根上的路径各看一次，任一处在就算在
///    （库里的前缀可能还是旧根，[SandboxRelocation] / 迁移会改写，但不能因此误报）。
///
/// 读库与 stat 整段放在后台 isolate（只读另开一条 SQLite 连接，同 [AndroidLibraryDbWitness]），
/// 不挡冷启动。**只判定、只写现场文件，绝不删除或改动任何数据库行与书库文件。**
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:fushi/src/storage/android_library_db_witness.dart';

/// 对账的媒体种类（现场里的键，进日志；冻结名）。
enum LibraryContentKind {
  /// `epub_books`（format ≠ manga）的解包目录。
  books,

  /// `epub_books`（format = manga）的页图目录。
  manga,

  /// `audiobooks` 的音频目录 / 音频文件 / 字幕。
  audiobooks,

  /// `srt_books` 的字幕与音频。
  subtitleBooks,

  /// `video_books` 里落在数据根内的视频（下载、远程缓存）。
  videos,
}

/// 一类媒体的对账数字。
class LibraryContentKindTally {
  LibraryContentKindTally({
    this.checkedRows = 0,
    this.missingRows = 0,
    this.missingPaths = 0,
    this.unreadableRows = 0,
    List<String>? samples,
  }) : samples = samples ?? <String>[];

  /// 有受管路径、参与对账的行数。
  int checkedRows;

  /// 至少有一条受管路径不在的行数。
  int missingRows;

  /// 不在的受管路径条数（一本有声书可能缺好几个音频文件）。
  int missingPaths;

  /// 所在顶层目录列不出来、判不了的行数（不算缺失）。
  int unreadableRows;

  /// 缺失路径样例（最多 [LibraryContentAudit.maxSamplesPerKind] 条，库里原样的路径）。
  final List<String> samples;

  Map<String, Object?> toJson() => <String, Object?>{
    'checkedRows': checkedRows,
    'missingRows': missingRows,
    'missingPaths': missingPaths,
    'unreadableRows': unreadableRows,
    'samples': samples,
  };

  static LibraryContentKindTally fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return LibraryContentKindTally();
    int read(String key) => raw[key] is int ? raw[key]! as int : 0;
    final Object? samples = raw['samples'];
    return LibraryContentKindTally(
      checkedRows: read('checkedRows'),
      missingRows: read('missingRows'),
      missingPaths: read('missingPaths'),
      unreadableRows: read('unreadableRows'),
      samples: <String>[
        if (samples is List)
          for (final Object? s in samples)
            if (s is String) s,
      ],
    );
  }
}

/// 一次对账的现场：数据库里有行、受管文件不在。
class LibraryContentLoss {
  const LibraryContentLoss({
    required this.detectedAt,
    required this.libraryRoot,
    required this.kinds,
    this.unreadableBuckets = const <String>[],
  });

  final DateTime detectedAt;

  /// 本次用的书库根。
  final String libraryRoot;

  /// 只含有过受管行的种类。
  final Map<LibraryContentKind, LibraryContentKindTally> kinds;

  /// 存在却列不出来的顶层受管目录（其下条目没判）。
  final List<String> unreadableBuckets;

  int get checkedRows => kinds.values.fold<int>(
    0,
    (int a, LibraryContentKindTally k) => a + k.checkedRows,
  );

  int get missingRows => kinds.values.fold<int>(
    0,
    (int a, LibraryContentKindTally k) => a + k.missingRows,
  );

  int get missingPaths => kinds.values.fold<int>(
    0,
    (int a, LibraryContentKindTally k) => a + k.missingPaths,
  );

  /// 「成片」缺失：缺 [LibraryContentAudit.massMissingRows] 行以上，或缺至少
  /// [LibraryContentAudit.minMissingRows] 行且占参与对账行数的
  /// 1/[LibraryContentAudit.missingFractionDenominator] 以上。偶发一两条残行（导入中断留下
  /// 的行之类）不惊动用户，但照样进数据位置环。
  bool get isSignificant {
    final int missing = missingRows;
    if (missing >= LibraryContentAudit.massMissingRows) return true;
    return missing >= LibraryContentAudit.minMissingRows &&
        missing * LibraryContentAudit.missingFractionDenominator >= checkedRows;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'detectedAt': detectedAt.toIso8601String(),
    'libraryRoot': libraryRoot,
    'kinds': <String, Object?>{
      for (final MapEntry<LibraryContentKind, LibraryContentKindTally> e
          in kinds.entries)
        e.key.name: e.value.toJson(),
    },
    'unreadableBuckets': unreadableBuckets,
  };

  static LibraryContentLoss? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final DateTime? detectedAt = DateTime.tryParse('${raw['detectedAt']}');
    if (detectedAt == null) return null;
    final Object? kinds = raw['kinds'];
    final Object? buckets = raw['unreadableBuckets'];
    return LibraryContentLoss(
      detectedAt: detectedAt,
      libraryRoot: '${raw['libraryRoot'] ?? ''}',
      kinds: <LibraryContentKind, LibraryContentKindTally>{
        if (kinds is Map<String, Object?>)
          for (final LibraryContentKind k in LibraryContentKind.values)
            if (kinds.containsKey(k.name))
              k: LibraryContentKindTally.fromJson(kinds[k.name]),
      },
      unreadableBuckets: <String>[
        if (buckets is List)
          for (final Object? b in buckets)
            if (b is String) b,
      ],
    );
  }

  /// 一行诊断（进数据位置取证环与反馈正文）：时间 + [summary]。
  String describe() => '书库内容对账 ${detectedAt.toIso8601String()}：${summary()}';

  /// 不带时间的现场摘要：同一批缺失每次启动得到同一串，数据位置环按它去重。
  String summary() {
    final List<String> parts = <String>[
      for (final MapEntry<LibraryContentKind, LibraryContentKindTally> e
          in kinds.entries)
        '${e.key.name} 缺 ${e.value.missingRows}/${e.value.checkedRows} 行'
            '（${e.value.missingPaths} 条路径'
            '${e.value.unreadableRows > 0 ? '，${e.value.unreadableRows} 行不可读未判' : ''}）'
            '${e.value.samples.isEmpty ? '' : '，样例 ${e.value.samples.join(' | ')}'}',
    ];
    return '$libraryRoot：数据库有行、受管文件不在 $missingRows/$checkedRows 行；'
        '${parts.join('；')}'
        '${unreadableBuckets.isEmpty ? '' : '；列不出来的目录：${unreadableBuckets.join('，')}'}';
  }
}

/// [LibraryContentAudit.run] 的结论。
enum LibraryContentAuditStatus {
  /// 没有缺失（或没有受管行）。
  clean,

  /// 有零星缺失，不到「成片」：只进日志，不提示。
  minor,

  /// 成片缺失且比上次提示过的多：留下待提示现场。
  incident,

  /// 成片缺失，但不比上次提示过的多：不重复提示。
  alreadyReported,

  /// 书库根不存在 / 列不出来（卷未挂载、权限被收回）：什么都不判。
  rootUnreadable,

  /// 主库读不到（不存在 / 打不开 / 超时）或现场文件写不进去：什么都没改。
  error,
}

class LibraryContentAuditResult {
  const LibraryContentAuditResult(this.status, {this.loss, this.error});

  final LibraryContentAuditStatus status;

  /// [LibraryContentAuditStatus.minor] / [incident] / [alreadyReported] 时的现场。
  final LibraryContentLoss? loss;
  final Object? error;
}

/// 一行数据库记录：种类 + 它指向的全部路径（库里原样）。
typedef LibraryContentRow = ({LibraryContentKind kind, List<String> paths});

/// 见文件头。
class LibraryContentAudit {
  const LibraryContentAudit._();

  /// support 根里的现场文件名。
  static const String fileName = 'library_content_audit.json';

  static const int maxSamplesPerKind = 3;
  static const int massMissingRows = 20;
  static const int minMissingRows = 2;
  static const int missingFractionDenominator = 10;

  static File _file(Directory supportRoot) =>
      File(p.join(supportRoot.path, fileName));

  /// 只读打开 [dbPath] 读出全部受管候选行；打不开返回 null，单条查询失败（老 schema）跳过。
  static List<LibraryContentRow>? readRowsSync(String dbPath) {
    final sqlite.Database db;
    try {
      db = sqlite.sqlite3.open(dbPath, mode: sqlite.OpenMode.readOnly);
    } catch (_) {
      return null;
    }
    final List<LibraryContentRow> rows = <LibraryContentRow>[];
    void query(String sql, LibraryContentRow? Function(sqlite.Row) map) {
      try {
        for (final sqlite.Row row in db.select(sql)) {
          final LibraryContentRow? mapped = map(row);
          if (mapped != null) rows.add(mapped);
        }
      } on sqlite.SqliteException {
        // 表 / 列不存在：跳过这一类。
      }
    }

    try {
      query(
        'SELECT extract_dir AS a, format AS f FROM epub_books',
        (sqlite.Row r) => (
          kind: r['f'] == 'manga'
              ? LibraryContentKind.manga
              : LibraryContentKind.books,
          paths: _strings(<Object?>[r['a']]),
        ),
      );
      query(
        'SELECT audio_root AS a, audio_paths_json AS j, alignment_path AS s '
        'FROM audiobooks',
        (sqlite.Row r) => (
          kind: LibraryContentKind.audiobooks,
          paths: _strings(<Object?>[r['a'], r['s'], ..._jsonList(r['j'])]),
        ),
      );
      query(
        'SELECT srt_path AS s, audio_root AS a, audio_paths_json AS j '
        'FROM srt_books',
        (sqlite.Row r) => (
          kind: LibraryContentKind.subtitleBooks,
          paths: _strings(<Object?>[r['s'], r['a'], ..._jsonList(r['j'])]),
        ),
      );
      query(
        'SELECT video_path AS v FROM video_books',
        (sqlite.Row r) => (
          kind: LibraryContentKind.videos,
          paths: _strings(<Object?>[r['v']]),
        ),
      );
      return rows;
    } catch (_) {
      return null;
    } finally {
      db.dispose();
    }
  }

  static List<String> _strings(List<Object?> raw) => <String>[
    for (final Object? v in raw)
      if (v is String && v.isNotEmpty) v,
  ];

  static List<Object?> _jsonList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <Object?>[];
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is List ? decoded : const <Object?>[];
    } on FormatException {
      return const <Object?>[];
    }
  }

  /// 纯对账（测试钉住）：[rows] 里每条受管路径在 [libraryRoot] 下是否还在。
  ///
  /// [exists] 是「这条路径（文件或目录）在不在」；[bucketReadable] 是「这个顶层受管目录在
  /// 本次书库根下是 `true` 可列 / `false` 不在 / `null` 存在却列不出来」。调用方保证书库根本身
  /// 可读（[run] 先查）。
  static LibraryContentLoss tally({
    required Iterable<LibraryContentRow> rows,
    required String libraryRoot,
    required bool Function(String path) exists,
    required bool? Function(String bucketPath) bucketReadable,
    required DateTime at,
  }) {
    final Map<LibraryContentKind, LibraryContentKindTally> kinds =
        <LibraryContentKind, LibraryContentKindTally>{};
    final Map<String, bool?> bucketState = <String, bool?>{};
    final Set<String> unreadable = <String>{};
    for (final LibraryContentRow row in rows) {
      int managed = 0;
      int missing = 0;
      bool rowUnreadable = false;
      final List<String> missingSamples = <String>[];
      final Set<String> seen = <String>{};
      for (final String stored in row.paths) {
        final String? tail = AndroidLibraryDbWitness.libraryRelativeTail(
          stored,
        );
        if (tail == null || !seen.add(tail)) continue;
        managed++;
        final List<String> parts = tail.split('/');
        final String bucket = parts.first;
        final bool? readable = bucketState.putIfAbsent(
          bucket,
          () => bucketReadable(p.join(libraryRoot, bucket)),
        );
        if (readable == null) {
          rowUnreadable = true;
          unreadable.add(bucket);
          continue;
        }
        if (exists(stored) ||
            exists(p.joinAll(<String>[libraryRoot, ...parts]))) {
          continue;
        }
        missing++;
        missingSamples.add(stored);
      }
      if (managed == 0) continue;
      final LibraryContentKindTally k = kinds.putIfAbsent(
        row.kind,
        LibraryContentKindTally.new,
      );
      k.checkedRows++;
      if (missing > 0) {
        k.missingRows++;
        k.missingPaths += missing;
        for (final String s in missingSamples) {
          if (k.samples.length >= maxSamplesPerKind) break;
          k.samples.add(s);
        }
      } else if (rowUnreadable) {
        k.unreadableRows++;
      }
    }
    return LibraryContentLoss(
      detectedAt: at,
      libraryRoot: libraryRoot,
      kinds: kinds,
      unreadableBuckets: unreadable.toList()..sort(),
    );
  }

  /// 真实磁盘上的存在判据（文件或目录，不跟随链接）。
  static bool pathExists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// 目录三态：可列 → true；不在 → false；在但列不出来 → null。
  static bool? directoryReadable(String path) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      // stat 本身失败时 existsSync 也是 false；父目录（书库根）可读才轮得到这里。
      return false;
    }
    try {
      dir.listSync(followLinks: false).take(1).toList();
      return true;
    } on FileSystemException {
      return null;
    }
  }

  /// 启动期对账（见文件头）。不抛异常。主库按 [AndroidLibraryDbWitness.databasePathIn] 在
  /// [supportRoot] 下找；读库与 stat 在后台 isolate。
  static Future<LibraryContentAuditResult> run({
    required Directory libraryRoot,
    required Directory supportRoot,
    DateTime? now,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final DateTime at = now ?? DateTime.now();
    final String root = libraryRoot.path;
    try {
      final String? databasePath = await AndroidLibraryDbWitness.databasePathIn(
        supportRoot,
      );
      if (databasePath == null) {
        return const LibraryContentAuditResult(
          LibraryContentAuditStatus.error,
          error: '主库不存在',
        );
      }
      final ({bool rootReadable, LibraryContentLoss? loss})? scanned =
          await Isolate.run<({bool rootReadable, LibraryContentLoss? loss})?>(
            () {
              if (directoryReadable(root) != true) {
                return (rootReadable: false, loss: null);
              }
              final List<LibraryContentRow>? rows = readRowsSync(databasePath);
              if (rows == null) return null;
              return (
                rootReadable: true,
                loss: tally(
                  rows: rows,
                  libraryRoot: root,
                  exists: pathExists,
                  bucketReadable: directoryReadable,
                  at: at,
                ),
              );
            },
          ).timeout(timeout, onTimeout: () => null);
      if (scanned == null) {
        return const LibraryContentAuditResult(
          LibraryContentAuditStatus.error,
          error: '主库读不到或对账超时',
        );
      }
      if (!scanned.rootReadable) {
        return const LibraryContentAuditResult(
          LibraryContentAuditStatus.rootUnreadable,
        );
      }
      final LibraryContentLoss loss = scanned.loss!;
      final Map<String, Object?> record = await _readRecord(supportRoot);
      final int reported = record['reportedMissingRows'] is int
          ? record['reportedMissingRows']! as int
          : 0;
      final LibraryContentLoss? pending = LibraryContentLoss.fromJson(
        record['pending'],
      );
      if (loss.missingRows == 0) {
        if (reported != 0 || pending != null) {
          await _writeRecord(supportRoot, reported: 0, pending: null);
        }
        return LibraryContentAuditResult(
          LibraryContentAuditStatus.clean,
          loss: loss,
        );
      }
      if (!loss.isSignificant) {
        return LibraryContentAuditResult(
          LibraryContentAuditStatus.minor,
          loss: loss,
        );
      }
      if (loss.missingRows <= reported) {
        // 恢复了一部分：把基线降到现状，之后再丢才会重新提示。
        if (loss.missingRows < reported) {
          await _writeRecord(
            supportRoot,
            reported: loss.missingRows,
            pending: pending,
          );
        }
        return LibraryContentAuditResult(
          LibraryContentAuditStatus.alreadyReported,
          loss: loss,
        );
      }
      await _writeRecord(
        supportRoot,
        reported: loss.missingRows,
        pending: loss,
      );
      return LibraryContentAuditResult(
        LibraryContentAuditStatus.incident,
        loss: loss,
      );
    } on Object catch (e) {
      return LibraryContentAuditResult(
        LibraryContentAuditStatus.error,
        error: e,
      );
    }
  }

  static Future<Map<String, Object?>> _readRecord(Directory supportRoot) async {
    try {
      final File f = _file(supportRoot);
      if (!await f.exists()) return <String, Object?>{};
      final Object? decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on Object {
      return <String, Object?>{};
    }
  }

  static Future<void> _writeRecord(
    Directory supportRoot, {
    required int reported,
    required LibraryContentLoss? pending,
  }) async {
    final File target = _file(supportRoot);
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{
        'reportedMissingRows': reported,
        'pending': pending?.toJson(),
      }),
      flush: true,
    );
    await tmp.rename(target.path);
  }

  /// 等用户处理的现场（首页提示读它）；没有返回 null。
  static Future<LibraryContentLoss?> pendingLoss(Directory supportRoot) async =>
      LibraryContentLoss.fromJson((await _readRecord(supportRoot))['pending']);

  /// 提示过后清掉现场；「已提示过的缺失行数」保留，同一批缺失不再反复提示。
  static Future<void> clearPending(Directory supportRoot) async {
    final Map<String, Object?> record = await _readRecord(supportRoot);
    if (record['pending'] == null) return;
    await _writeRecord(
      supportRoot,
      reported: record['reportedMissingRows'] is int
          ? record['reportedMissingRows']! as int
          : 0,
      pending: null,
    );
  }
}
