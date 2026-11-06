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
/// 多个源可以指向同一本书（源文件挪了位置、旧路径的条目还没被对账清掉时，新路径
/// 认领到同一行）：只要还有一个源在，这本书就不算失效。同一来源下**仍然在场**的
/// 两个不同文件不会共用一本书——第二个是另一卷，换名另导（见 [isDuplicateSourceBook]）。
///
/// 另记一张**负向结果表**（[isRejected] / [reject]）：扩展名对得上、开包后判定
/// 「不是这一类媒体」的源（漫画来源里的词典 `.zip`、文字 `.epub`）→ 当时的内容指纹。
/// 指纹没变就不再开包 / 下载重判，变了（文件被换掉）才重判。同一个偏好键、同一份
/// JSON，不升 schema。
class BookSourceIndex {
  BookSourceIndex._(this.sourceId, this._uidByRel, this._rejectedByRel);

  /// 空索引（测试 / 来源还没扫过）。
  factory BookSourceIndex.empty(int sourceId) =>
      BookSourceIndex._(sourceId, <String, String>{}, <String, String>{});

  final int sourceId;
  final Map<String, String> _uidByRel;

  /// 源相对路径 → 判定「不是本类媒体」时的内容指纹（见 [sourceContentFingerprint]）。
  final Map<String, String> _rejectedByRel;

