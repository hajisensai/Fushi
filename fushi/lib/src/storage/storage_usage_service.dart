import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart'
    show databaseSnapshotMainFileName, fnv1a32Hex, isDeletableDatabaseSnapshot;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/books_directory.dart'
    show kLegacyBooksDirectoryName;
import 'package:fushi/src/storage/export_directory.dart'
    show kLegacyExportDirectoryName;

/// 存储占用扫描服务（设置 → 存储）。
///
/// 只读扫描：本文件**不做任何删除**。删除一律走各域既有的删除路径
/// （书籍 `ReaderFushiSource.deleteBook`、词典 `AppModel.deleteDictionary`、
/// 主库快照残留 fushi_core `deleteDatabaseSnapshotFiles`、
/// OCR 模型 `MangaOcrService.deleteModels`、Anime4K `deleteAnime4kShaderFiles`），
/// 由 UI 层接线——存储页新写裸 `Directory.delete` 会绕过墓碑/引用护栏
/// （见 `video_storage.dart` 头注释的共享资产误删坑）。每条明细带
/// [StorageEntryKind] 说明它接哪条原语（或只读）。
///
/// 类目清单是 [AppPaths.fushiOwnedDocumentsEntries] 的**全覆盖分组**：documents
/// 根下白名单顶层目录每一个都归属且只归属一个类目（守卫见
/// `storage_usage_service_test.dart`），support 根整体归「数据库与内部数据」，
/// 其中 OCR 模型子目录单独拆出（它是唯一可删可恢复的 support 子项）。
///
/// 每个类目都出明细：书籍/词典的条目来自 DB（有标题、接既有删除原语），其余
/// 类目的条目就是类目根下的直接子项（`_childEntriesSync`，只读展示）。
///
/// 目录求和递归 stat 整棵树（词典是 GB 级），全部经 [Isolate.run] 隔离跑，
/// 绝不在 UI isolate 同步扫。
enum StorageCategoryId {
  /// 书籍与有声书：`fushi_books`（EPUB/漫画解压正文）+ `hoshi_books`（旧名残留）
  /// + `audiobooks`（复制导入的音频）。
  books,

  /// 词典数据：`dictionaryResources` + `dictionaryImportWorkingDirectory` +
  /// `recommended_pack`（新手引导推荐包＝词典+发音库的下载暂存，常态为空）。
  dictionaries,

  /// 视频下载：`remote_videos` + `anime_downloads` + `videos`。
  videoDownloads,

  /// 封面与缩略图：`video_covers` + `game_covers` + `thumbnails`。
  covers,

  /// 字幕副本：`video_subtitles`。
  subtitles,

  /// 视频着色器与 mpv Lua 脚本：`mpv_shaders`（Anime4K 下载与用户自导入混放）
  /// + `mpv_scripts`（体量极小，不值得独立类目）。
  shaders,

  /// 自定义字体：`custom_fonts`。
  customFonts,

  /// 网页存档与浏览器数据：`webArchive` + `browser`。
  web,

  /// 导出文件：`fushiExport` + `hibikiExport`。
  exports,

  /// 数据库与内部数据：support 根的直接子项减去 OCR 模型子目录（主库
  /// `fushi.db`、本地发音库副本 `local_audio_*.db` 等都在明细里）。
  database,

  /// 漫画 OCR 模型：`<support>/ocr_models`（可删可恢复）。
  ocrModels,

  /// BUG-1905：缓存与临时文件。
  ///
  /// 此前 `scanCategories` 只取 documents + support 两个根，**缓存根一个都没扫过**，
  /// 而在 iOS 上它恰恰是大头：`path_provider` 的 `getTemporaryDirectory()` 在 Apple
  /// 平台返回的是 **`Library/Caches`**（不是 `tmp`，见 `PathProviderPlugin.swift` 的
  /// `case .temp: return .cachesDirectory`），而 Dart 的 `Directory.systemTemp` 读
  /// `TMPDIR` 指向 `<沙盒>/tmp`——**两个不同目录**。落在这里的有：远端封面缓存
  /// （自称常驻）、互联导入发音库的 staging 副本（与 support 里那份重复）、整包
  /// `.fushiaudio` / EPUB、备份 zip、file_picker 对每个导入文件的整份复制、
  /// `flutter_cache_manager` 的图片缓存。
  ///
  /// iOS 系统设置里的「文稿与数据」= Documents + 整个 Library/* + tmp，三块全算；
  /// 只扫两块必然少报（用户 2026-08-28：app 内 6.9 GB vs 系统 13.68 GB）。
  ///
  /// **具体扫哪些根按平台门控**——桌面的临时目录是全系统共享的，算进来会严重高报。
  /// 判据与理由见 [StorageUsageService._defaultCacheRoots]。
  cache,

