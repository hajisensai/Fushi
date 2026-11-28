/// 受管存储区域登记表（架构重构 D1）。
///
/// 「磁盘上哪个目录归 Fushi 管、在哪个根下、叫什么、旧名是什么、归哪个存储类目、
/// 什么性质、随不随数据根搬」是**一个事实**，以前却在 `EnginePaths` / `AppPaths`
/// 白名单 / 存储页类目表 / 书库证据豁免 / `ServerPaths` 五处手写，再靠扫源码的守卫
/// 对齐。现在它只写在这里定义的 [StorageArea] 值上：
///
/// - 引擎只定义值类型与 [StorageAreaRegistry]，外加引擎自己派生目录的那几个区域
///   （[EngineStorageArea]）。app 与 `fushi_server` 各自用自己的增强枚举实现
///   [StorageArea]，在装配期把「引擎区域 + 自己的区域」交给 [StorageAreaRegistry]
///   ——枚举值就是登记项，新加一个区域只加一个枚举值，不存在「声明了却忘了登记」。
/// - 所有者从自己登记的区域取目录（`EnginePaths.areaDirectory` /
///   `AppPaths.areaDirectory` / [StorageAreaPath.pathUnder]），不再手写
///   `p.join(<根>, '<字面量>')`。
/// - 迁移白名单、存储类目、证据豁免都从登记表派生，不再另写一份。
///
/// 引擎只带 id：类目的标题与图标、确认文案留在 app 层。
library;

import 'package:path/path.dart' as p;

/// 书库正文目录 `fushi_books` 的存量旧名（W2-7：启动就地改名，改名失败时仍可能留在
/// 磁盘上；数据根搬迁、存储页、证据探测都必须继续认它）。
const String kLegacyBooksDirectoryName = 'hoshi_books';

/// 区域挂在哪个根下。根的绝对路径由宿主解析（app：`AppPaths`；服务端：`ServerPaths`）。
enum StorageRootId {
  /// 内容 / 书库根（数据根的 documents 半边；老安装扁平布局下 = 共享的用户 Documents）。
  documents(migratesWithDataRoot: true),

  /// 数据库 / 模型根（数据根的 support 半边）。它搬不搬由迁移请求整体决定
  /// （BUG-1188：默认根迁移时数据库留在原地），区域自己不单独决定。
  support(migratesWithDataRoot: true),

  /// 临时根（`getTemporaryDirectory()`）。
  temp(migratesWithDataRoot: false),

  /// 本 app 专属缓存根（`getApplicationCacheDirectory()`）。
  appCache(migratesWithDataRoot: false),

  /// 用户可见的导出基目录（Android 外部 app 专属目录 / iOS「文件」App 可见的
  /// Documents / 桌面平台 Documents）。直连平台目录，刻意**不**随数据根走：
  /// 那里放的是交给用户的导出物，搬走反而与读写方脱节。
  userExports(migratesWithDataRoot: false),

  /// 无头服务端的 `data_dir` 本身（`interconnect/`、`logs/` 挂在这里）。app 没有这个根。
  hostData(migratesWithDataRoot: false);

  const StorageRootId({required this.migratesWithDataRoot});

  /// 挂在这个根下的区域是否随数据根迁移。
  final bool migratesWithDataRoot;
}

/// 区域里装的东西是什么性质。它决定区域的默认条目可删性
/// （[StorageLifecycleDefaults.defaultDeletability]），所有者可以按条目收紧。
enum StorageLifecycle {
  /// 用户数据：手动封面、导入的着色器 / 字体、登录态、导出物、备份。丢了找不回。
  userData,

  /// 书库内容：书、词典、视频、字幕。每条都有库行，删除只能走拥有者的删除链。
  libraryContent,

  /// 可重新算出来的派生物（任务缓存、识别稿）。
  derived,

  /// 纯缓存 / 暂存：没有任何库行 / 配置 / 用户产物指着，系统随时可能清掉。
  cache,

