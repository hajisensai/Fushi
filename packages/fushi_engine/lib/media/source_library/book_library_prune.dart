/// 书 / 漫画根的扫描对账：回收「库里还在、源文件已消失」的书与漫画卷。
///
/// 与视频根的对账（`video_library_prune.dart`）不同，书 / 漫画的行**记不住源文件**：
/// EPUB / 漫画导入会把正文拷进 `<documents>/fushi_books/<bookKey>/`，`epubPath` 只存
/// 文件名（漫画恒为 `manga.json`），所以光看 `epub_books` 判不出源文件是否被删。
///
/// 这里补一张**来源扫描索引**：每个书 / 漫画来源（`media_sources` 一行）一份
/// 「源相对路径 → 书的本机稳定身份 `uid`」映射，落 `preferences` 表的
/// `media_source_scan_index_<sourceId>` 键（与 `media_source_secret_<id>` 同一命名族，
/// 按来源 id 隐式引用）。不升 schema；键 `uid`（v81 起导入生成一次、改名不变）而不是
/// 标题派生的 `bookKey`，用户在客户端改书名不会让映射失效。
///
/// 边界（与视频对账同口径）：
/// - 只动**该来源**的书：行的 `sourceId` 必须等于该来源、且被索引认领过；手动导入 /
///   客户端上传 / 别的库根里的书一概不碰。
/// - **不删任何用户源文件**；只回收库里的行（`deleteEpubBook` 全量级联）与导入时拷进
///   `fushi_books/` 的正文副本。
/// - **不写跨设备删除墓碑 / 备份墓碑**（`tombstone: false`）：「本机源文件没了」是本地
///   事实，不代表用户要让对端或旧备份里的这本书也消失；源文件放回来，下次扫描照常再导入。
/// - 护栏与视频根共用（`library_prune_guard.dart`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi_engine/media/source_library/library_prune_guard.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

/// 来源扫描索引的偏好键前缀（后缀 = `MediaSources.id`）。
const String kBookSourceScanIndexPrefKeyPrefix = 'media_source_scan_index_';

/// 来源 [sourceId] 的扫描索引偏好键。
String bookSourceScanIndexPrefKey(int sourceId) =>
    '$kBookSourceScanIndexPrefKeyPrefix$sourceId';

/// [entryPath] 相对库根 [rootPath] 的索引键：正斜杠分隔、已归一。库根本身（漫画根目录
/// 直接放页图时整根是一卷）为 `.`。
String bookSourceRelPath(String rootPath, String entryPath) => p
    .relative(p.normalize(entryPath), from: p.normalize(rootPath))
    .replaceAll(r'\', '/');

/// 索引键 [rel] 在库根 [rootPath] 下的绝对路径。
String bookSourceAbsPath(String rootPath, String rel) =>
    p.normalize(p.join(rootPath, rel));

/// 一个书 / 漫画来源的扫描索引：源相对路径 → 书 `uid`。
///
/// 多个源可以指向同一本书（同名书在两个子目录各放一份，第二份导入时判重复、被认领到
/// 同一行）：只要还有一个源在，这本书就不算失效。
class BookSourceIndex {
  BookSourceIndex._(this.sourceId, this._uidByRel);

  /// 空索引（测试 / 来源还没扫过）。
  factory BookSourceIndex.empty(int sourceId) =>
      BookSourceIndex._(sourceId, <String, String>{});

  final int sourceId;
  final Map<String, String> _uidByRel;

  /// 读来源 [sourceId] 的索引；没有或损坏时返回空索引（损坏 = 当作没认领过，
  /// 只会少删、不会误删）。
  static Future<BookSourceIndex> load(FushiDatabase db, int sourceId) async {
    final String? raw = await db.getPref(bookSourceScanIndexPrefKey(sourceId));
    final Map<String, String> entries = <String, String>{};
    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(PrefCodec.decode<String>(raw, ''));
        final Object? map = decoded is Map<String, dynamic>
            ? decoded['entries']
            : null;
        if (map is Map<String, dynamic>) {
          map.forEach((String rel, Object? uid) {
            if (uid is String && uid.isNotEmpty) entries[rel] = uid;
          });
        }
      } on FormatException {
        // 损坏的索引按空处理。
      }
    }
    return BookSourceIndex._(sourceId, entries);
  }

  /// 落库（空索引直接删键）。
  Future<void> save(FushiDatabase db) async {
    final String key = bookSourceScanIndexPrefKey(sourceId);
    if (_uidByRel.isEmpty) {
      await db.deletePref(key);
      return;
    }
    await db.setPref(
      key,
      PrefCodec.encode(
        jsonEncode(<String, Object?>{'v': 1, 'entries': _uidByRel}),
      ),
    );
  }

  /// 删掉来源 [sourceId] 的索引（库根移除时用）。
  static Future<void> clear(FushiDatabase db, int sourceId) =>
      db.deletePref(bookSourceScanIndexPrefKey(sourceId));

  Map<String, String> get entries =>
      Map<String, String>.unmodifiable(_uidByRel);

  /// 被认领过的书 uid 集合。
  Set<String> get uids => _uidByRel.values.toSet();

  bool get isEmpty => _uidByRel.isEmpty;

  String? uidOf(String rel) => _uidByRel[rel];

  void put(String rel, String uid) => _uidByRel[rel] = uid;

  void remove(String rel) => _uidByRel.remove(rel);

  /// 源 [uid] 被哪些相对路径认领。
  List<String> relsOf(String uid) => <String>[
    for (final MapEntry<String, String> e in _uidByRel.entries)
      if (e.value == uid) e.key,
  ];

  /// 丢掉指向已不在库的书的条目（用户在客户端删了书等），返回丢掉的条数。
  int retainUids(Set<String> liveUids) {
    final int before = _uidByRel.length;
    _uidByRel.removeWhere((String _, String uid) => !liveUids.contains(uid));
    return before - _uidByRel.length;
  }
}

