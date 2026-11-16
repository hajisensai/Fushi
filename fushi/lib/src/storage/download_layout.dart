import 'package:path/path.dart' as p;

import 'package:fushi_engine/epub/epub_storage.dart';

/// 下载根下各个域的子目录名。**目录名是磁盘持久化名，冻结。**
///
/// 一个总下载根（偏好 `download_save_root`，空串 = 默认根
/// `<documents>/anime_downloads/content`），所有「下载类」内容落 `<下载根>/<域>/`：
///
/// - torrent：`<下载根>/<分类>`（分类默认 `fushi`，用户可改）——TODO-1961 起就是
///   这个布局，存量任务的 savePath 与 fast-resume 都指向它，**不改**；
/// - 发现页下载：`<下载根>/discovery/<媒体类型>`（既有布局，不改）；
/// - 在线漫画（Mihon / 网页 / Kavita / 互联 / 旧 Aidoku 书架条目）：
///   `<下载根>/manga/<bookKey>`；
/// - 在线音源插件曲目：`<下载根>/music/<插件>/<专辑>/`。
///
/// 刻意不进下载根的：浏览器下载（落系统公共「下载」目录，用户在 app 外直接取用；
/// 默认下载根是 app 私有目录，搬进去反而让 Android 用户找不到文件）、在线小说
/// （下载即打包成普通 EPUB 走书籍导入，是书架里的书，不是下载目录）、远端 / 在线
/// 视频副本 `remote_videos`（续传清单、封面、光盘与扩展源剧集混住一棵树，单独改）。
const String kDownloadMangaDirName = 'manga';

/// 在线音源插件曲目的下载域目录名（见 [kDownloadMangaDirName]）。
const String kDownloadMusicDirName = 'music';

/// 发现页下载的域目录名（既有布局）。
const String kDownloadDiscoveryDirName = 'discovery';

/// 改下载根时可以把旧根内容一起搬走的域。
///
/// torrent 不在内：做种中的任务由引擎持有句柄，搬文件会掐断做种（TODO-1961 的
/// 既有语义是「旧根降级为历史根、旧任务留在原地」）。发现页下载只是导入前的暂存，
/// 在飞任务的落点在内存里，同样不搬。
const List<String> kMigratableDownloadDomains = <String>[
  kDownloadMangaDirName,
  kDownloadMusicDirName,
];

/// 一个下载根的派生路径（纯路径，零 IO）。
///
/// [legacyRoots] 是改目录前用过的根（含默认根）：用户改根时选了「只用于新下载」，
/// 旧根里保留着删书时留下的漫画目录，重新入库扫描要把它们算上。
class DownloadLayout {
  /// 规范化构造：丢空串、去重、剔除与 [root] 相同的旧根。
  factory DownloadLayout({
    required String root,
    Iterable<String> legacyRoots = const <String>[],
  }) {
    final String normalizedRoot = p.normalize(root.trim());
    final List<String> legacy = <String>[];
    for (final String raw in legacyRoots) {
      if (raw.trim().isEmpty) continue;
      final String normalized = p.normalize(raw.trim());
      if (p.equals(normalized, normalizedRoot)) continue;
      if (legacy.any((String kept) => p.equals(kept, normalized))) continue;
      legacy.add(normalized);
    }
    return DownloadLayout._(normalizedRoot, List<String>.unmodifiable(legacy));
  }

  const DownloadLayout._(this.root, this.legacyRoots);

  /// 当前下载根（新下载的唯一写入根）。
  final String root;

  /// 历史根（只读：认领旧位置、重新入库扫描）。
  final List<String> legacyRoots;

  /// 当前根在前的全部根。
  List<String> get allRoots => <String>[root, ...legacyRoots];

  /// [root] 下某个域的目录。
  static String domainPath(String root, String domain) => p.join(root, domain);

  /// 在线漫画域 `<下载根>/manga`。
  String get mangaRoot => domainPath(root, kDownloadMangaDirName);

  /// 一部在线漫画的书目录 `<下载根>/manga/<bookKey>`。
  String mangaBookPath(String bookKey) => p.join(mangaRoot, bookKey);

  /// 在线音源插件下载域 `<下载根>/music`。
  String get musicRoot => domainPath(root, kDownloadMusicDirName);

  /// 发现页下载落点 `<下载根>/discovery/<kind>`。
  String discoveryPath(String kind) =>
      p.join(domainPath(root, kDownloadDiscoveryDirName), kind);

  /// 全部根下的在线漫画域（重新入库扫描用）。
  List<String> get allMangaRoots => <String>[
    for (final String r in allRoots) domainPath(r, kDownloadMangaDirName),
  ];

  /// [extractDir] 是否已是**某个**下载根下这部漫画的规范书目录
  /// `<任一下载根>/manga/<bookKey>`。是 → 不需要（也不应该）搬家。
  ///
  /// 按路径形状判，不要求根在 [allRoots] 里：用户自选的旧根可能已被挤出历史根
  /// 列表（上限 8 个），备份恢复 / 换机后行里也可能是别处的下载根；只要它已经是
  /// 下载布局，就说明是用户（或一次成功的迁移）把它放在那里的，不该在打开时被
  /// 偷偷搬走。存量旧位置（`fushi_books/<bookKey>`、`<运行时根>/library/<bookKey>`）
  /// 的父目录名都不是 `manga`，不会被误认。
  static bool isMangaBookDirectory(String extractDir, String bookKey) {
    if (extractDir.trim().isEmpty || bookKey.isEmpty) return false;
    final String normalized = p.normalize(extractDir);
    return p.basename(normalized) == bookKey &&
        p.basename(p.dirname(normalized)) == kDownloadMangaDirName;
  }
}

/// 进程内「当前下载根」的唯一取值口。
///
/// 下载根是偏好（`AppModel` 持有），而它的消费方（在线漫画书架服务、音乐插件下载）
/// 有的在 AppModel 起来之前就会被单测 / 临时实例构造出来。AppModel 初始化时
/// [install] 真正的解析器；没装（单测、极早期）时退回默认根，与「用户没改过目录」
/// 的行为逐字节一致。
abstract final class DownloadRoot {
  static Future<DownloadLayout> Function()? _resolver;

  /// 装上解析器（AppModel 初始化时调一次；测试可装假根）。
  static void install(Future<DownloadLayout> Function()? resolver) {
    _resolver = resolver;
  }

  /// 默认下载根 `<documents>/anime_downloads/content`。
  ///
  /// 与 TODO-1961 起的 torrent 默认根逐字节一致（存量任务的 savePath 都指向它，
  /// **不能改**）。documents 根取自 [EpubStorage.baseDirectory] 的父目录——生产上
  /// 两者同一个 documents 根（都经 `AppPaths`）；单测用
  /// `EpubStorage.debugBaseDirectoryOverride` 把书库根指到临时目录时，默认下载根
  /// 也就随之落在同一个临时根下，不会去碰 path_provider。
  static Future<String> defaultRoot() async {
    final String booksBase = await EpubStorage.baseDirectory();
    return p.join(p.dirname(booksBase), 'anime_downloads', 'content');
  }

  /// 当前生效的下载布局。
  static Future<DownloadLayout> current() async {
    final Future<DownloadLayout> Function()? resolver = _resolver;
    if (resolver != null) return resolver();
    return DownloadLayout(root: await defaultRoot());
  }
}
