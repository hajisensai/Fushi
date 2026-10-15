/// 漫画扫描根的**卷归组**规则：一棵目录树里哪些是 `.mokuro` 卷、哪些目录该当作
/// 一卷纯页图导入。
///
/// 这是 app 源库扫描（`SourceLibraryScanner`）与无头服务端库扫描
/// （`fushi_server` 的 `LibraryScanner`）共用的唯一口径；两边各写一遍的话，
/// 同一个目录在手机上算两卷、在服务端算一卷，客户端看到的书架就不再是同一个。
///
/// 三条规则（与 app 手动「选择漫画文件夹」的语义一致）：
/// - 根目录直接有页图：根本身是一卷；
/// - 根目录没有页图：每个含页图的**直接**子目录是一卷，因此选择这些卷的上级目录
///   也能批量导入；更深的章节/图片子目录仍归属于这个直接子目录，不会拆成多本；
/// - 候选目录与某个 `.mokuro` 所在目录存在祖先/后代关系时，以 manifest 为准，
///   不再生成裸图卷——两种导入器都递归读页图，混用会把同一批图片重复消费。
///
/// 「是页图」的判据是 [kMangaImageExtensions]（= `kImageExtensionsBase`），
/// 与导入器 `enumerateMangaPages` 同源；这里只决定**哪个目录是一卷**，
/// 目录里具体有哪些页仍由导入器枚举。
library;

import 'dart:io';

import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;
import 'package:path/path.dart' as p;

/// `.mokuro` 卷 manifest 的扩展名（含点、小写）。
const String kMokuroExtension = '.mokuro';

/// 一次归组的结果（纯数据）。
class MangaFolderPlan {
  const MangaFolderPlan({
    required this.mokuroPaths,
    required this.imageFolders,
  });

  /// 扫描根下所有 `.mokuro` 文件的完整路径，按小写字典序。
  final List<String> mokuroPaths;

  /// 应各自作为一卷导入的纯页图目录（完整路径），按小写字典序；标题惯例取
  /// 目录 basename。已被某个 `.mokuro` 覆盖的目录不在其中。
  final List<String> imageFolders;

  bool get isEmpty => mokuroPaths.isEmpty && imageFolders.isEmpty;
}

/// 纯函数：把已枚举的文件列表归组成卷。无 IO。
///
/// [filePaths] 是 [rootPath] 之下**文件**（不含目录条目）的完整路径；路径命名
/// 空间与 [rootPath] 一致即可（都是绝对路径、或都相对同一基准），不落在根之下的
/// 条目被忽略。
///
/// [context] 是这批路径的路径语义，缺省为宿主平台（本地目录）。网络来源的路径
/// 是正斜杠的远端路径 / WebDAV 的 `https://` href，必须传 [p.url]：用宿主语义在
/// Windows 上 normalize 会把分隔符换成反斜杠、把 URL 拆坏，归出来的卷目录就再也
/// 对不上远端条目。
MangaFolderPlan planMangaFolders({
  required String rootPath,
  required Iterable<String> filePaths,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final String root = ctx.normalize(rootPath);
  bool rootHasImages = false;
  final Set<String> childFolders = <String>{};
  final List<String> mokuroPaths = <String>[];
  for (final String path in filePaths) {
    final String ext = ctx.extension(path).toLowerCase();
    if (ext == kMokuroExtension) {
      mokuroPaths.add(path);
      continue;
    }
    if (!kMangaImageExtensions.contains(ext)) continue;
    final String relative = ctx.relative(ctx.normalize(path), from: root);
    final List<String> segments = ctx.split(relative);
    if (segments.isEmpty || segments.first == '..') continue;
    if (segments.length == 1) {
      rootHasImages = true;
    } else {
      childFolders.add(ctx.join(root, segments.first));
    }
  }
  mokuroPaths.sort(_compareIgnoreCase);

  final List<String> candidates = rootHasImages
      ? <String>[root]
      : (childFolders.toList()..sort(_compareIgnoreCase));
  final List<String> imageFolders = <String>[];
  for (final String candidate in candidates) {
    final bool claimedByMokuro = mokuroPaths.any((String mokuroPath) {
      final String mokuroDir = ctx.dirname(ctx.normalize(mokuroPath));
      return ctx.equals(mokuroDir, candidate) ||
          ctx.isWithin(mokuroDir, candidate) ||
          ctx.isWithin(candidate, mokuroDir);
    });
    if (!claimedByMokuro) imageFolders.add(candidate);
  }
  return MangaFolderPlan(mokuroPaths: mokuroPaths, imageFolders: imageFolders);
}

/// `dart:io` 便捷入口：递归枚举 [root] 下的文件（不跟符号链接；无权限/瞬时 IO
/// 的子目录整个跳过，不让整次归组失败）后交给 [planMangaFolders]。
MangaFolderPlan planMangaFoldersInDirectory(Directory root) {
  final List<String> files = <String>[];
  void walk(Directory dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final FileSystemEntity entity in entries) {
      if (entity is File) {
        files.add(entity.path);
      } else if (entity is Directory) {
        walk(entity);
      }
    }
  }

  walk(root);
  return planMangaFolders(rootPath: root.path, filePaths: files);
}

int _compareIgnoreCase(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());
