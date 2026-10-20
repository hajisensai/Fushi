/// 「从 Anki 迁移」的来源侧：找到本机 Anki / AnkiDroid 的用户数据目录，把集合拍成只读快照。
///
/// - [ankiDataRoots]：按平台列出 Anki 用户数据根（纯函数，可单测）。桌面 Anki 的根下每个
///   profile 一个子目录（`<根>/<profile>/collection.anki2` + `collection.media/`）；
///   AnkiDroid 的根本身就是集合目录（`/storage/emulated/0/AnkiDroid/collection.anki2`）。
/// - [discoverAnkiProfiles]：在这些根下找集合。
/// - [snapshotAnkiCollection]：把 `collection.anki2` 连同 `-wal` / `-journal` 拷进临时目录，
///   在**副本**上回放 WAL、做完整性检查。Anki 开着时集合可能处在 WAL 模式、最新的修改还没
///   落进主文件，只拷主文件会丢掉这部分。整组文件拷**两遍**、比对两份副本的内容哈希：
///   期间被写过（哪怕大小与修改时刻都没变，例如 WAL 重置后原位覆盖）就报
///   [AnkiSnapshotFailure.changedDuringCopy]，不拿一份撕裂的快照去导入。
///
/// 用户的 Anki 数据**只读**：原始集合只被 `File.copy` 读（两遍），不打开、不加锁、不写；
/// 媒体（[AnkiMediaFolder]）原位按名字读，不拷整个目录。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart' show ffcSha256FileSync;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi_engine/srs/apkg/anki_collection_db.dart';

/// Anki 集合文件名（桌面 Anki 2.1.x 与 AnkiDroid 相同；Anki 23.10+ 仍是这个名字，
/// 内容是 schema 18）。
const String ankiCollectionFileName = 'collection.anki2';

/// 集合旁的媒体目录名。
const String ankiMediaFolderName = 'collection.media';

/// 一个 Anki 用户数据根来自哪种客户端。
enum AnkiDataRootKind {
  /// 桌面 Anki：根下每个 profile 一个子目录。
  desktop,

  /// AnkiDroid：根本身就是集合目录。
  ankiDroid,

  /// 用户手动选的文件夹（两种布局都认）。
  custom,
}

/// 一个待扫描的 Anki 用户数据根。
class AnkiDataRoot {
  const AnkiDataRoot(this.path, this.kind);

  final String path;
  final AnkiDataRootKind kind;

  @override
  bool operator ==(Object other) =>
      other is AnkiDataRoot && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(path, kind);

  @override
  String toString() => 'AnkiDataRoot($kind, $path)';
}

/// 按平台列出 Anki 用户数据根（去重、保序）。
///
/// [os] 取 `Platform.operatingSystem` 的值；[env] 取 `Platform.environment`。
/// - 所有桌面平台：`ANKI_BASE`（Anki 自己认的覆盖变量）优先；
/// - Windows：`%APPDATA%\Anki2`；
/// - macOS：`~/Library/Application Support/Anki2`；
/// - Linux：`$XDG_DATA_HOME/Anki2`（缺省 `~/.local/share/Anki2`），再加 Flatpak 版
///   `~/.var/app/net.ankiweb.Anki/data/Anki2`；
/// - Android：AnkiDroid 的旧默认目录 `<外部存储>/AnkiDroid`（[androidExternalRoot]，缺省
///   `/storage/emulated/0`）。AnkiDroid 2.17 起新装默认放 `Android/data/com.ichi2.anki/…`，
///   那是别的 app 的私有目录，Android 11+ 上「所有文件访问」也读不到，只能走导出 .colpkg；
/// - iOS：没有（AnkiMobile 的数据在它自己的沙盒里）。
List<AnkiDataRoot> ankiDataRoots({
  required String os,
  required Map<String, String> env,
  String androidExternalRoot = '/storage/emulated/0',
}) {
  final List<AnkiDataRoot> out = <AnkiDataRoot>[];
  void add(String? path, AnkiDataRootKind kind) {
    if (path == null || path.trim().isEmpty) return;
    final AnkiDataRoot root = AnkiDataRoot(path, kind);
    if (!out.contains(root)) out.add(root);
  }

  String? nonEmpty(String key) {
    final String? v = env[key];
    return v == null || v.trim().isEmpty ? null : v;
  }

  switch (os) {
    case 'windows':
      final p.Context w = p.Context(style: p.Style.windows);
      add(nonEmpty('ANKI_BASE'), AnkiDataRootKind.desktop);
      final String? appData = nonEmpty('APPDATA');
      if (appData != null) {
        add(w.join(appData, 'Anki2'), AnkiDataRootKind.desktop);
      }
    case 'macos':
      final p.Context x = p.Context(style: p.Style.posix);
      add(nonEmpty('ANKI_BASE'), AnkiDataRootKind.desktop);
      final String? home = nonEmpty('HOME');
      if (home != null) {
        add(
          x.join(home, 'Library', 'Application Support', 'Anki2'),
          AnkiDataRootKind.desktop,
        );
      }
    case 'linux':
      final p.Context x = p.Context(style: p.Style.posix);
      add(nonEmpty('ANKI_BASE'), AnkiDataRootKind.desktop);
      final String? home = nonEmpty('HOME');
      final String? xdg = nonEmpty('XDG_DATA_HOME');
      if (xdg != null) add(x.join(xdg, 'Anki2'), AnkiDataRootKind.desktop);
      if (home != null) {
        add(x.join(home, '.local', 'share', 'Anki2'), AnkiDataRootKind.desktop);
        add(
          x.join(home, '.var', 'app', 'net.ankiweb.Anki', 'data', 'Anki2'),
          AnkiDataRootKind.desktop,
        );
      }
    case 'android':
      add(
        p.Context(style: p.Style.posix).join(androidExternalRoot, 'AnkiDroid'),
        AnkiDataRootKind.ankiDroid,
      );
  }
  return out;
}