  /// 能重新下载的资源（模型、运行时）。
  redownloadable,

  /// app 自己的控制状态（引导进度、配对身份、续传元数据）。
  control,
}

/// 一个存储条目（区域下的一个子项 / 一本书 / 一部词典）能不能删、怎么删。
enum StorageEntryDeletability {
  /// 不能从存储页删（只读展示）：用户数据、或只能走拥有者删除链之外的东西。
  no,

  /// 可以删，但必须逐条确认。
  confirm,

  /// 纯缓存：可以逐条删，也进「一键清除全部缓存」。
  cacheBulk,
}

extension StorageLifecycleDefaults on StorageLifecycle {
  /// 区域级默认可删性。只是默认值：条目级判定属于所有者。
  StorageEntryDeletability get defaultDeletability => switch (this) {
    StorageLifecycle.userData => StorageEntryDeletability.no,
    StorageLifecycle.libraryContent => StorageEntryDeletability.no,
    StorageLifecycle.control => StorageEntryDeletability.no,
    StorageLifecycle.derived => StorageEntryDeletability.confirm,
    StorageLifecycle.redownloadable => StorageEntryDeletability.confirm,
    StorageLifecycle.cache => StorageEntryDeletability.cacheBulk,
  };
}

/// 存储类目 id（存储页的分组）。只是 id：标题、图标、说明文案在 app 层。
enum StorageCategoryId {
  /// 书籍与有声书。
  books,

  /// 词典数据（含导入工作目录、推荐包暂存）。
  dictionaries,

  /// 下载 / 抓轨 / 收件箱进来的媒体文件。
  videoDownloads,

  /// 封面与缩略图。
  covers,

  /// 字幕副本。
  subtitles,

  /// 字幕生成任务（ASR 任务缓存与登记产物）。
  subtitleJobs,

  /// 视频着色器与 mpv 脚本。
  shaders,

  /// 自定义字体。
  customFonts,

  /// 网页存档与浏览器数据。
  web,

  /// 导出文件。
  exports,

  /// 本地备份归档。
  backups,

  /// 数据库与内部数据。
  database,

  /// 漫画 OCR 模型。
  ocrModels,

  /// 缓存与临时文件。
  cache,

  /// 未登记的东西（结构上让漏算无法隐藏）。
  other,
}

/// 一个受管存储区域。宿主用增强枚举实现它（见 [EngineStorageArea]），枚举值即登记项。
abstract interface class StorageArea {
  /// 登记表内唯一的稳定 id（诊断 / 日志用；不是磁盘名）。
  String get id;

  /// 挂在哪个根下。
  StorageRootId get root;

  /// 相对 [root] 的路径，用 `/` 分隔（可多段，如 `torrent/resume`）。
  String get relativePath;

  /// 第一段的存量旧名（只认不写：迁移 / 统计 / 证据探测仍要认它）。只对单段区域有意义。
  List<String> get legacyNames;

  /// 归哪个存储类目。
  StorageCategoryId get category;

  /// 内容性质（决定默认可删性）。
  StorageLifecycle get lifecycle;

  /// 区域级可删性覆盖；null = 用 [lifecycle] 的默认值。只能**收紧**到所有者认可的
  /// 粒度：[StorageEntryDeletability.cacheBulk] 只允许 [StorageLifecycle.cache]
  /// （由 [StorageAreaRegistry] 构造期校验）。
  StorageEntryDeletability? get deletabilityOverride;

  /// 这个区域里有没有东西就算「书库在这个根」的证据。导出目录（冷启动会放
  /// `.nomedia`）、导入工作目录、推荐包暂存这类过程物不算（#4366）。
  bool get countsAsLibraryEvidence;
}