/// 对账要用的书行瘦投影（不拉章节 JSON）。
class BookSourceRow {
  const BookSourceRow({
    required this.bookKey,
    required this.uid,
    required this.title,
    required this.format,
    required this.epubPath,
    required this.extractDir,
    required this.sourceId,
  });

  final String bookKey;
  final String uid;
  final String title;
  final String format;
  final String epubPath;
  final String extractDir;
  final int? sourceId;
}

/// 读全部书行的瘦投影。
Future<List<BookSourceRow>> loadBookSourceRows(FushiDatabase db) async {
  final $EpubBooksTable t = db.epubBooks;
  final List<TypedResult> rows =
      await (db.selectOnly(t)..addColumns(<Expression<Object>>[
            t.bookKey,
            t.uid,
            t.title,
            t.format,
            t.epubPath,
            t.extractDir,
            t.sourceId,
          ]))
          .get();
  return <BookSourceRow>[
    for (final TypedResult r in rows)
      BookSourceRow(
        bookKey: r.read(t.bookKey)!,
        uid: r.read(t.uid) ?? '',
        title: r.read(t.title)!,
        format: r.read(t.format) ?? BookFormat.epub.dbValue,
        epubPath: r.read(t.epubPath) ?? '',
        extractDir: r.read(t.extractDir) ?? '',
        sourceId: r.read(t.sourceId),
      ),
  ];
}

/// 书行 [bookKey] 的 uid；不在库或 uid 为空返回 null。
Future<String?> bookUidForKey(FushiDatabase db, String bookKey) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null || row.uid.isEmpty) return null;
  return row.uid;
}

/// 扫描时一个源被导入器判「同名书已在库」（`DuplicateImportCancelledException`）后，
/// 决定它能不能**认领**那本已在库的书，能就返回该书 uid（并把无来源的行归到本来源），
/// 不能返回 null。
///
/// 这是存量行回填的唯一入口：旧版服务端扫描进来的书既没 `sourceId` 也没索引，
/// 只能靠「同一个源再扫一次时撞上的同名行」把关系补回来。判据刻意保守：
/// - 标题身份（`sanitizeTtuFilename`）相同、书身份格式相同；
/// - 行的 `sourceId` 为空或已是本来源（属于别的库根的书绝不抢）；
/// - EPUB 还要求 `epubPath`（导入时记的源文件名）等于这个源的文件名——旧扫描器就是
///   这么写的，客户端上传的同名书文件名多半不同；漫画的 `epubPath` 恒为 `manga.json`，
///   只能按标题 + 格式认（同名漫画卷视为同一卷）。
///
/// 认领不上的（标题被手动导入 / 别的库根的书占着）保持原样：它不进本来源的索引，
/// 也就永远不会被本来源的对账删掉。
Future<String?> adoptExistingBookForSource({
  required FushiDatabase db,
  required int sourceId,
  required String proposedTitle,
  required BookFormat format,
  String? sourceFileName,
}) async {
  final EpubBookRow? row = await db.getEpubBook(
    sanitizeTtuFilename(proposedTitle),
  );
  if (row == null || row.uid.isEmpty) return null;
  if (row.format != format.dbValue) return null;
  if (row.sourceId != null && row.sourceId != sourceId) return null;
  if (format != BookFormat.manga &&
      (sourceFileName == null || row.epubPath != sourceFileName)) {
    return null;
  }
  if (row.sourceId == null) {
    await (db.update(db.epubBooks)
          ..where(($EpubBooksTable t) => t.bookKey.equals(row.bookKey)))
        .write(EpubBooksCompanion(sourceId: Value<int?>(sourceId)));
  }
  return row.uid;
}