/// 找到的一份 Anki 集合。
class AnkiProfileCandidate {
  const AnkiProfileCandidate({
    required this.name,
    required this.directory,
    required this.kind,
    required this.collectionBytes,
    required this.walBytes,
    required this.modified,
  });

  /// 显示名：桌面是 profile 名（子目录名），AnkiDroid / 手选目录是目录名。
  final String name;

  /// 放 `collection.anki2` 的目录。
  final Directory directory;
  final AnkiDataRootKind kind;

  /// 主文件大小。
  final int collectionBytes;

  /// `-wal` 大小；> 0 表示 Anki 很可能正开着（关闭时会把 WAL 并回主文件）。
  final int walBytes;

  /// 主文件与 `-wal` 里较新的修改时刻。
  final DateTime modified;

  File get collection => File(p.join(directory.path, ankiCollectionFileName));

  Directory get mediaDir =>
      Directory(p.join(directory.path, ankiMediaFolderName));

  /// Anki 大概率正开着（有未并回的 WAL）。
  bool get probablyOpen => walBytes > 0;
}

/// 一次扫描的结果。
class AnkiDiscovery {
  const AnkiDiscovery({required this.profiles, required this.unreadableRoots});

  final List<AnkiProfileCandidate> profiles;

  /// 存在但读不了的根（例如 Android 没给「所有文件访问」）。
  final List<AnkiDataRoot> unreadableRoots;
}

/// 在 [roots] 下找集合：根本身有 `collection.anki2`（AnkiDroid / 用户直接选了 profile
/// 目录）就认根；再找根下一层含 `collection.anki2` 的子目录（桌面 Anki 的 profile）。
/// 同一目录只出现一次；不存在的根直接跳过，存在但列不了的根进 [AnkiDiscovery.unreadableRoots]。
Future<AnkiDiscovery> discoverAnkiProfiles(List<AnkiDataRoot> roots) async {
  final List<AnkiProfileCandidate> found = <AnkiProfileCandidate>[];
  final List<AnkiDataRoot> unreadable = <AnkiDataRoot>[];
  final Set<String> seen = <String>{};

  Future<void> consider(Directory dir, AnkiDataRootKind kind) async {
    final String key = p.normalize(p.absolute(dir.path));
    if (seen.contains(key)) return;
    final AnkiProfileCandidate? c = await _candidateAt(dir, kind);
    if (c == null) return;
    seen.add(key);
    found.add(c);
  }

  for (final AnkiDataRoot root in roots) {
    final Directory dir = Directory(root.path);
    if (!await dir.exists()) continue;
    try {
      await consider(dir, root.kind);
      final List<Directory> children = <Directory>[
        await for (final FileSystemEntity e in dir.list(followLinks: false))
          if (e is Directory) e,
      ]..sort((Directory a, Directory b) => a.path.compareTo(b.path));
      for (final Directory child in children) {
        await consider(child, root.kind);
      }
    } on FileSystemException {
      unreadable.add(root);
    }
  }
  return AnkiDiscovery(profiles: found, unreadableRoots: unreadable);
}

