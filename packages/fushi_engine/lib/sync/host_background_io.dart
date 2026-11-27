/// 互联 host 路由上的同步文件 IO 的唯一去处：一次性后台 isolate（BUG-5606）。
///
/// host 的路由处理代码（`fushi_sync_server*`、`local_library_host_service*`）禁止同步
/// 文件 IO（守卫 `host_route_sync_io_guard_test.dart`）：app 当 host 时它们跑在 UI
/// isolate 上。确实只能同步做的探测（复用的判据函数本身是同步的）集中在本文件，
/// 每个入口都经 `Isolate.run` 进后台；入口必须是顶层函数，闭包只捕获显式参数。
///
/// ## 书单探测
///
/// 互联 host 书单（`/api/library/books`）的逐书文件探测，整批放进一次性 isolate。
///
/// 每本书要问好几次盘：封面候选逐个 `existsSync`、EPUB 根目录与
/// `META-INF/container.xml`、漫画根 `manga.json` 整份读 + 解析 + 逐页核对、PDF 原件
/// 大小、章目录列举。旧实现在 host 所在 isolate 上同步做——app 当 host 时那就是 UI
/// isolate，书库一大（或书目录在网络盘上，BUG-3756）界面就跟着冻住。这里把一张书单
/// 的全部探测交给一个后台 isolate 做完，只交回每本书几个布尔与封面路径。
///
/// 判据与旧实现逐字同源（调用的就是同一批函数），所以清单内容不变。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart'
    show hasAnyChapterDirSync;
import 'package:fushi_engine/sync/epub_repackage.dart'
    show resolveExtractedEpubRoot;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show resolveEpubCoverFilePath;
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show MokuroPayload, parseMangaJson;
import 'package:fushi_engine/sync/manga_sync_package.dart'
    show hasExportableMangaContent, readExportableMangaPayload;
import 'package:fushi_engine/sync/online_manga_host_reader.dart'
    show pruneOnlineMangaPageCache;
import 'package:fushi_engine/sync/online_novel_book.dart'
    show isLnReaderOnlineBookMetadata;
import 'package:fushi_engine/sync/pdf_sync_package.dart'
    show hasExportablePdfFile;

/// 一本书的探测输入：只带探测要用的几列（不把整行连章表一起拷进后台 isolate）。
final class HostBookProbeInput {
  HostBookProbeInput.fromRow(EpubBookRow row)
    : format = row.format,
      extractDir = row.extractDir,
      coverPath = row.coverPath,
      epubPath = row.epubPath,
      sourceMetadata = row.sourceMetadata;

  final String format;
  final String extractDir;
  final String? coverPath;
  final String epubPath;
  final String? sourceMetadata;
}

/// 一本书的探测结果（字段语义见 `RemoteBookInfo` 同名字段）。
typedef HostBookProbe = ({
  /// 盘上存在的封面绝对路径；没有为 null。
  String? coverPath,

  /// EPUB 内容树可导出（格式是 EPUB、不是在线小说占位书、有 EPUB 根目录）。
  bool hasContent,

  /// 单卷漫画内容完整可导出。
  bool hasMangaContent,

  /// PDF 原件在盘上且非空。
  bool hasPdfContent,

  /// 漫画书目录下至少有一个已下载的章目录（清单级廉价判据）。
  bool hasMangaChapterDirs,
});

/// 在一次性后台 isolate 里探测 [inputs] 的每一本书，按输入顺序交回结果。
Future<List<HostBookProbe>> probeHostBooks(List<HostBookProbeInput> inputs) {
  if (inputs.isEmpty) return Future<List<HostBookProbe>>.value(const []);
  return Isolate.run(
    () => <HostBookProbe>[for (final HostBookProbeInput i in inputs) _probe(i)],
    debugName: 'host-book-probes',
  );
}

HostBookProbe _probe(HostBookProbeInput i) {
  final BookFormat format = BookFormat.parseOrEpub(i.format);
  return (
    // EPUB 行的 coverPath 是 EPUB 内部相对 href，必须拼 extractDir 才是磁盘真
    // 路径；直接按绝对路径判存在恒 false → 远端书卡没封面（#4）。
    coverPath: resolveEpubCoverFilePath(
      extractDir: i.extractDir,
      coverPath: i.coverPath,
    ),
    hasContent:
        format == BookFormat.epub &&
        !isLnReaderOnlineBookMetadata(i.sourceMetadata) &&
        resolveExtractedEpubRoot(i.extractDir) != null,
    hasMangaContent:
        format == BookFormat.manga && hasExportableMangaContent(i.extractDir),
    hasPdfContent: hasExportablePdfFile(
      format: i.format,
      extractDir: i.extractDir,
      epubPath: i.epubPath,
    ),
    hasMangaChapterDirs:
        format == BookFormat.manga &&
        i.extractDir.isNotEmpty &&
        hasAnyChapterDirSync(i.extractDir),
  );
}

// ── 漫画 ──────────────────────────────────────────────────────────────────

/// 单卷漫画的判据与页表（`manga.json` 读 + 解析 + 逐页核对）：[rootMarker] = 行里
/// 记的 `manga.json` 就是根判据文件（常态，只读一遍），否则判完再读 [jsonPath]。
Future<MokuroPayload?> readExportableVolumeInIsolate({
  required String extractDir,
  required String jsonPath,
  required bool rootMarker,
}) => Isolate.run(() {
  if (rootMarker) return readExportableMangaPayload(extractDir);
  if (!hasExportableMangaContent(extractDir)) return null;
  return parseMangaJson(File(jsonPath).readAsStringSync());
}, debugName: 'manga-volume-payload');

/// 现取页缓存的按章清理（整棵树 stat / 删除）。
Future<void> pruneOnlineMangaPageCacheInIsolate(
  String rootPath,
  String keepPath,
) => Isolate.run(
  () =>
      pruneOnlineMangaPageCache(Directory(rootPath), keep: Directory(keepPath)),
  debugName: 'prune-online-manga-pages',
);