  /// BUG-1905：其他未归类 —— documents 根下**不在**白名单里的顶层项。
  ///
  /// 存在的意义是让「漏算」变得**结构上无法隐藏**：此前总计 = 各类目之和，
  /// 而类目 = 一份手写白名单，漏了什么就静默少算多少，页面自己永远发现不了
  /// （守卫测试也只断言「类目清单 == 迁移白名单」，而迁移白名单本身就故意排除
  /// 了 temp、`video_clips`、日志）。现在白名单之外的东西会自己冒出来。
  ///
  /// **只在 documents 根是 Fushi 专属容器时才有意义**：老安装的扁平布局下
  /// documents 根就是用户真实的 `Documents` 文件夹（共享目录，装着用户自己的
  /// 文件），把那些算进来既不准也吓人。桌面扁平布局下本类目恒为 0。
  other,
}

/// 明细条目的种类 = 它接哪条删除原语。可删性属于**条目**而不是类目：同一个
/// 「数据库与内部数据」类目里，活库是只读的，快照残留却可删（BUG-1870）。
enum StorageEntryKind {
  /// 一本书（`id` = bookKey；删除走 `ReaderFushiSource.deleteBook`）。
  book,

  /// 一本纯字幕书 / standalone 有声书（`id` = `SrtBooks.uid`；删除走
  /// `SrtBookRepository.delete`）。这类书**没有** EpubBooks 行、`bookKey` 恒空，
  /// 不能走 `ReaderFushiSource.deleteBook`（那条路按 bookKey 找行，必然落空）。
  srtBook,

  /// 一部词典（`id` = 词典名；删除走 `AppModel.deleteDictionary`）。
  dictionary,

  /// support 根下全部主库快照残留聚成的**一条**（`paths` = 文件清单；删除走
  /// fushi_core `deleteDatabaseSnapshotFiles`，识别口径同源）。
  databaseSnapshots,

  /// 类目根下的磁盘子项，只读展示（删它就是裸 `Directory.delete`，绕过墓碑/引用护栏）。
  readOnly,
}

/// 一个类目内的单条可展开条目（一本书 / 一部词典 / 类目根下的一个子项）。
class StorageEntryUsage {
  const StorageEntryUsage({
    required this.id,
    required this.label,
    required this.bytes,
    required this.paths,
    required this.kind,
    this.externalPaths = const <String>[],
  });

  /// 域内主键（EPUB 书 = bookKey，纯字幕书 = `SrtBooks.uid`，词典 = 词典名，
  /// 通用子项 = 绝对路径）。
  final String id;

  /// 显示名（书名 / 词典名 / `<顶层目录>/<子项名>`）。[StorageEntryKind.databaseSnapshots]
  /// 的显示名由 UI 按 `paths.length` 翻译，此处只是无 i18n 的兜底。
  final String label;

  final StorageEntryKind kind;

  /// 该条目占用字节数（多个目录求和）。
  final int bytes;

  /// 参与求和的绝对路径（诊断用）。
  final List<String> paths;

  /// 「引用原文件」的外部路径：桌面导入勾了「引用原文件」时音频留在 app 目录
  /// 之外（`AudiobookStorage.syncAudioFiles(copy: false)` 直接存原始绝对路径），
  /// 既不占应用空间也删不掉。**不计入 [bytes]**，只用于告诉用户「这本书的音频
  /// 在别处」——否则条目显示 0 字节，用户以为音频丢了（BUG-1893）。
  final List<String> externalPaths;
}

/// 一个类目的扫描结果。
class StorageCategoryUsage {
  const StorageCategoryUsage({
    required this.id,
    required this.bytes,
    this.entries = const <StorageEntryUsage>[],
  });

  final StorageCategoryId id;

  /// 类目总字节数。书籍/词典类目按**目录整树**求和——可能大于 [entries] 之和：
  /// 孤儿目录、未入库残留也如实计入，不做「只算已知条目」的假账；其余类目的
  /// 明细就是根目录的全部直接子项，两者恒相等。
  final int bytes;

  /// 可展开明细，按字节数降序。书籍/词典是 DB 已知条目（带删除原语），其余
  /// 类目是类目根下的直接子项（只读展示）。
  final List<StorageEntryUsage> entries;
}

