import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart'
    show fushiDatabaseFileName, legacyHibikiDatabaseFileName;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:fushi/src/storage/app_paths.dart';

/// Android 书库两个候选根（内部 / 外部）**都有书库文件**时，用数据库里的存量路径作证
/// 判断书库到底在哪个根（拍板台 review-library-anchor-both-roots，承接 BUG-5375）。
///
/// 场景：锚点曾被冲到错的根，那段时间里用户又往错的根导入了书——两边都有文件，单看
/// 磁盘「哪边有文件」已经分不出真假。数据库才是书库的账本：读出它记的全部书库路径，取
/// 数据根内的相对尾段（`fushi_books/<key>` 等），看这条尾段**只在哪个根**里存在。
///
/// 只认「只在一边存在」的样本：中断的跨盘迁移会让同一尾段两边都在（复制阶段不删源），
/// 那不说明书库在哪；两边都不在的是早已删掉的书。按尾段而非整条绝对路径比较，所以与
/// 库里记的是哪个根的前缀无关（台账重基前后结论一致，重复启动不会来回翻）。
///
/// 时序：这一步在 [AppPaths.resolve] 里跑，早于 app 打开主库，所以这里只读、轻量地
/// 另开一条 SQLite 只读连接（[readStoredLibraryPaths]），读完即关，不跑迁移、不建表；
/// 打不开 / 表不存在都当「没有证据」，由调用方沿用锚点。
class AndroidLibraryDbWitness {
  const AndroidLibraryDbWitness({
    required this.sampled,
    required this.onlyInAnchored,
    required this.onlyInOther,
  });

  /// 带数据根内尾段、参与比较的样本数。
  final int sampled;

  /// 尾段只在锚定的根里存在的样本数。
  final int onlyInAnchored;

  /// 尾段只在另一个根里存在的样本数。
  final int onlyInOther;

  /// 证据是否指向另一个根：严格多数才算（平局 = 迁移中断的完整副本，沿用锚点）。
  bool get favorsOther => onlyInOther > onlyInAnchored;

  /// 读主库用的查询：都是指向数据根内书库内容的列。表 / 列不存在（老 schema）就跳过。
  ///
  /// **全表读、不抽样**：两边都有书的成因正是「锚点错指期间往错的根导入了书」，错根里的
  /// 恰恰是最新的那批行。只取最新 N 行（曾经是 `ORDER BY rowid DESC LIMIT 1000`）在书多于
  /// N 本时会让错根里的新书占满样本、反把真书库判成落选根，随后整库往错根搬。只读几列
  /// 路径字符串、在后台 isolate 里逐条 stat，几千本也是亚秒级，且只在两边都有书这一罕见
  /// 情形才跑。
  static const List<String> _queries = <String>[
    'SELECT extract_dir AS p FROM epub_books',
    'SELECT audio_root AS p FROM audiobooks WHERE audio_root IS NOT NULL',
    'SELECT srt_path AS p FROM srt_books',
    'SELECT video_path AS p FROM video_books',
    'SELECT cover_path AS p FROM video_books WHERE cover_path IS NOT NULL',
  ];