/// [StorageArea] 的派生量（全部由字段算出，不另存）。
extension StorageAreaPath on StorageArea {
  /// 随数据根迁移与否——完全由所在的根决定，写不出「documents 根下却不随根走」的区域。
  bool get migratesWithDataRoot => root.migratesWithDataRoot;

  /// 区域的默认条目可删性。
  StorageEntryDeletability get entryDeletability =>
      deletabilityOverride ?? lifecycle.defaultDeletability;

  /// [relativePath] 的各段。
  List<String> get segments => relativePath.split('/');

  /// 根下第一段（顶层目录名）。
  String get topLevelName => segments.first;

  /// 根下第一段的全部名字（现名 + 存量旧名）。
  List<String> get topLevelNames => <String>[topLevelName, ...legacyNames];

  /// 区域在 [rootPath]（[root] 的绝对路径）下的绝对路径。
  String pathUnder(String rootPath) =>
      p.joinAll(<String>[rootPath, ...segments]);
}

/// 一个宿主的区域登记表。构造期校验，违反约束直接抛 [ArgumentError]
/// （是编程错误，不做静默兜底）。
class StorageAreaRegistry {
  StorageAreaRegistry(Iterable<StorageArea> areas)
    : areas = List<StorageArea>.unmodifiable(areas) {
    _validate(this.areas);
  }

  final List<StorageArea> areas;

  /// [root] 下的全部区域。
  Iterable<StorageArea> under(StorageRootId root) =>
      areas.where((StorageArea a) => a.root == root);

  /// [root] 下全部顶层名（现名 + 旧名）。
  Set<String> topLevelNamesUnder(StorageRootId root) => <String>{
    for (final StorageArea a in under(root)) ...a.topLevelNames,
  };

  /// documents 根下随数据根迁移的顶层名全集（数据根迁移白名单 / 迷途库合并 /
  /// 沙盒重定位 / 书库探测的判据）。
  Set<String> get dataRootDocumentsEntries => <String>{
    for (final StorageArea a in under(StorageRootId.documents))
      if (a.migratesWithDataRoot) ...a.topLevelNames,
  };

  /// documents 根下不算书库证据的顶层名。
  Set<String> get libraryEvidenceIgnoredDocumentsEntries => <String>{
    for (final StorageArea a in under(StorageRootId.documents))
      if (!a.countsAsLibraryEvidence) ...a.topLevelNames,
  };

  /// [root] 下归 [category] 的区域，按登记顺序。
  List<StorageArea> inCategory(
    StorageCategoryId category,
    StorageRootId root,
  ) => <StorageArea>[
    for (final StorageArea a in under(root))
      if (a.category == category) a,
  ];