Future<AnkiProfileCandidate?> _candidateAt(
  Directory dir,
  AnkiDataRootKind kind,
) async {
  final File col = File(p.join(dir.path, ankiCollectionFileName));
  if (!await col.exists()) return null;
  final FileStat colStat = await col.stat();
  final File wal = File('${col.path}-wal');
  final FileStat? walStat = await wal.exists() ? await wal.stat() : null;
  final DateTime modified =
      walStat != null && walStat.modified.isAfter(colStat.modified)
      ? walStat.modified
      : colStat.modified;
  return AnkiProfileCandidate(
    name: p.basename(dir.path),
    directory: dir,
    kind: kind,
    collectionBytes: colStat.size,
    walBytes: walStat?.size ?? 0,
    modified: modified,
  );
}

/// 拍快照失败的原因。
enum AnkiSnapshotFailure {
  /// 集合文件不见了。
  missing,

  /// 读不了（Windows 上 Anki 正开着、集合超过 1 GB 时，SQLite 的锁字节区会挡住拷贝）。
  locked,

  /// 拷贝期间集合被写过（Anki 正在复习 / 同步）。
  changedDuringCopy,

  /// 快照不是可用的 SQLite / 完整性检查不过。
  corrupt,
}

class AnkiSnapshotException implements Exception {
  const AnkiSnapshotException(this.reason, this.message);

  final AnkiSnapshotFailure reason;
  final String message;

  @override
  String toString() => 'AnkiSnapshotException(${reason.name}): $message';
}

/// 快照里的条目数（确认页给用户看）。
class AnkiCollectionStats {
  const AnkiCollectionStats({
    required this.notes,
    required this.cards,
    required this.reviews,
    required this.decks,
    required this.noteTypes,
  });

  final int notes;
  final int cards;
  final int reviews;
  final int decks;
  final int noteTypes;
}

/// 一份集合的只读快照。用完必须 [discard]。
class AnkiCollectionSnapshot {
  AnkiCollectionSnapshot({
    required this.collection,
    required this.mediaDir,
    required this.stats,
    required Directory workDir,
    this.sourceWalBytes = 0,
  }) : _workDir = workDir;

  /// 快照里的集合（已回放 WAL、改成 DELETE 日志模式，属于快照自己）。
  final File collection;

  /// 拍快照那一刻原始集合 `-wal` 的大小（拷进来的那份）。
  final int sourceWalBytes;

  /// 拍快照时 Anki 大概率还开着。按快照时刻判，不用发现阶段的 [AnkiProfileCandidate]：
  /// 用户看到列表后再去关 Anki，候选里记的还是关之前的 WAL。
  bool get sourceProbablyOpen => sourceWalBytes > 0;

  /// 原位媒体目录（用户的，只读）。
  final Directory mediaDir;
  final AnkiCollectionStats stats;
  final Directory _workDir;

  Future<void> discard() async {
    try {
      await _workDir.delete(recursive: true);
    } on FileSystemException {
      // Windows 上 SQLite 句柄偶尔晚释放：临时目录留给系统清理。
    }
  }
}

/// 集合主文件之外需要一起拷的 SQLite 旁路文件（`-shm` 不拷：它只是 WAL 的内存索引，
/// 打开时会从 WAL 重建）。
const List<String> _sidecarSuffixes = <String>['-wal', '-journal'];

/// 现在存在的文件（主文件 `''` + 旁路后缀），按固定顺序。
Future<List<String>> _presentSuffixes(File col) async => <String>[
  for (final String suffix in <String>['', ..._sidecarSuffixes])
    if (await File('${col.path}$suffix').exists()) suffix,
];