/// 书根：[root] 下全部 `.epub`（递归、不跟链接、按路径排序）。
Future<List<String>> listEpubSourceFiles(Directory root) async {
  final List<String> out = <String>[];
  await for (final FileSystemEntity e in root.list(
    recursive: true,
    followLinks: false,
  )) {
    if (e is File && p.extension(e.path).toLowerCase() == '.epub') {
      out.add(e.path);
    }
  }
  out.sort();
  return out;
}

/// 枚举 [root] 下现存的书 / 漫画源（索引键形态，见 [bookSourceRelPath]）：书根是
/// `.epub` 文件，漫画根是引擎归组出的 `.mokuro` 卷与纯页图卷目录——与扫描器导入的
/// 口径逐一对应。
Future<Set<String>> enumerateBookSourceRelPaths(
  Directory root, {
  required SourceLibraryKind kind,
}) async {
  final List<String> paths;
  switch (kind) {
    case SourceLibraryKind.book:
      paths = await listEpubSourceFiles(root);
    case SourceLibraryKind.manga:
      final MangaFolderPlan plan = planMangaFoldersInDirectory(root);
      paths = <String>[...plan.mokuroPaths, ...plan.imageFolders];
    case SourceLibraryKind.video:
      throw ArgumentError.value(kind, 'kind', 'video roots use video prune');
  }
  return <String>{
    for (final String path in paths) bookSourceRelPath(root.path, path),
  };
}

/// 回收一本**已删行**的书导入时拷进 `fushi_books/` 的正文副本；不碰源文件。
///
/// 书目录只在确实位于书库根（[EpubStorage.baseDirectory]）之内时才删——PDF 等把
/// `extractDir` 写成占位 / 外部路径的行绝不会因此删到库外的东西。
Future<void> reclaimBookAssets(BookSourceRow row) async {
  if (row.extractDir.isEmpty) return;
  final String base = await EpubStorage.baseDirectory();
  if (p.isWithin(base, row.extractDir)) {
    await EpubStorage.deleteBookDir(row.extractDir);
  }
}