/// 书籍条目的扫描输入（由 UI 层从 `epub_books` + `srt_books` + `audiobooks`
/// 三张表取出后传入）。
class StorageBookRef {
  const StorageBookRef({
    required this.id,
    required this.title,
    required this.extractDir,
    this.persistKeys = const <String>[],
    this.audioPaths = const <String>[],
    this.kind = StorageEntryKind.book,
  });

  /// 域内主键，直接成为 [StorageEntryUsage.id]：[StorageEntryKind.book] 时是
  /// `EpubBooks.bookKey`，[StorageEntryKind.srtBook] 时是 `SrtBooks.uid`
  /// （standalone 字幕书的 bookKey 恒空串，做不了身份）。删除侧按 [kind] 分流。
  final String id;

  final String title;

  /// `EpubBooks.extractDir`（解压正文绝对路径；这是唯一真相，**不要**用
  /// bookKey 重新派生——pre-v16 的书目录名是旧 int id）。standalone 字幕书没有
  /// EPUB 正文载体，传空串。
  final String extractDir;

  /// 有声书 persist 目录 `audiobooks/<fnv1a32Hex(key)>` 的键集合。真实键口径
  /// 与删除侧完全一致（`AudiobookRepository.delete` 传 bookKey、
  /// `SrtBookRepository` 传 SRT uid）：EPUB 配音频 = bookKey，字幕书音频 =
  /// 关联 `SrtBooks.uid`。**不是** `EpubBooks.uid`（那是 v81 的本机机器 id，
  /// 从不入哈希——审查 H1）。
  ///
  /// 哈希目录只是**本地导入**这一条路径的形态，不是唯一形态：见 [audioPaths]。
  final List<String> persistKeys;

  /// DB 里记的音频**真实路径**：`Audiobooks.audioRoot` / `SrtBooks.audioRoot`
  /// 与两表 `audioPathsJson` 里的逐个文件路径。
  ///
  /// BUG-1893：互联/同步拉来的有声书落的是**明文目录**
  /// `audiobooks/<safeDirName(bookKey|uid)>`（`sync_asset_package_service.dart`），
  /// 不是 [persistKeys] 派生的哈希目录。只按哈希反推就永远找不到它们，明细行
  /// 显示 0 字节、几 GB 音频全掉进「类目总量 − 明细之和」的差额里。DB 路径是
  /// 真相源，哈希派生只是存量兼容——两者都喂进来，重叠部分由
  /// [resolveBookStoragePaths] 去嵌套去重，不会重复计数。
  final List<String> audioPaths;

  /// 该条目接哪条删除原语（[StorageEntryKind.book] / [StorageEntryKind.srtBook]）。
  final StorageEntryKind kind;
}

/// 一本书的存储路径拆解结果（[resolveBookStoragePaths] 的产物）。
class StorageBookPaths {
  const StorageBookPaths({required this.counted, required this.external});

  /// 计入体积的绝对路径：已去重、去嵌套，且音频部分全部落在书籍类目根之内
  /// （保证「明细之和 ≤ 类目总量」这条不变式）。
  final List<String> counted;

  /// 落在 app 目录之外的音频路径（引用导入）。见 [StorageEntryUsage.externalPaths]。
  final List<String> external;
}

/// [path] 是否等于或位于 [roots] 中任一根之内（空路径/空根跳过）。
bool _isWithinAny(final List<String> roots, final String path) {
  if (path.isEmpty) return false;
  final String target = p.canonicalize(path);
  for (final String root in roots) {
    if (root.isEmpty) continue;
    final String base = p.canonicalize(root);
    if (p.equals(base, target) || p.isWithin(base, target)) return true;
  }
  return false;
}

/// 去掉重复路径与**被别的路径包住**的路径（保持原序）。
///
/// 这是「DB 真实路径 + 哈希派生目录」两个来源并存的必然要求：同步导入的书
/// `audioRoot` 是目录、`audioPathsJson` 是它下面的文件，本地导入的哈希目录又
/// 常常与 `audioRoot` 是同一个目录——不去嵌套就会把同一堆字节数两次三次。
List<String> _dedupeNestedPaths(final List<String> paths) {
  final List<String> kept = <String>[];
  final List<String> canonical = <String>[];
  for (final String path in paths) {
    if (path.isEmpty) continue;
    final String key = p.canonicalize(path);
    if (canonical.contains(key)) continue;
    kept.add(path);
    canonical.add(key);
  }
  return <String>[
    for (int i = 0; i < kept.length; i++)
      if (!_isWithinAny(<String>[
        for (int j = 0; j < canonical.length; j++)
          if (j != i) canonical[j],
      ], canonical[i]))
        kept[i],
  ];
}

