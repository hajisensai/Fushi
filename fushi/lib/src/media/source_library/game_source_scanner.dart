/// 游戏来源（`SourceLibraryKind.game`，反馈 9Rm_8JEkGM）：把一个本地扫描根下的
/// 游戏目录登记进游戏库（`galgames`）。
///
/// **游戏目录**：来源根之下、自上而下第一层**直接**含有游戏入口候选（[isGameExePath]，
/// 与「添加游戏」同一判据）的目录。找到即认作一个游戏、不再往下走——游戏自带的
/// `tools/`、`plugin/` 里的 exe 属于这个游戏，不另成一条；也省掉把整个游戏资源树
/// 列一遍（游戏目录动辄上万个资源文件）。来源根自己就直接含 exe 时，整个根是一个
/// 游戏（用户把单个游戏文件夹登记成来源）。来源行的「含子文件夹」关闭时只看根与根
/// 的直接子目录。
///
/// **增量**：来源 ↔ 游戏的归属记在来源扫描索引（[BookSourceIndex]，`preferences` 表
/// `media_source_scan_index_<sourceId>`，与书 / 漫画来源同一个键族、同一份格式，不升
/// schema）：游戏目录相对来源根的路径 → `galgames.id`。重扫时：
/// - 已认领且游戏还在库里的目录：什么都不做（用户在详情页改过的 exe / 名称 / 启动
///   参数不会被重扫改回去）；
/// - 没认领、但库里已有 exe 落在这个目录里的游戏（之前手动添加过）：认领那一条，不
///   重复添加；
/// - 其余：选主 exe（[pickGameDirectoryExe]）新建一条，名称取目录名。
///
/// **目录被删 / 来源被移除**：与 app 内书 / 视频来源同口径——app 内扫描不回收库条目
/// （回收只在服务端「移除并清理」里做），游戏连同游玩记录、刮削资料都留在库里；移除
/// 来源只清掉这份索引（`removeSourceLibrary`）。游戏被用户从库里删掉后，该目录的
/// 认领随之失效，下次重扫会再登记（与书来源重扫重新导入同一语义）。
///
/// 只收**本地**来源：exe 要在本机拉起，网络来源扫出来也启动不了。
///
/// 不进 Rust 胖核心：这里没有计算——只有按层列目录与少量 stat（每个多 exe 的游戏
/// 目录 stat 一次各 exe），与既有 Dart 来源扫描框架（`SourceLibraryScanner`）同一层。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';

/// 游戏来源扫描完一次后的装配点（AppModel 接到游戏库仓储：重载缓存 + 后台补封面）。
/// 参数是本轮**新建**的 `galgames.id`。与 `onMusicSourceScanned` 同一形态：扫描器只
/// 拿得到数据库，游戏库仓储（ChangeNotifier 缓存）由 app 装配层持有。
void Function(List<String> createdGameIds)? onGameSourceScanned;

/// 来源根下识别出的一个游戏目录。
class GameDirectoryCandidate {
  const GameDirectoryCandidate({
    required this.directoryPath,
    required this.exePaths,
  });

  /// 游戏目录的绝对路径。
  final String directoryPath;

  /// 该目录**直接**含有的 exe（路径 → 字节数；只有一个 exe 或 stat 失败时为 null）。
  final Map<String, int?> exePaths;
}

/// 列出来源根 [rootPath] 下的游戏目录（见库注释的「游戏目录」定义）。
///
/// [recursive] 为 false 时只看根与根的直接子目录。列不出的子目录（权限 / IO 错误）
/// 跳过，只有根本身不存在 / 列不出时才抛（整次扫描读不了，由调用方记进来源行）。
/// 按路径排序，结果确定。
Future<List<GameDirectoryCandidate>> findGameDirectories(
  String rootPath, {
  bool recursive = true,
}) async {
  final Directory root = Directory(rootPath);
  if (!await root.exists()) {
    throw FileSystemException('Game source root does not exist', rootPath);
  }
  final List<GameDirectoryCandidate> found = <GameDirectoryCandidate>[];
  // 广度优先（按层），depth 0 = 来源根。
  List<String> level = <String>[root.path];
  int depth = 0;
  while (level.isNotEmpty) {
    final List<String> next = <String>[];
    for (final String dir in level) {
      final List<String> exes = <String>[];
      final List<String> subdirs = <String>[];
      try {
        await for (final FileSystemEntity e in Directory(
          dir,
        ).list(followLinks: false)) {
          if (e is File && isGameExePath(e.path)) {
            exes.add(e.path);
          } else if (e is Directory) {
            subdirs.add(e.path);
          }
        }
      } on FileSystemException {
        if (depth == 0) rethrow;
        continue;
      }
      if (exes.isNotEmpty) {
        final Map<String, int?> sized = <String, int?>{};
        for (final String exe in exes) {
          sized[exe] = exes.length == 1 ? null : await _sizeOf(exe);
        }
        found.add(GameDirectoryCandidate(directoryPath: dir, exePaths: sized));
        continue; // 游戏目录的子树属于这个游戏，不再往下找。
      }
      if (recursive || depth == 0) next.addAll(subdirs);
    }
    level = next;
    depth++;
  }
  found.sort(
    (GameDirectoryCandidate a, GameDirectoryCandidate b) =>
        a.directoryPath.compareTo(b.directoryPath),
  );
  return found;
}