  static void _validate(List<StorageArea> areas) {
    final Set<String> ids = <String>{};
    final Map<String, StorageArea> paths = <String, StorageArea>{};
    final Map<String, StorageArea> topLevelOwners = <String, StorageArea>{};
    for (final StorageArea a in areas) {
      if (!ids.add(a.id)) {
        throw ArgumentError('duplicate storage area id: ${a.id}');
      }
      final List<String> segments = a.segments;
      for (final String s in segments) {
        if (s.isEmpty || s == '.' || s == '..' || s.contains(r'\')) {
          throw ArgumentError(
            'storage area ${a.id}: bad relativePath "${a.relativePath}"',
          );
        }
      }
      if (a.legacyNames.isNotEmpty && segments.length != 1) {
        throw ArgumentError(
          'storage area ${a.id}: legacyNames only apply to top-level areas',
        );
      }
      for (final String legacy in a.legacyNames) {
        if (legacy.isEmpty || legacy.contains('/') || legacy.contains(r'\')) {
          throw ArgumentError(
            'storage area ${a.id}: bad legacy name "$legacy"',
          );
        }
      }
      final String key = '${a.root.name}:${a.relativePath}';
      final StorageArea? clash = paths[key];
      if (clash != null) {
        throw ArgumentError(
          'storage areas ${clash.id} and ${a.id} both claim $key',
        );
      }
      paths[key] = a;
      if (segments.length == 1) {
        for (final String name in a.topLevelNames) {
          final String nameKey = '${a.root.name}:${name.toLowerCase()}';
          final StorageArea? owner = topLevelOwners[nameKey];
          if (owner != null) {
            throw ArgumentError(
              'storage areas ${owner.id} and ${a.id} both claim top-level '
              '"$name" under ${a.root.name}',
            );
          }
          topLevelOwners[nameKey] = a;
        }
      }
      if (a.deletabilityOverride == StorageEntryDeletability.cacheBulk &&
          a.lifecycle != StorageLifecycle.cache) {
        throw ArgumentError(
          'storage area ${a.id}: only cache areas may join bulk cache clearing',
        );
      }
    }
  }
}

/// 引擎自己派生目录的区域（app 与服务端共用，两边逐字节同形）。
enum EngineStorageArea implements StorageArea {
  /// EPUB / 漫画解压正文根 `<documents>/fushi_books`。
  epubBooks(
    id: 'epub_books',
    root: StorageRootId.documents,
    relativePath: 'fushi_books',
    legacyNames: <String>[kLegacyBooksDirectoryName],
    category: StorageCategoryId.books,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 有声书音频持久根 `<documents>/audiobooks`。
  audiobooks(
    id: 'audiobooks',
    root: StorageRootId.documents,
    relativePath: 'audiobooks',
    category: StorageCategoryId.books,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 视频封面 `<documents>/video_covers`（`video_books.cover_path` 指着，来源账本
  /// `cover_meta.json` 记着手动封面，BUG-5613：不可逐条裸删）。
  videoCovers(
    id: 'video_covers',
    root: StorageRootId.documents,
    relativePath: 'video_covers',
    category: StorageCategoryId.covers,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 视频外挂字幕副本 `<documents>/video_subtitles`。
  videoSubtitles(
    id: 'video_subtitles',
    root: StorageRootId.documents,
    relativePath: 'video_subtitles',
    category: StorageCategoryId.subtitles,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 云端 / 互联上传的视频 `<documents>/remote_videos`（app 与服务端的上传视频根）。
  remoteVideos(
    id: 'remote_videos',
    root: StorageRootId.documents,
    relativePath: 'remote_videos',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 选择器临时副本的持久落点 `<support>/imported_videos`（BUG-2863）。
  pickedVideoCopies(
    id: 'imported_videos',
    root: StorageRootId.support,
    relativePath: 'imported_videos',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 字幕生成任务根 `<support>/asr_jobs`（视频 / 音乐字幕管线、上游转录任务）。
  asrJobs(
    id: 'asr_jobs',
    root: StorageRootId.support,
    relativePath: 'asr_jobs',
    category: StorageCategoryId.subtitleJobs,
    lifecycle: StorageLifecycle.derived,
  ),

  /// 本机 OCR 模型根 `<support>/ocr_models`（各模型落在它下面的兄弟目录）。
  ocrModels(
    id: 'ocr_models',
    root: StorageRootId.support,
    relativePath: 'ocr_models',
    category: StorageCategoryId.ocrModels,
    lifecycle: StorageLifecycle.redownloadable,
  );

  const EngineStorageArea({
    required this.id,
    required this.root,
    required this.relativePath,
    required this.category,
    required this.lifecycle,
    this.legacyNames = const <String>[],
  });

  @override
  final String id;
  @override
  final StorageRootId root;
  @override
  final String relativePath;
  @override
  final List<String> legacyNames;
  @override
  final StorageCategoryId category;
  @override
  final StorageLifecycle lifecycle;

  /// 引擎区域都按 [lifecycle] 的默认可删性。
  @override
  StorageEntryDeletability? get deletabilityOverride => null;

  /// 引擎区域装的都是书库内容 / 派生物，全部算书库证据。
  @override
  bool get countsAsLibraryEvidence => true;
}