  /// 只读地从 [supportRoot] 下的主库（兼看旧名）读出书库路径；主库不存在、打不开
  /// 或超时返回 null（没有证据）。SQLite 读放后台 isolate，不卡启动的 UI 线程。
  static Future<List<String>?> readStoredLibraryPaths(
    Directory supportRoot, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? path = await databasePathIn(supportRoot);
    if (path == null) return null;
    try {
      return await Isolate.run<List<String>?>(
        () => readStoredLibraryPathsSync(path),
      ).timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// [supportRoot] 下现存的主库文件（兼看旧名）；都不存在返回 null。书库内容对账
  /// （`LibraryContentAudit`）也用它找主库。
  static Future<String?> databasePathIn(Directory supportRoot) async {
    for (final String name in <String>[
      fushiDatabaseFileName,
      legacyHibikiDatabaseFileName,
    ]) {
      final String candidate = p.join(supportRoot.path, name);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// [readStoredLibraryPaths] 的同步内核：只读打开 [dbPath]、按 [_queries] 取样后关闭。
  /// 打不开返回 null；单条查询失败（表 / 列不存在）只跳过那一条。
  static List<String>? readStoredLibraryPathsSync(String dbPath) {
    final sqlite.Database db;
    try {
      db = sqlite.sqlite3.open(dbPath, mode: sqlite.OpenMode.readOnly);
    } catch (_) {
      return null;
    }
    try {
      final List<String> paths = <String>[];
      for (final String sql in _queries) {
        try {
          for (final sqlite.Row row in db.select(sql)) {
            final Object? value = row['p'];
            if (value is String && value.isNotEmpty) paths.add(value);
          }
        } on sqlite.SqliteException {
          continue;
        }
      }
      return paths;
    } catch (_) {
      return null;
    } finally {
      db.dispose();
    }
  }

  /// 存量绝对路径在数据根内的相对尾段（`fushi_books/<key>/...`，`/` 分隔）；不是数据根
  /// 内路径（相对路径、外部媒体库、不计证据的运行目录）返回 null。
  ///
  /// 从右往左找 [AppPaths.fushiOwnedDocumentsEntries] 段（同 `SandboxRelocation` 反推旧根的
  /// 判据：根自己的路径里也可能出现同名段，靠右那个才是数据根首段）。
  static String? libraryRelativeTail(String storedPath) {
    if (storedPath.isEmpty) return null;
    final String normalized = storedPath.replaceAll('\\', '/');
    final bool absolute =
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
    if (!absolute) return null;
    final List<String> segments = normalized
        .split('/')
        .where((String s) => s.isNotEmpty)
        .toList();
    for (int i = segments.length - 1; i > 0; i--) {
      final String segment = segments[i];
      String? owned;
      for (final String name in AppPaths.fushiOwnedDocumentsEntries) {
        if (name.toLowerCase() == segment.toLowerCase()) {
          owned = name;
          break;
        }
      }
      if (owned == null) continue;
      if (AppPaths.libraryEvidenceIgnoredEntries.contains(owned)) return null;
      // 只有首段本身（整个目录）不指向任何一本书，不作证。
      if (i == segments.length - 1) return null;
      return <String>[owned, ...segments.sublist(i + 1)].join('/');
    }
    return null;
  }

  /// 纯计票（[exists] 注入以便单测）：每条样本取尾段，看它在 [anchoredRoot] /
  /// [otherRoot] 下是否存在。
  static AndroidLibraryDbWitness tally({
    required Iterable<String> storedPaths,
    required String anchoredRoot,
    required String otherRoot,
    required bool Function(String path) exists,
  }) {
    final ({int sampled, List<int> onlyIn}) votes = tallyRoots(
      storedPaths: storedPaths,
      roots: <String>[anchoredRoot, otherRoot],
      exists: exists,
    );
    return AndroidLibraryDbWitness(
      sampled: votes.sampled,
      onlyInAnchored: votes.onlyIn[0],
      onlyInOther: votes.onlyIn[1],
    );
  }

  /// [tally] 的多根版本（BUG-5450：书库可能散在外部与几种内部布局里，不止两个根）：
  /// 每条尾段只在**恰好一个**根里存在时给那个根记一票，返回与 [roots] 同序的票数。
  static ({int sampled, List<int> onlyIn}) tallyRoots({
    required Iterable<String> storedPaths,
    required List<String> roots,
    required bool Function(String path) exists,
  }) {
    int sampled = 0;
    final List<int> onlyIn = List<int>.filled(roots.length, 0);
    final Set<String> seen = <String>{};
    for (final String stored in storedPaths) {
      final String? tail = libraryRelativeTail(stored);
      if (tail == null || !seen.add(tail)) continue;
      sampled++;
      final List<String> parts = tail.split('/');
      int? only;
      int hits = 0;
      for (int i = 0; i < roots.length; i++) {
        if (exists(p.joinAll(<String>[roots[i], ...parts]))) {
          hits++;
          only = i;
        }
      }
      if (hits == 1) onlyIn[only!]++;
    }
    return (sampled: sampled, onlyIn: onlyIn);
  }

  /// 读主库、对 [roots] 计票（[tallyRoots]），返回与 [roots] 同序的「只在该根存在」票数；
  /// 没有证据（主库不存在 / 打不开 / 超时）返回 null。读库与 stat 同 [probe] 放后台 isolate。
  static Future<List<int>?> probeRoots({
    required Directory supportRoot,
    required List<Directory> roots,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? path = await databasePathIn(supportRoot);
    if (path == null) return null;
    final List<String> rootPaths = <String>[
      for (final Directory d in roots) d.path,
    ];
    try {
      return await Isolate.run<List<int>?>(() {
        final List<String>? paths = readStoredLibraryPathsSync(path);
        if (paths == null) return null;
        return tallyRoots(
          storedPaths: paths,
          roots: rootPaths,
          exists: pathExists,
        ).onlyIn;
      }).timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// 真实磁盘上的存在判据（文件或目录）。
  static bool pathExists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// 读主库并计票；没有证据（主库不存在 / 打不开 / 超时）返回 null。
  ///
  /// 读库与计票（每条尾段两次 stat）整段放在后台 isolate：全表读时 stat 次数随书量
  /// 线性增长，不能落在启动期的 UI isolate 上。
  static Future<AndroidLibraryDbWitness?> probe({
    required Directory supportRoot,
    required Directory anchoredRoot,
    required Directory otherRoot,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? path = await databasePathIn(supportRoot);
    if (path == null) return null;
    final String anchored = anchoredRoot.path;
    final String other = otherRoot.path;
    try {
      return await Isolate.run<AndroidLibraryDbWitness?>(() {
        final List<String>? paths = readStoredLibraryPathsSync(path);
        if (paths == null) return null;
        return tally(
          storedPaths: paths,
          anchoredRoot: anchored,
          otherRoot: other,
          exists: pathExists,
        );
      }).timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'sampled=$sampled onlyInAnchored=$onlyInAnchored onlyInOther=$onlyInOther';
}