/// 把一条 [book] 拆成「计入体积的路径」与「外部引用路径」两组。
///
/// [categoryRoots] 是书籍类目的 documents 子根（`fushi_books` / 旧名 /
/// `audiobooks`）。音频路径只有落在这些根之内才计入——落在外面的是桌面
/// 「引用原文件」导入，本来就不占应用空间、也删不掉，计进去就是假账（而类目
/// 总量同样扫不到它，明细之和就会大于类目总量）。
/// [StorageBookRef.extractDir] 无条件计入（它是 app 自己解压出来的正文）。
StorageBookPaths resolveBookStoragePaths({
  required final Directory documentsRoot,
  required final StorageBookRef book,
  required final List<String> categoryRoots,
}) {
  final List<String> inside = <String>[];
  final List<String> external = <String>[];
  for (final String candidate in <String>[
    for (final String key in book.persistKeys)
      if (key.isNotEmpty) audiobookPersistDirPath(documentsRoot, key),
    for (final String path in book.audioPaths)
      if (path.isNotEmpty) path,
  ]) {
    (_isWithinAny(categoryRoots, candidate) ? inside : external).add(candidate);
  }
  return StorageBookPaths(
    counted: _dedupeNestedPaths(<String>[
      if (book.extractDir.isNotEmpty) book.extractDir,
      ...inside,
    ]),
    external: _dedupeNestedPaths(external),
  );
}

/// 随包组件（安装目录内、随安装包携带）的一条展示项。
class BundledComponentUsage {
  const BundledComponentUsage({
    required this.name,
    required this.bytes,
    required this.path,
  });

  /// 目录/文件名（不翻译——它就是磁盘上的名字）。
  final String name;
  final int bytes;
  final String path;
}

/// 每类目 → documents 根下归属的顶层目录名。与
/// [AppPaths.fushiOwnedDocumentsEntries] 保持全覆盖（守卫测试咬住）。
const Map<StorageCategoryId, List<String>> kStorageCategoryDocumentsChildren =
    <StorageCategoryId, List<String>>{
  StorageCategoryId.books: <String>[
    'fushi_books',
    // 旧名存量目录（启动就地改名失败时仍可能在磁盘上）：引用迁移常量，
    // 不重复旧代号字面量（fushi_rename_guard 禁模式）。
    kLegacyBooksDirectoryName,
    'audiobooks',
  ],
  StorageCategoryId.dictionaries: <String>[
    'dictionaryResources',
    'dictionaryImportWorkingDirectory',
    'recommended_pack',
  ],
  StorageCategoryId.videoDownloads: <String>[
    'remote_videos',
    'anime_downloads',
    'videos',
    // 下载页「手动添加任务」的 .torrent 元数据（随任务持久化）。体量很小，但必须
    // 归进某个类目——否则存储页总量对不上白名单（守卫逼着新目录选类目）。
    'manual_torrents',
  ],
  StorageCategoryId.covers: <String>[
    'video_covers',
    'game_covers',
    'thumbnails',
  ],
  StorageCategoryId.subtitles: <String>['video_subtitles'],
  StorageCategoryId.shaders: <String>['mpv_shaders', 'mpv_scripts'],
  StorageCategoryId.customFonts: <String>['custom_fonts'],
  StorageCategoryId.web: <String>['webArchive', 'browser'],
  StorageCategoryId.exports: <String>[
    'fushiExport',
    // 同上：旧名存量目录走迁移常量。
    kLegacyExportDirectoryName,
  ],
  StorageCategoryId.database: <String>[],
  StorageCategoryId.ocrModels: <String>[],
};

/// `<support>/ocr_models`（[StorageCategoryId.ocrModels] 的根；
/// `MangaOcrServiceImpl.defaultMangaOcrModelsDir` 是它下面的 `manga/`）。
const String kOcrModelsSupportChild = 'ocr_models';

/// 同步递归求目录字节数（isolate 入口；每个 entry 单独容错——扫描中途被删/
/// 无权限的文件跳过不炸整树）。
int directorySizeSync(final String path) {
  final Directory dir = Directory(path);
  if (!dir.existsSync()) {
    // 不是目录时按文件算（随包组件里有单文件项）。
    final File f = File(path);
    try {
      return f.existsSync() ? f.lengthSync() : 0;
    } on FileSystemException {
      return 0;
    }
  }
  int total = 0;
  try {
    for (final FileSystemEntity e
        in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        total += e.lengthSync();
      } on FileSystemException {
        // 竞态删除/无权限：跳过该文件。
      }
    }
  } on FileSystemException {
    // 整树列举失败（目录被并发删除等）：返回已累计部分。
  }
  return total;
}