bool _entryExists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// 对一个书 / 漫画来源做一次对账：挑出「认领它的源全都不在了」的书并回收。
///
/// [index] 不给就从库里读；对账后（非 dryRun、未被拦下）写回：删掉已回收的书的条目、
/// 以及「源已不在但书还被别的源认领着」的死条目。[foundRelPaths] 不给就自行枚举
/// （[enumerateBookSourceRelPaths]）。[baselineBookUids] 与视频对账同义：只在本轮
/// 扫描导入前就被认领的书上判失效与算护栏比例。
///
/// 护栏（[force] 全部越过，只留「源确实不存在」）：库根不存在 / 一个源都枚举不到 →
/// 拒绝；失效源所在子树疑似脱挂 → 该书不判失效；失效占比越过 [threshold] → 拒绝。
Future<LibraryPruneReport> pruneMissingBookRows({
  required FushiDatabase db,
  required int sourceId,
  required Directory root,
  required SourceLibraryKind kind,
  BookSourceIndex? index,
  Set<String>? foundRelPaths,
  Set<String>? baselineBookUids,
  LibraryPruneThreshold threshold = const LibraryPruneThreshold(),
  bool force = false,
  bool dryRun = false,
  bool Function(String path)? exists,
}) async {
  final bool Function(String path) sourceExists = exists ?? _entryExists;
  final BookSourceIndex idx = index ?? await BookSourceIndex.load(db, sourceId);
  final List<BookSourceRow> rows = await loadBookSourceRows(db);
  final int droppedDead = idx.retainUids(<String>{
    for (final BookSourceRow r in rows)
      if (r.uid.isNotEmpty) r.uid,
  });
  final Set<String> claimed = idx.uids;
  final List<BookSourceRow> candidates = <BookSourceRow>[
    for (final BookSourceRow r in rows)
      if (r.uid.isNotEmpty &&
          r.sourceId == sourceId &&
          claimed.contains(r.uid) &&
          (baselineBookUids == null || baselineBookUids.contains(r.uid)))
        r,
  ];
  Future<void> persistIfChanged() async {
    if (droppedDead > 0 && !dryRun) await idx.save(db);
  }

  if (candidates.isEmpty) {
    await persistIfChanged();
    return const LibraryPruneReport(considered: 0, missing: 0, deleted: 0);
  }
  final bool rootExists = await root.exists();
  final Set<String> found =
      foundRelPaths ??
      (rootExists
          ? await enumerateBookSourceRelPaths(root, kind: kind)
          : <String>{});
  final String? rootSkip = force
      ? null
      : libraryRootSkipReason(
          rootPath: root.path,
          rootExists: rootExists,
          foundAny: found.isNotEmpty,
          mediaNoun: kind == SourceLibraryKind.manga
              ? 'manga volumes'
              : 'book files',
        );
  if (rootSkip != null) {
    await persistIfChanged();
    return LibraryPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      skipped: true,
      skipReason: rootSkip,
    );
  }

  bool relGone(String rel) =>
      !found.contains(rel) && !sourceExists(bookSourceAbsPath(root.path, rel));
  final List<BookSourceRow> stale = <BookSourceRow>[];
  final List<String> deadRels = <String>[];
  int unreachable = 0;
  for (final BookSourceRow row in candidates) {
    final List<String> rels = idx.relsOf(row.uid);
    final List<String> gone = <String>[
      for (final String rel in rels)
        if (relGone(rel)) rel,
    ];
    if (gone.length < rels.length) {
      // 还有源在：这本书不失效，但已消失的源条目是死条目，顺手清掉。
      for (final String rel in gone) {
        if (force ||
            !isPathInDetachedSubtree(
              bookSourceAbsPath(root.path, rel),
              root.path,
            )) {
          deadRels.add(rel);
        }
      }
      continue;
    }
    final bool detached =
        !force &&
        gone.any(
          (String rel) => isPathInDetachedSubtree(
            bookSourceAbsPath(root.path, rel),
            root.path,
          ),
        );
    if (detached) {
      unreachable++;
    } else {
      stale.add(row);
    }
  }

  Future<void> saveCleaned(Iterable<String> deletedUids) async {
    if (dryRun) return;
    final Set<String> deleted = deletedUids.toSet();
    for (final String rel in deadRels) {
      idx.remove(rel);
    }
    for (final String uid in deleted) {
      for (final String rel in idx.relsOf(uid)) {
        idx.remove(rel);
      }
    }
    if (droppedDead > 0 || deadRels.isNotEmpty || deleted.isNotEmpty) {
      await idx.save(db);
    }
  }

  if (stale.isEmpty) {
    await saveCleaned(const <String>[]);
    return LibraryPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      unreachable: unreachable,
    );
  }
  final String? thresholdSkip = force
      ? null
      : threshold.skipReason(
          stale: stale.length,
          considered: candidates.length,
        );
  if (thresholdSkip != null) {
    await persistIfChanged();
    return LibraryPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
      skipped: true,
      skipReason: thresholdSkip,
    );
  }
  if (dryRun) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
    );
  }
  final List<String> errors = <String>[];
  final List<String> deletedUids = <String>[];
  for (final BookSourceRow row in stale) {
    try {
      await db.deleteEpubBook(row.bookKey);
    } catch (e) {
      // 部分成功：已删的照实计数，失败的书留在库里、索引条目也留着，下轮再判。
      errors.add('${row.bookKey}: $e');
      continue;
    }
    deletedUids.add(row.uid);
    try {
      await reclaimBookAssets(row);
    } catch (e) {
      // 行已删、正文副本没删掉：计入已删，副本残留如实报错。
      errors.add('${row.bookKey}: reclaim ${row.extractDir}: $e');
    }
  }
  await saveCleaned(deletedUids);
  return LibraryPruneReport(
    considered: candidates.length,
    missing: stale.length,
    deleted: deletedUids.length,
    unreachable: unreachable,
    errors: errors,
  );
}