  /// 读来源 [sourceId] 的索引；没有或损坏时返回空索引（损坏 = 当作没认领过，
  /// 只会少删、不会误删）。
  static Future<BookSourceIndex> load(FushiDatabase db, int sourceId) async {
    final String? raw = await db.getPref(bookSourceScanIndexPrefKey(sourceId));
    final Map<String, String> entries = <String, String>{};
    final Map<String, String> rejected = <String, String>{};
    void readMap(Object? map, Map<String, String> into) {
      if (map is! Map<String, dynamic>) return;
      map.forEach((String rel, Object? value) {
        if (value is String && value.isNotEmpty) into[rel] = value;
      });
    }

    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(PrefCodec.decode<String>(raw, ''));
        if (decoded is Map<String, dynamic>) {
          readMap(decoded['entries'], entries);
          // 旧版（只有 entries）读出来就是空负向表：最多多判一次，不会误跳。
          readMap(decoded['rejected'], rejected);
        }
      } on FormatException {
        // 损坏的索引按空处理。
      }
    }
    return BookSourceIndex._(sourceId, entries, rejected);
  }

  /// 落库（认领与负向表都空时直接删键）。
  Future<void> save(FushiDatabase db) async {
    final String key = bookSourceScanIndexPrefKey(sourceId);
    if (_uidByRel.isEmpty && _rejectedByRel.isEmpty) {
      await db.deletePref(key);
      return;
    }
    await db.setPref(
      key,
      PrefCodec.encode(
        jsonEncode(<String, Object?>{
          'v': 1,
          'entries': _uidByRel,
          if (_rejectedByRel.isNotEmpty) 'rejected': _rejectedByRel,
        }),
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

  /// [rel] 上次被判「不是本类媒体」、且内容指纹仍是 [fingerprint]。指纹为 null
  /// （传输给不出大小 / 时间 / ETag）时一律不算命中——宁可重判，不凭空跳过。
  bool isRejected(String rel, String? fingerprint) =>
      fingerprint != null && _rejectedByRel[rel] == fingerprint;

  /// 记下 [rel] 在内容指纹 [fingerprint] 下不是本类媒体；指纹为 null 不记。
  void reject(String rel, String? fingerprint) {
    if (fingerprint == null) return;
    _rejectedByRel[rel] = fingerprint;
  }

  /// 负向表快照（测试 / 诊断用）。
  Map<String, String> get rejected =>
      Map<String, String>.unmodifiable(_rejectedByRel);

  /// 只留下本轮仍在场的源的负向结果（文件删了 / 改名了，旧判定随之作废）。
  void retainRejected(Set<String> presentRels) => _rejectedByRel.removeWhere(
    (String rel, String _) => !presentRels.contains(rel),
  );
}

/// 一个源文件的内容指纹：ETag 优先，否则「字节数 + 修改时刻」能拿到几样拼几样；
/// 一样都没有返回 null（调用方因此不缓存负向结果）。
///
/// 只拿传输**列目录时顺带给出**的元数据，不为算指纹多发请求 / 多读内容。
String? sourceContentFingerprint({
  int? sizeBytes,
  int? modifiedAt,
  String? etag,
}) {
  final String? tag = etag?.trim();
  if (tag != null && tag.isNotEmpty) return 'e:$tag';
  if (sizeBytes == null && modifiedAt == null) return null;
  return 's:${sizeBytes ?? '-'}|m:${modifiedAt ?? '-'}';
}

/// 本地文件 [path] 的内容指纹（字节数 + 修改时刻微秒）；stat 失败返回 null。
String? localSourceContentFingerprint(String path) {
  try {
    final FileStat stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return sourceContentFingerprint(
      sizeBytes: stat.size,
      modifiedAt: stat.modified.microsecondsSinceEpoch,
    );
  } catch (_) {
    return null;
  }
}

/// 来源扫描撞上同名书时，这个源与那本书的关系（[isDuplicateSourceBook] 的结论）。
enum SourceDuplicateKind {
  /// 标题没被占：不是重复，照常导入。
  none,

  /// 就是这个源早先导进来的那本（存量行回填 / 源文件挪了位置）：认领它，不再导入。
  sameSource,

  /// 同一来源下**另一个仍在场的文件**已经认领了这本书：两份是不同的卷 / 书，只是
  /// 标题撞了（`系列A/Vol 1.cbz` 与 `系列B/Vol 1.cbz`、`Vol 1.cbz` 与 `Vol 1.pdf`）。
  /// 不是重复，换名另导（`DuplicatePolicy.suffix()`）。
  otherSourceFile,

  /// 标题被别的库根 / 手动导入 / 不同格式的书占着：按重复处理，不导入、不认领。
  foreign,
}

/// [isDuplicateSourceBook] 的结论：[kind] + 撞上的那本书的 uid（[SourceDuplicateKind.none]
/// 时为 null）。
class SourceDuplicateVerdict {
  const SourceDuplicateVerdict(this.kind, {this.uid});

  final SourceDuplicateKind kind;
  final String? uid;

  /// 是否按重复处理（不再导入这个源）。
  bool get isDuplicate =>
      kind == SourceDuplicateKind.sameSource ||
      kind == SourceDuplicateKind.foreign;
}

/// 来源扫描的**重复判据**：来源 [sourceId] 里相对路径为 [rel] 的源，标题身份
/// （`sanitizeTtuFilename(proposedTitle)`）若已被一本书占着，它是不是那本书。
///
/// 只读，不写库；认领（回填 `sourceId`）交给 [adoptExistingBookForSource]。
///
/// 重复身份 = 标题 **+ 来源路径**：同一来源里另一个本轮仍在场的源（[presentRels]）
/// 已认领了那本书时，这个源是另一卷，不是重复——此前只看标题，`系列A/Vol 1.cbz`
/// 导入后 `系列B/Vol 1.cbz`（或同目录的 `Vol 1.pdf`）被静默跳过，永远进不了库。
///
/// 认领判据仍保守（与 [adoptExistingBookForSource] 一致）：书身份格式相同、行的
/// `sourceId` 为空或就是本来源；EPUB 还要源文件名一致。本来源的行源文件名对不上时，
/// 那是本来源里另一个文件导进来的书（[SourceDuplicateKind.otherSourceFile]）。
///
/// [claimUnsourcedRows]：无来源（`sourceId` 为空）的同名行能不能被认领。无头服务端
/// 要它（旧版服务端扫描进来的书没记来源，只能这样回填）；app 的来源扫描从一开始就
/// 写 `sourceId`，无来源的行是**手动导入**的书，不该被某个来源抢走，传 false。
Future<SourceDuplicateVerdict> isDuplicateSourceBook({
  required FushiDatabase db,
  required BookSourceIndex index,
  required int sourceId,
  required String rel,
  required String proposedTitle,
  required BookFormat format,
  required Set<String> presentRels,
  String? sourceFileName,
  bool claimUnsourcedRows = true,
}) async {
  final EpubBookRow? row = await db.getEpubBook(
    sanitizeTtuFilename(proposedTitle),
  );
  if (row == null || row.uid.isEmpty) {
    return const SourceDuplicateVerdict(SourceDuplicateKind.none);
  }
  final String uid = row.uid;
  final bool claimedByOtherPresentSource = index
      .relsOf(uid)
      .any((String other) => other != rel && presentRels.contains(other));
  if (claimedByOtherPresentSource) {
    return SourceDuplicateVerdict(
      SourceDuplicateKind.otherSourceFile,
      uid: uid,
    );
  }
  if (row.format != format.dbValue ||
      (row.sourceId == null && !claimUnsourcedRows) ||
      (row.sourceId != null && row.sourceId != sourceId)) {
    return SourceDuplicateVerdict(SourceDuplicateKind.foreign, uid: uid);
  }
  if (format != BookFormat.manga &&
      (sourceFileName == null || row.epubPath != sourceFileName)) {
    return SourceDuplicateVerdict(
      row.sourceId == sourceId
          ? SourceDuplicateKind.otherSourceFile
          : SourceDuplicateKind.foreign,
      uid: uid,
    );
  }
  return SourceDuplicateVerdict(SourceDuplicateKind.sameSource, uid: uid);
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

/// 「系列目录/卷目录」被拆成分卷后，旧版扫描把整个系列目录导成的那本「合订本」。
typedef FlattenedMangaSeries = ({
  /// 系列目录的索引键（旧版把它当一卷登记的就是这个键）。
  String seriesRel,

  /// 系列目录 basename：旧版就用它当书名（索引里没有这条时按它认）。
  String seriesTitle,

  /// 本轮拆出的各卷目录的索引键。
  List<String> volumeRels,
});

/// 把旧版扫描导成一整本的系列目录让位给拆出的分卷（BUG：
/// manga-series-volume-folders-flattened）。返回被回收的书 uid 与逐条错误。
///
/// 旧规则把 `库根/系列/卷N/页图` 的整个 `系列` 目录导成一本（~2000 页）。新规则拆成
/// 分卷后，这本书的源（`系列` 目录）**仍然存在**，所以对账（[pruneMissingBookRows]
/// 的 `relGone` 还会现场看目录在不在）永远不会回收它——不处理的话重扫后书架上是
/// 「合订本 + 各分卷」重复一份。这里在本轮分卷都已入库后回收它：
/// - 先决条件：该系列**每一卷**都已被索引认领（本轮导入成功，或早已在库）。有一卷
///   失败 / 因同名书被跳过，就保留合订本，内容不会凭空少一块；
/// - 只认本来源导入的那一行：索引里 `seriesRel` 指向的书；索引里没有（升级前的
///   扫描没写索引）时退到「`sourceId` = 本来源、格式漫画、bookKey = 系列目录名」，
///   正是旧扫描器的落库方式。手动导入 / 别的来源的同名书不碰；
/// - 那本书还被本来源别的源认领着就只撤掉 `seriesRel` 这条，不删书；
/// - 回收方式与对账删失效书相同：`deleteEpubBook`（不写墓碑）+ 回收 `fushi_books/`
///   正文副本，不碰用户源文件。合订本的阅读进度 / 书签随行一起删——2000 页里的
///   页码对不上任何一卷，没有可迁移的落点。
Future<({List<String> retiredUids, List<String> errors})>
retireFlattenedMangaSeries({
  required FushiDatabase db,
  required BookSourceIndex index,
  required int sourceId,
  required Iterable<FlattenedMangaSeries> series,
}) async {
  final List<String> retired = <String>[];
  final List<String> errors = <String>[];
  List<BookSourceRow>? rows;
  for (final FlattenedMangaSeries s in series) {
    final List<String?> volumeUids = <String?>[
      for (final String rel in s.volumeRels) index.uidOf(rel),
    ];
    if (volumeUids.isEmpty || volumeUids.contains(null)) continue;
    rows ??= await loadBookSourceRows(db);
    final String? indexedUid = index.uidOf(s.seriesRel);
    final String fallbackKey = sanitizeTtuFilename(s.seriesTitle);
    BookSourceRow? row;
    for (final BookSourceRow r in rows) {
      if (indexedUid != null
          ? r.uid == indexedUid
          : r.bookKey == fallbackKey &&
                r.sourceId == sourceId &&
                r.format == BookFormat.manga.dbValue) {
        row = r;
        break;
      }
    }
    if (row == null ||
        row.sourceId != sourceId ||
        row.format != BookFormat.manga.dbValue ||
        volumeUids.contains(row.uid) ||
        index.relsOf(row.uid).any((String rel) => rel != s.seriesRel)) {
      // 不是本来源的合订本（或还有别的源认领它）：只撤掉这条过期的卷登记。
      index.remove(s.seriesRel);
      continue;
    }
    try {
      await db.deleteEpubBook(row.bookKey);
    } catch (e) {
      errors.add('${row.bookKey}: $e');
      continue;
    }
    index.remove(s.seriesRel);
    rows.remove(row);
    retired.add(row.uid);
    try {
      await reclaimBookAssets(row);
    } catch (e) {
      errors.add('${row.bookKey}: reclaim ${row.extractDir}: $e');
    }
  }
  return (retiredUids: retired, errors: errors);
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
/// `.epub` 文件，漫画根是引擎归组出的 `.mokuro` 卷、单文件卷与纯页图卷目录——与扫描器导入的
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
      // 单文件卷（cbz / zip / rar …）同样是扫描器登记进索引的源；漏掉它们，
      // 不带 foundRelPaths 的对账会把每一本压缩包卷都当成「源已不在」回收。
      paths = <String>[
        ...plan.mokuroPaths,
        ...plan.carrierPaths,
        ...plan.imageFolders,
      ];
    case SourceLibraryKind.video:
      throw ArgumentError.value(kind, 'kind', 'video roots use video prune');
    case SourceLibraryKind.music:
      throw ArgumentError.value(
        kind,
        'kind',
        'music roots soft-delete via the music scanner',
      );
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
