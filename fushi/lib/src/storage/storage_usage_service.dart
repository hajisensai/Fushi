import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart' show fnv1a32Hex;
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
/// OCR 模型 `MangaOcrService.deleteModels`、Anime4K `deleteAnime4kShaderFiles`），
/// 由 UI 层接线——存储页新写裸 `Directory.delete` 会绕过墓碑/引用护栏
/// （见 `video_storage.dart` 头注释的共享资产误删坑）。
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
}

/// 一个类目内的单条可展开条目（一本书 / 一部词典 / 类目根下的一个子项）。
class StorageEntryUsage {
  const StorageEntryUsage({
    required this.id,
    required this.label,
    required this.bytes,
    required this.paths,
  });

  /// 域内主键（书 = bookKey，词典 = 词典名，通用子项 = 绝对路径）。
  final String id;

  /// 显示名（书名 / 词典名 / `<顶层目录>/<子项名>`）。
  final String label;

  /// 该条目占用字节数（多个目录求和）。
  final int bytes;

  /// 参与求和的绝对路径（诊断用）。
  final List<String> paths;
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

/// 书籍条目的扫描输入（由 UI 层从 `epub_books` + `srt_books` 表取出后传入）。
class StorageBookRef {
  const StorageBookRef({
    required this.bookKey,
    required this.title,
    required this.extractDir,
    this.persistKeys = const <String>[],
  });

  final String bookKey;

  final String title;

  /// `EpubBooks.extractDir`（解压正文绝对路径；这是唯一真相，**不要**用
  /// bookKey 重新派生——pre-v16 的书目录名是旧 int id）。
  final String extractDir;

  /// 有声书 persist 目录 `audiobooks/<fnv1a32Hex(key)>` 的键集合。真实键口径
  /// 与删除侧完全一致（`AudiobookRepository.delete` 传 bookKey、
  /// `SrtBookRepository` 传 SRT uid）：EPUB 配音频 = bookKey，字幕书音频 =
  /// 关联 `SrtBooks.uid`。**不是** `EpubBooks.uid`（那是 v81 的本机机器 id，
  /// 从不入哈希——审查 H1）。
  final List<String> persistKeys;
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
    StorageIsolateRunner? isolateRunner,
  })  : _documentsRoot = documentsRoot ?? AppPaths.documentsRootDirectory,
        _supportRoot = supportRoot ?? AppPaths.supportRootDirectory,
        _run = isolateRunner ?? Isolate.run;

  final Future<Directory> Function() _documentsRoot;
  final Future<Directory> Function() _supportRoot;
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
    final List<List<String>> perBookPaths = <List<String>>[
      for (final StorageBookRef b in books)
        <String>[
          b.extractDir,
          for (final String key in b.persistKeys)
            if (key.isNotEmpty) audiobookPersistDirPath(docs, key),
        ],
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
          id: books[i].bookKey,
          label: books[i].title,
          bytes: sizes[i + 1],
          paths: perBookPaths[i],
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
        ),
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    return StorageCategoryUsage(
      id: StorageCategoryId.dictionaries,
      bytes: sizes[0],
      entries: entries,
    );
  }

  Future<StorageCategoryUsage> _scanDatabase(final Directory support) async {
    // support 根的直接子项，减去 OCR 模型子目录（后者单列一类）。明细里因此
    // 能看到主库 `fushi.db`、本地发音库副本 `local_audio_*.db` 等具体大件。
    return _scanGeneric(
      StorageCategoryId.database,
      <String>[support.path],
      excludePaths: <String>{p.join(support.path, kOcrModelsSupportChild)},
    );
  }

  /// 通用类目扫描：类目根下每个直接子项一条明细，类目总量 = 明细求和。
  /// [excludePaths] 里的子项既不计入明细也不计入总量（被别的类目单列时用）。
  Future<StorageCategoryUsage> _scanGeneric(
    final StorageCategoryId id,
    final List<String> roots, {
    final Set<String> excludePaths = const <String>{},
  }) async {
    final List<Map<String, Object>> raw =
        await _run(() => _childEntriesSync(roots));
    final List<StorageEntryUsage> entries = <StorageEntryUsage>[
      for (final Map<String, Object> e in raw)
        if (!excludePaths.contains(e['path'] as String))
          StorageEntryUsage(
            // 通用明细没有域内主键，用绝对路径当身份（UI 只拿它做展开/去重，
            // 不接删除原语——通用条目一律只读展示）。
            id: e['path'] as String,
            label: e['label'] as String,
            bytes: e['bytes'] as int,
            paths: <String>[e['path'] as String],
          ),
    ]..sort((StorageEntryUsage a, StorageEntryUsage b) =>
        b.bytes.compareTo(a.bytes));
    final int bytes =
        entries.fold<int>(0, (int sum, StorageEntryUsage e) => sum + e.bytes);
    return StorageCategoryUsage(id: id, bytes: bytes, entries: entries);
  }

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