/// isolate 入口：多路径求和（每条路径独立容错）。
int _pathsSizeSync(final List<String> paths) {
  int total = 0;
  for (final String path in paths) {
    total += directorySizeSync(path);
  }
  return total;
}

/// isolate 入口：列出多个根目录的**直接子项**并逐个求大小。
///
/// 这是除书籍/词典（有 DB 标题与既有删除原语，见 `_scanBooks` / `_scanDictionaries`）
/// 之外所有类目的明细来源：类目根下每个文件/子目录一条，label 带顶层目录名前缀
/// （`videos/Foo.mkv`、`mpv_shaders/Anime4K_Clamp.glsl`），跨根重名不会混淆。
///
/// 子项之和恒等于整树之和（根目录自身不占字节），所以类目总量直接由明细求和得出，
/// 不再额外扫一遍整树。
List<Map<String, Object>> _childEntriesSync(final List<String> roots) {
  final List<Map<String, Object>> out = <Map<String, Object>>[];
  for (final String root in roots) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } on FileSystemException {
      // 整树列举失败（并发删除/无权限）：该根跳过。
      continue;
    }
    for (final FileSystemEntity child in children) {
      out.add(<String, Object>{
        'label': '${p.basename(root)}/${p.basename(child.path)}',
        'path': child.path,
        'bytes': directorySizeSync(child.path),
        'isFile': child is File,
      });
    }
  }
  return out;
}

/// 有声书 persist 目录的纯派生（**不创建**，与
/// `AudiobookStorage.ensurePersistDir` 同口径：`fnv1a32Hex(utf8(key))`；
/// 该口径已固化进持久目录名，不得漂移——上游金标在 fushi_core
/// `stable_hash_test.dart`）。[persistKey] 的取值见 [StorageBookRef.persistKeys]。
String audiobookPersistDirPath(
        final Directory documentsRoot, final String persistKey) =>
    p.join(
        documentsRoot.path, 'audiobooks', fnv1a32Hex(utf8.encode(persistKey)));

/// 目录求和的执行环境（默认 [Isolate.run]；widget 测试的 FakeAsync 区里真
/// isolate 永不完成，测试注同步执行版 `<R>(f) async => f()`）。
typedef StorageIsolateRunner = Future<R> Function<R>(R Function() computation);

class StorageUsageService {
  StorageUsageService({
    Future<Directory> Function()? documentsRoot,
    Future<Directory> Function()? supportRoot,
    Future<List<Directory>> Function()? cacheRoots,
    Future<bool> Function()? documentsRootIsFushiOwned,
    StorageIsolateRunner? isolateRunner,
  })  : _documentsRoot = documentsRoot ?? AppPaths.documentsRootDirectory,
        _supportRoot = supportRoot ?? AppPaths.supportRootDirectory,
        _cacheRoots = cacheRoots ?? _defaultCacheRoots,
        _documentsRootIsFushiOwned =
            documentsRootIsFushiOwned ?? AppPaths.documentsRootIsFushiOwned,
        _run = isolateRunner ?? Isolate.run;

  final Future<Directory> Function() _documentsRoot;
  final Future<Directory> Function() _supportRoot;

  /// BUG-1905：此前完全没被扫过的第三类根（缓存/临时）。见 [_defaultCacheRoots]。
  final Future<List<Directory>> Function() _cacheRoots;

  /// BUG-1905：见 [AppPaths.documentsRootIsFushiOwned]——决定「其他未归类」敢不敢算。
  final Future<bool> Function() _documentsRootIsFushiOwned;

  final StorageIsolateRunner _run;

  /// 多路径求和（isolate 隔离）。
  Future<int> sizeOfPaths(final List<String> paths) =>
      _run(() => _pathsSizeSync(paths));

  /// 逐类目扫描，每算完一类就产出一个结果（UI 渐进刷新，慢的词典类目
  /// 不挡快的类目）。[books] / [dictionaryNames] 由调用方从 DB/AppModel 取出。
  Stream<StorageCategoryUsage> scanCategories({
    required final List<StorageBookRef> books,
    required final List<String> dictionaryNames,
  }) async* {
    final Directory docs = await _documentsRoot();
    final Directory support = await _supportRoot();

    for (final StorageCategoryId id in StorageCategoryId.values) {
      switch (id) {
        case StorageCategoryId.books:
          yield await _scanBooks(docs, books);
        case StorageCategoryId.dictionaries:
          yield await _scanDictionaries(docs, dictionaryNames);
        case StorageCategoryId.database:
          yield await _scanDatabase(support);
        case StorageCategoryId.ocrModels:
          yield await _scanGeneric(id, <String>[
            p.join(support.path, kOcrModelsSupportChild),
          ]);
        case StorageCategoryId.cache:
          yield await _scanCache();
        case StorageCategoryId.other:
          yield await _scanOther(docs);
        default:
          final List<String> children =
              kStorageCategoryDocumentsChildren[id] ?? const <String>[];
          yield await _scanGeneric(id, <String>[
            for (final String child in children) p.join(docs.path, child),
          ]);
      }
    }
  }