Future<int?> _sizeOf(String path) async {
  try {
    return await File(path).length();
  } on FileSystemException {
    return null;
  }
}

/// 一次游戏来源扫描的结果。
class GameSourceScanResult {
  const GameSourceScanResult({
    required this.discoveredDirectories,
    required this.createdGameIds,
    required this.adoptedGameIds,
  });

  /// 本轮识别出的游戏目录（绝对路径）。
  final List<String> discoveredDirectories;

  /// 本轮新建的 `galgames.id`。
  final List<String> createdGameIds;

  /// 本轮认领的、之前已在库里的游戏（手动添加过的）。
  final List<String> adoptedGameIds;
}

/// 扫描游戏来源 [sourceId]（根 [rootPath]）：识别游戏目录，按库注释的增量规则登记
/// 进 `galgames`，并回写来源扫描索引。不调 [onGameSourceScanned]（由
/// `SourceLibraryScanner` 在写完来源行后调）。
///
/// [now] 只给测试钉新游戏的添加时刻 / id 用。
Future<GameSourceScanResult> scanGameSource({
  required FushiDatabase db,
  required int sourceId,
  required String rootPath,
  bool recursive = true,
  DateTime? now,
}) async {
  final List<GameDirectoryCandidate> dirs = await findGameDirectories(
    rootPath,
    recursive: recursive,
  );
  final BookSourceIndex index = await BookSourceIndex.load(db, sourceId);
  final List<GalgameRow> rows = await db.getAllGalgames();
  final Set<String> liveIds = <String>{for (final GalgameRow r in rows) r.id};
  // 用户从库里删掉的游戏：认领作废（下次重扫再登记，见库注释）。
  index.retainUids(liveIds);

  final List<String> created = <String>[];
  final List<String> adopted = <String>[];
  final DateTime base = now ?? DateTime.now();
  int seq = 0;
  for (final GameDirectoryCandidate dir in dirs) {
    final String rel = bookSourceRelPath(rootPath, dir.directoryPath);
    final String? claimed = index.uidOf(rel);
    if (claimed != null && liveIds.contains(claimed)) continue;

    final GalgameRow? existing = _gameInsideDirectory(
      rows,
      dir.directoryPath,
      exclude: index.uids,
    );
    if (existing != null) {
      index.put(rel, existing.id);
      adopted.add(existing.id);
      continue;
    }

    final String dirName = p.basename(dir.directoryPath);
    final String? exe = pickGameDirectoryExe(dirName, dir.exePaths);
    if (exe == null) continue;
    final bool isRoot = p.equals(dir.directoryPath, rootPath);
    // id 沿用「添加时刻微秒」口径（与「添加游戏」同一个构造函数）；批内按序号错开，
    // 并跳过库里已有的 id —— upsert 撞上已有 id 会覆盖掉那个游戏。
    GalgameEntry entry;
    do {
      entry = newGalgameEntryFromExe(
        exe,
        now: base.add(Duration(microseconds: seq++)),
        // 来源根自己就是游戏目录时沿用 exe 名（与「添加游戏」一致）；其余取目录名
        // （`ATRI/game.exe` → 「ATRI」，而不是「game」）。
        name: isRoot ? null : dirName,
      );
    } while (liveIds.contains(entry.id));
    await db.upsertGalgame(galgamesCompanionFromEntry(entry));
    liveIds.add(entry.id);
    index.put(rel, entry.id);
    created.add(entry.id);
  }
  await index.save(db);
  return GameSourceScanResult(
    discoveredDirectories: <String>[
      for (final GameDirectoryCandidate d in dirs) d.directoryPath,
    ],
    createdGameIds: created,
    adoptedGameIds: adopted,
  );
}

/// 库里 exe 落在 [directory]（含子目录）里、且没被本来源别的目录认领（[exclude]）的
/// 第一个游戏。路径比较走 Windows 语义（大小写无关、`/` ≡ `\`），与 exe 去重同口径。
GalgameRow? _gameInsideDirectory(
  List<GalgameRow> rows,
  String directory, {
  required Set<String> exclude,
}) {
  final p.Context windows = p.Context(style: p.Style.windows);
  final String dirKey = windows.normalize(directory).toLowerCase();
  for (final GalgameRow row in rows) {
    if (exclude.contains(row.id) || row.exePath.trim().isEmpty) continue;
    final String exeKey = windows.normalize(row.exePath).toLowerCase();
    if (windows.isWithin(dirKey, exeKey)) return row;
  }
  return null;
}

/// 游戏来源 [sourceId] 当前**累计拥有**的游戏数（来源页每行的计数）：索引里认领、
/// 且仍在库里的游戏。
Future<int> countGamesOfSource(FushiDatabase db, int sourceId) async {
  final BookSourceIndex index = await BookSourceIndex.load(db, sourceId);
  if (index.isEmpty) return 0;
  final Set<String> liveIds = <String>{
    for (final GalgameRow r in await db.getAllGalgames()) r.id,
  };
  return index.uids.where(liveIds.contains).length;
}

/// 移除游戏来源 [sourceId] 时清掉它的扫描索引（游戏本身留在库里，见库注释）。
Future<void> clearGameSourceIndex(FushiDatabase db, int sourceId) =>
    BookSourceIndex.clear(db, sourceId);