/// 把 [suffixes] 对应的原始文件逐个 `File.copy` 到 [target] 旁。
///
/// 只用 `File.copy`（Windows 上是 CopyFileEx）读原始文件：它以共享读 / 写 / 删除打开源文件，
/// Anki 照常写、照常在关闭时删 `-wal`。自己 `open()` 原始文件读则不行——dart:io 的句柄不带
/// FILE_SHARE_DELETE，持有期间 Anki 删不掉 `-wal` / `-journal`（实测 `del` 报「另一个程序
/// 正在使用此文件」），所以第二遍读也走 `File.copy`，而不是直接对原始文件算哈希。
Future<void> _copyAll(
  File collection,
  List<String> suffixes,
  File target,
) async {
  for (final String suffix in suffixes) {
    try {
      await File('${collection.path}$suffix').copy('${target.path}$suffix');
    } on PathNotFoundException catch (e) {
      // 主文件不见了是 missing；旁路文件在两次检查之间消失 = Anki 刚 checkpoint / 关闭。
      throw AnkiSnapshotException(
        suffix.isEmpty
            ? AnkiSnapshotFailure.missing
            : AnkiSnapshotFailure.changedDuringCopy,
        '$e',
      );
    } on FileSystemException catch (e) {
      throw AnkiSnapshotException(AnkiSnapshotFailure.locked, '$e');
    }
  }
}

/// 给 [collection]（用户的 `collection.anki2`）拍一份只读快照放进 [tempParent] 下的新目录。
///
/// [mediaDir] 缺省取集合旁的 `collection.media`。
///
/// 一致性判据：整组文件（主文件 + `-wal` / `-journal`）先拷一遍作快照、再拷一遍作对照，
/// 两遍之间文件集合不变、每个文件两份副本的 SHA-256 相同，才认快照。两份相同 ⇔ 第一遍读完
/// 到第二遍开读之间没有任何改变内容的写入，且第一遍的每一段都等于那段时间里的内容——
/// 即快照恰是原始文件组在某一时刻的状态。大小 + 修改时刻做不到这点：WAL 重置后原位覆盖时
/// 大小不变，粗粒度时间戳的文件系统（FAT / exFAT / ext4 按 tick 记）上同一 tick 里的写入
/// 修改时刻也不变，而 `quick_check` 只查 B 树结构，查不出跨事务拼起来的页。
Future<AnkiCollectionSnapshot> snapshotAnkiCollection({
  required File collection,
  required Directory tempParent,
  Directory? mediaDir,
}) => _snapshot(
  collection: collection,
  tempParent: tempParent,
  mediaDir: mediaDir,
  afterFirstCopy: null,
);

/// 测试入口：与 [snapshotAnkiCollection] 相同，只是在第一遍拷完、第二遍开拷之前调
/// [afterFirstCopy]（模拟 Anki 恰在拷贝期间写入）。
@visibleForTesting
Future<AnkiCollectionSnapshot> debugSnapshotAnkiCollection({
  required File collection,
  required Directory tempParent,
  required Future<void> Function() afterFirstCopy,
}) => _snapshot(
  collection: collection,
  tempParent: tempParent,
  mediaDir: null,
  afterFirstCopy: afterFirstCopy,
);

Future<AnkiCollectionSnapshot> _snapshot({
  required File collection,
  required Directory tempParent,
  required Directory? mediaDir,
  required Future<void> Function()? afterFirstCopy,
}) async {
  if (!await collection.exists()) {
    throw AnkiSnapshotException(
      AnkiSnapshotFailure.missing,
      'no collection at ${collection.path}',
    );
  }
  final List<String> suffixes = await _presentSuffixes(collection);
  await tempParent.create(recursive: true);
  final Directory work = await tempParent.createTemp('fushi_anki_snapshot_');
  final File copy = File(p.join(work.path, ankiCollectionFileName));
  final Directory verifyDir = Directory(p.join(work.path, 'verify'));
  final File verify = File(p.join(verifyDir.path, ankiCollectionFileName));
  try {
    await _copyAll(collection, suffixes, copy);
    if (afterFirstCopy != null) await afterFirstCopy();
    await verifyDir.create();
    await _copyAll(collection, suffixes, verify);
    final List<String> suffixesAfter = await _presentSuffixes(collection);
    if (suffixesAfter.join('|') != suffixes.join('|')) {
      throw AnkiSnapshotException(
        AnkiSnapshotFailure.changedDuringCopy,
        'collection files changed while copying: $suffixes -> $suffixesAfter',
      );
    }
    // 比对两遍副本 + 回放 WAL + quick_check 在大集合上要几秒：放后台 isolate，不卡 UI 线程。
    // 哈希走 fushi_compute（每 1 MiB 一次 FFI），只读本快照自己的副本。
    final int walBytes = suffixes.contains('-wal')
        ? await File('${copy.path}-wal').length()
        : 0;
    final String copyPath = copy.path;
    final String verifyPath = verify.path;
    final AnkiCollectionStats stats = await Isolate.run(() {
      _checkCopiesIdentical(copyPath, verifyPath, suffixes);
      Directory(p.dirname(verifyPath)).deleteSync(recursive: true);
      return _settleCopy(File(copyPath));
    });
    return AnkiCollectionSnapshot(
      collection: copy,
      mediaDir:
          mediaDir ??
          Directory(p.join(collection.parent.path, ankiMediaFolderName)),
      stats: stats,
      workDir: work,
      sourceWalBytes: walBytes,
    );
  } on Object {
    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // 同上：留给系统清理。
    }
    rethrow;
  }
}