  Future<StorageCategoryUsage> _scanBooks(
    final Directory docs,
    final List<StorageBookRef> books,
  ) async {
    // 总量按目录整树（含孤儿），明细按 DB 已知的书。全部路径打包进**一次**
    // isolate 调用，避免几百本书起几百个 isolate。
    final List<String> categoryRoots = <String>[
      for (final String child
          in kStorageCategoryDocumentsChildren[StorageCategoryId.books]!)
        p.join(docs.path, child),
    ];
    // BUG-1893：明细口径 = DB 里记的真实音频路径（`audioRoot`/`audioPathsJson`）
    // ∪ 哈希派生的 persist 目录，去嵌套去重后求和。只按哈希反推会漏掉同步导入
    // 落的明文目录（几 GB 音频显示成 0）。
    final List<StorageBookPaths> perBook = <StorageBookPaths>[
      for (final StorageBookRef b in books)
        resolveBookStoragePaths(
          documentsRoot: docs,
          book: b,
          categoryRoots: categoryRoots,
        ),
    ];
    final List<List<String>> perBookPaths = <List<String>>[
      for (final StorageBookPaths paths in perBook) paths.counted,
    ];
    final List<int> sizes = await _run(() {
      return <int>[
        _pathsSizeSync(categoryRoots),
        for (final List<String> paths in perBookPaths) _pathsSizeSync(paths),
      ];
    });
    final List<StorageEntryUsage> entries = <StorageEntryUsage>[
      for (int i = 0; i < books.length; i++)
        StorageEntryUsage(
          id: books[i].id,
          label: books[i].title,
          bytes: sizes[i + 1],
          paths: perBookPaths[i],
          externalPaths: perBook[i].external,
          kind: books[i].kind,
        ),
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
      id: StorageCategoryId.books,
      bytes: sizes[0],
      entries: entries,
    );
  }

  Future<StorageCategoryUsage> _scanDictionaries(
    final Directory docs,
    final List<String> dictionaryNames,
  ) async {
    final List<String> categoryRoots = <String>[
      for (final String child
          in kStorageCategoryDocumentsChildren[StorageCategoryId.dictionaries]!)
        p.join(docs.path, child),
    ];
    final String resourcesRoot = p.join(docs.path, 'dictionaryResources');
    final List<String> perDictPaths = <String>[
      for (final String name in dictionaryNames) p.join(resourcesRoot, name),
    ];
    final List<int> sizes = await _run(() {
      return <int>[
        _pathsSizeSync(categoryRoots),
        for (final String path in perDictPaths) directorySizeSync(path),
      ];
    });
    final List<StorageEntryUsage> entries = <StorageEntryUsage>[
      for (int i = 0; i < dictionaryNames.length; i++)
        StorageEntryUsage(
          id: dictionaryNames[i],
          label: dictionaryNames[i],
          bytes: sizes[i + 1],
          paths: <String>[perDictPaths[i]],
          kind: StorageEntryKind.dictionary,
        ),
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
      id: StorageCategoryId.dictionaries,
      bytes: sizes[0],
      entries: entries,
    );
  }

  /// 快照聚合条目的域内主键（UI 用它做忙碌态/去重）。
  static const String kDatabaseSnapshotsEntryId = 'database-snapshots';

  Future<StorageCategoryUsage> _scanDatabase(final Directory support) async {
    // support 根的直接子项，减去 OCR 模型子目录（后者单列一类）。明细里因此
    // 能看到主库 `fushi.db`、本地发音库副本 `local_audio_*.db` 等具体大件。
    //
    // BUG-1870：主库快照残留（`fushi.db.corrupt-bak-<stamp>.db*`、旧
    // `hibiki.db.bak.v16.*` 等，用户机器上实测几十个）不再逐个按原始文件名铺开，
    // 而是聚成**一条**可删条目——识别口径直接用 fushi_core 的
    // [isDeletableDatabaseSnapshot]（形态白名单 + 恢复流程所有权门控），与删除
    // 原语同源。所有权门控需要「同目录还有哪些文件」，这份清单 [raw] 里已经有了，
    // 不再二次 IO。
    final List<Map<String, Object>> raw =
        await _run(() => _childEntriesSync(<String>[support.path]));
    final Set<String> supportChildNames = <String>{
      for (final Map<String, Object> e in raw) p.basename(e['path'] as String),
    };
    final List<Map<String, Object>> snapshots = <Map<String, Object>>[
      for (final Map<String, Object> e in raw)
        if (e['isFile'] as bool &&
            isDeletableDatabaseSnapshot(
                p.basename(e['path'] as String), supportChildNames))
          e,
    ];
    final List<String> snapshotPaths = <String>[
      for (final Map<String, Object> e in snapshots) e['path'] as String,
    ];
    final List<StorageEntryUsage> entries = <StorageEntryUsage>[
      ..._readOnlyEntries(raw, excludePaths: <String>{
        p.join(support.path, kOcrModelsSupportChild),
        ...snapshotPaths,
      }),
      if (snapshots.isNotEmpty)
        StorageEntryUsage(
          id: kDatabaseSnapshotsEntryId,
          label: '${p.basename(support.path)}/'
              '${_snapshotStemLabel(snapshotPaths)}.*',
          bytes: snapshots.fold<int>(
              0, (int sum, Map<String, Object> e) => sum + (e['bytes'] as int)),
          paths: snapshotPaths,
          kind: StorageEntryKind.databaseSnapshots,
        ),
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
      id: StorageCategoryId.database,
      bytes: _sumBytes(entries),
      entries: entries,
    );
  }

  /// 快照聚合条目 fallback label 里的库名部分。按**实际命中的**主库名生成：
  /// 老用户盘上几十个文件全是 `hibiki.db.*`，写死 `fushi.db.*` 一个都描述不到
  /// （BUG-1870 审查）。两个库名都命中时并列列出。
  static String _snapshotStemLabel(final List<String> snapshotPaths) {
    final List<String> stems = <String>{
      for (final String path in snapshotPaths)
        if (databaseSnapshotMainFileName(p.basename(path)) case final String s)
          s,
    }.toList()
      ..sort();
    return stems.length == 1 ? stems.single : '{${stems.join(',')}}';
  }

  /// 通用类目扫描：类目根下每个直接子项一条明细，类目总量 = 明细求和。
  Future<StorageCategoryUsage> _scanGeneric(
    final StorageCategoryId id,
    final List<String> roots,
  ) async {
    final List<Map<String, Object>> raw =
        await _run(() => _childEntriesSync(roots));
    final List<StorageEntryUsage> entries = _readOnlyEntries(raw)
      ..sort((StorageEntryUsage a, StorageEntryUsage b) =>
          b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
        id: id, bytes: _sumBytes(entries), entries: entries);
  }

  /// BUG-1905：要统计的缓存/临时根。
  ///
  /// **只在这些目录确实属于本 app 时才统计** —— 这是本类目唯一的正确性红线：
  /// * **iOS / Android**：两个目录都在 app 沙盒内，且**互不相同**——
  ///   `path_provider` 的 `getTemporaryDirectory()` 在 Apple 平台返回
  ///   `Library/Caches`（见 `PathProviderPlugin.swift` 的
  ///   `case .temp: return .cachesDirectory`），而 Dart 的 `Directory.systemTemp`
  ///   读 `TMPDIR` 指向 `<沙盒>/tmp`。两个都要算，去重后扫。
  /// * **macOS**：`getTemporaryDirectory()` 给的是 app 私有的 `Library/Caches`，
  ///   算；但 `systemTemp`（`/var/folders/…/T`）是跨 app 共享的，不算。
  /// * **Windows / Linux**：临时目录是**全系统共享**的（`%TEMP%` / `/tmp`），
  ///   里面装着别的程序的文件。把它算进 app 占用会严重高报——宁可这一类为 0，
  ///   也绝不报一个假的大数。要在桌面统计 Fushi 自己的临时文件，只能再引入一份
  ///   「哪些子目录是我们的」白名单，而白名单漂移正是本 bug 的成因，不再重蹈。
  static Future<List<Directory>> _defaultCacheRoots() async {
    final bool sandboxed = Platform.isIOS || Platform.isAndroid;
    if (!sandboxed && !Platform.isMacOS) return const <Directory>[];
    final Directory temp = await AppPaths.tempRootDirectory();
    if (!sandboxed) return <Directory>[temp];
    final Directory system = Directory.systemTemp;
    return <Directory>[
      temp,
      if (p.canonicalize(system.path) != p.canonicalize(temp.path)) system,
    ];
  }