/// 两遍副本逐文件比对（先比长度，再比 SHA-256）；不同 = 拷贝期间原始集合被写过。
void _checkCopiesIdentical(String copy, String verify, List<String> suffixes) {
  for (final String suffix in suffixes) {
    final File a = File('$copy$suffix');
    final File b = File('$verify$suffix');
    if (a.lengthSync() != b.lengthSync() ||
        ffcSha256FileSync(a.path) != ffcSha256FileSync(b.path)) {
      throw AnkiSnapshotException(
        AnkiSnapshotFailure.changedDuringCopy,
        'collection${suffix.isEmpty ? '' : ' $suffix'} was modified while '
        'copying',
      );
    }
  }
}

/// 在副本上：回放 WAL / 回滚热日志 → 改成单文件 → 完整性检查 → 读条目数。
AnkiCollectionStats _settleCopy(File copy) {
  final Database db;
  try {
    db = openAnkiCollectionDb(copy.path, mode: OpenMode.readWrite);
  } on Object catch (e) {
    throw AnkiSnapshotException(AnkiSnapshotFailure.corrupt, 'sqlite: $e');
  }
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    db.execute('PRAGMA journal_mode = DELETE');
    final String check =
        '${db.select('PRAGMA quick_check').first.values.first}';
    if (check != 'ok') {
      throw AnkiSnapshotException(AnkiSnapshotFailure.corrupt, check);
    }
    int count(String sql) => db.select(sql).first.values.first! as int;
    bool hasTable(String name) => db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[name],
    ).isNotEmpty;
    for (final String table in <String>['col', 'notes', 'cards', 'revlog']) {
      if (!hasTable(table)) {
        throw AnkiSnapshotException(
          AnkiSnapshotFailure.corrupt,
          'not an Anki collection (no $table table)',
        );
      }
    }
    final bool newSchema = hasTable('notetypes');
    return AnkiCollectionStats(
      notes: count('SELECT count(*) FROM notes'),
      cards: count('SELECT count(*) FROM cards'),
      reviews: count('SELECT count(*) FROM revlog'),
      decks: newSchema ? count('SELECT count(*) FROM decks') : -1,
      noteTypes: newSchema ? count('SELECT count(*) FROM notetypes') : -1,
    );
  } on AnkiSnapshotException {
    rethrow;
  } on SqliteException catch (e) {
    throw AnkiSnapshotException(AnkiSnapshotFailure.corrupt, '$e');
  } finally {
    db.close();
  }
}

/// Anki 的平铺媒体目录（`collection.media`），只读。
class AnkiMediaFolder {
  AnkiMediaFolder(this.directory);

  final Directory directory;

  /// 目录里的文件名 → 条目名（就是文件名本身）。目录不存在时为空。
  ///
  /// 在后台 isolate 里枚举：`collection.media` 常有几万个文件，导入任务跑在 UI isolate，
  /// 同步枚举会一次卡住若干帧；结果经 `Isolate.exit` 交回，不复制。
  Future<Map<String, String>> index() {
    final String path = directory.path;
    return Isolate.run(() => _listMediaFolder(path));
  }

  static Map<String, String> _listMediaFolder(String path) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) return <String, String>{};
    final Map<String, String> out = <String, String>{};
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      out[name] = name;
    }
    return out;
  }

  /// 读一个媒体文件。名字必须是单层文件名：带路径分隔符、`.` / `..`、NUL 的一律不读
  /// （字段里的引用来自来源集合，不能让它读到媒体目录以外的文件）。
  ///
  /// 异步读（导入跑在 UI isolate，同步读大媒体会卡帧）。
  Future<Uint8List?> read(String entry) async {
    if (!isSafeAnkiMediaName(entry)) return null;
    final File f = File(p.join(directory.path, entry));
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }
}

/// [AnkiMediaFolder.read] 的名字判据。
bool isSafeAnkiMediaName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains(r'\') &&
    !name.contains('\u0000') &&
    !name.contains(':');