  /// BUG-1905：缓存与临时文件。根的选取与理由见 [_defaultCacheRoots]。
  Future<StorageCategoryUsage> _scanCache() async {
    final List<Directory> roots = await _cacheRoots();
    if (roots.isEmpty) {
      return const StorageCategoryUsage(id: StorageCategoryId.cache, bytes: 0);
    }
    return _scanGeneric(
      StorageCategoryId.cache,
      <String>[for (final Directory d in roots) d.path],
    );
  }

  /// BUG-1905：documents 根下**白名单之外**的顶层项。
  ///
  /// 让漏算无法隐藏：白名单是手写的，漏了什么就静默少算多少，而总计恰恰是各类目
  /// 之和，页面自己永远发现不了。已知的两个既有漏点就落在这里——剪辑导出
  /// `video_clips`（`clip_export.part.dart`，`fushiOwnedDocumentsEntries` 明确「刻意
  /// 不收」）与错误日志 `.txt`。
  ///
  /// 桌面老扁平安装下 documents 根就是用户自己的文档文件夹，那里的东西不是 app 的
  /// 占用，本类目直接返回 0（见 [AppPaths.documentsRootIsFushiOwned]）。
  Future<StorageCategoryUsage> _scanOther(final Directory docs) async {
    if (!await _documentsRootIsFushiOwned()) {
      return const StorageCategoryUsage(id: StorageCategoryId.other, bytes: 0);
    }
    final List<Map<String, Object>> raw =
        await _run(() => _childEntriesSync(<String>[docs.path]));
    const Set<String> known = AppPaths.fushiOwnedDocumentsEntries;
    final List<StorageEntryUsage> entries = <StorageEntryUsage>[
      for (final StorageEntryUsage e in _readOnlyEntries(raw))
        if (!known.contains(p.basename(e.paths.single))) e,
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
      id: StorageCategoryId.other,
      bytes: _sumBytes(entries),
      entries: entries,
    );
  }

  /// isolate 回传的原始子项 → 只读明细。[excludePaths] 里的子项既不计入明细也不
  /// 计入总量（被别的类目单列、或已聚合进别的条目时用）。
  static List<StorageEntryUsage> _readOnlyEntries(
    final List<Map<String, Object>> raw, {
    final Set<String> excludePaths = const <String>{},
  }) {
    return <StorageEntryUsage>[
      for (final Map<String, Object> e in raw)
        if (!excludePaths.contains(e['path'] as String))
          StorageEntryUsage(
            // 通用明细没有域内主键，用绝对路径当身份（UI 只拿它做展开/去重）。
            id: e['path'] as String,
            label: e['label'] as String,
            bytes: e['bytes'] as int,
            paths: <String>[e['path'] as String],
            kind: StorageEntryKind.readOnly,
          ),
    ];
  }

  static int _sumBytes(final List<StorageEntryUsage> entries) =>
      entries.fold<int>(0, (int sum, StorageEntryUsage e) => sum + e.bytes);

  /// 随包组件占用（桌面端安装目录内、随安装包携带；**只展示不可删**——
  /// 更新 = 安装器整体重写安装目录，删掉的必然回来）。移动端返回空。
  Future<List<BundledComponentUsage>> scanBundledComponents() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return const <BundledComponentUsage>[];
    }
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    // 已知的可选大件；不存在的项直接不出现（不显示 0 字节噪音行）。
    // voice_hook / galgame_helper / magpie* 见 galgame_helper_installer.dart
    // 与 magpie_installer.dart 的目录名常量；mihon_bridge 见
    // desktop_mihon_runtime.dart。
    const List<String> candidates = <String>[
      'voice_hook',
      'galgame_helper',
      'magpie',
      'magpie_bundle',
      'mihon_bridge',
      'ffmpeg.exe',
    ];
    final List<String> paths = <String>[
      for (final String name in candidates) p.join(exeDir, name)
    ];
    final List<int> sizes = await _run(
        () => <int>[for (final String path in paths) directorySizeSync(path)]);
    return <BundledComponentUsage>[
      for (int i = 0; i < candidates.length; i++)
        if (sizes[i] > 0)
          BundledComponentUsage(
            name: candidates[i],
            bytes: sizes[i],
            path: paths[i],
          ),
    ];
  }
}

/// 人类可读字节数（存储页统一口径：1024 进制，两位小数以内）。
String formatStorageBytes(final int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}
