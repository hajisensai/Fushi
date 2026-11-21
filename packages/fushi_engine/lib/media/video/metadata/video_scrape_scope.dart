import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show isLocalVideoFilePath;
import 'package:path/path.dart' as p;

// ── 视频刮削的「范围」：已登记的本机来源 + 无来源本机视频 ───────────────────────
//
// 刮削链（计划器 → 协调器 → sidecar）按「范围」逐个跑：每个已登记的本机视频来源是
// 一个范围，`video_books.source_id` 为 NULL 的本机视频合起来是另一个范围（拍板台
// gtpgyff3l7-oneshot-scrape 方案 b）。后者没有来源行：「导入文件夹（仅此一次）」扫完
// 删掉临时来源行后、手动导入的单文件、来源被移除后留下的视频都落在这里，表结构本就
// 允许这些列为 NULL。
//
// 无来源范围在内存里用 [sourcelessLocalVideoScrapeScope] 这条**不落库**的行表示，只为
// 让刮削链沿用同一套「按范围」的签名；凡是往库里写来源 id 的地方一律经
// [persistedScrapeSourceId] 换成 NULL，库里永远不会出现这个 id。

/// 无来源范围的内存 id。SQLite 自增主键从 1 起，0 不会与任何真实来源撞上。
const int kSourcelessLocalVideoScrapeScopeId = 0;

/// 无来源本机视频的刮削范围（不落库）。`rootPath` 为空：这个范围没有统一的扫描根，
/// sidecar 边界按作品现算（[videoScrapeRootFor]）。
const SourceLibraryRow sourcelessLocalVideoScrapeScope = SourceLibraryRow(
  id: kSourcelessLocalVideoScrapeScopeId,
  label: '',
  mediaKind: 'video',
  transport: 'local',
  rootPath: '',
  mediaCount: 0,
  recursive: true,
  videoGroupingMode: 'series',
  isPrivate: false,
  autoScan: false,
  sortOrder: 0,
  createdAt: 0,
);

/// [source] 是不是无来源范围（[sourcelessLocalVideoScrapeScope]）。
bool isSourcelessVideoScrapeScope(SourceLibraryRow source) =>
    source.id == kSourcelessLocalVideoScrapeScopeId;

/// 往库里写「这次刮削属于哪个来源」时用的值：无来源范围写 NULL。
int? persistedScrapeSourceId(SourceLibraryRow source) =>
    isSourcelessVideoScrapeScope(source) ? null : source.id;

/// [source] 是不是「导入文件夹（仅此一次）」的临时来源行（扫完即删，见
/// [kSourceConfigOneShotKey]）。
///
/// 刮削链一律不对它立项：临时行随时会被删，对它立项的批次在行删掉后写
/// `video_sidecar_artifacts` 会撞外键（FK 787）。它导入的视频在行删掉后落进无来源
/// 范围，由那条范围照常补刮。
bool isOneShotImportSource(SourceLibraryRow source) =>
    decodeSourceConfig(source.configJson)[kSourceConfigOneShotKey] == true;

/// [source] 是不是一个可刮削的范围：本机视频来源（非临时行），或无来源范围。
bool isVideoScrapeScope(SourceLibraryRow source) =>
    source.mediaKind == 'video' &&
    source.transport == 'local' &&
    !isOneShotImportSource(source);

/// [book] 是否落在范围 [scope] 里。
///
/// - 来源范围：`book.sourceId == scope.id`；
/// - 无来源范围：`sourceId` 为 NULL、`videoPath` 是本机绝对路径（远端流 / 媒体服务器 /
///   粘贴 URL 的视频没有本机文件可刮、可写 sidecar），且最近一次导入不是目录分组
///   模式（目录模式按导入目录组织，不按作品识别，同 [VideoBooks.videoGroupingMode]
///   对来源的语义）。
bool videoBookInScrapeScope(VideoBookRow book, SourceLibraryRow scope) {
  if (!isSourcelessVideoScrapeScope(scope)) return book.sourceId == scope.id;
  return book.sourceId == null &&
      book.videoGroupingMode != 'folder' &&
      isLocalVideoFilePath(book.videoPath);
}

/// 本机所有可刮削范围：已登记的本机视频来源（排除临时行），末尾追加无来源范围。
///
/// 无来源范围恒在：没有无来源视频时计划器对它产出空计划，不必在这里先扫一遍。
Future<List<SourceLibraryRow>> localVideoScrapeScopes(
  FushiDatabase database,
) async => <SourceLibraryRow>[
  for (final SourceLibraryRow source in await database.getMediaSourcesByKind(
    'video',
  ))
    if (isVideoScrapeScope(source)) source,
  sourcelessLocalVideoScrapeScope,
];

/// 刮削 [scope] 里的一部作品（成员 [memberPaths]）时，sidecar 写入与 NFO 读取的
/// 边界根目录。
///
/// 来源范围就是来源的扫描根。无来源范围没有扫描根，取首个成员所在盘的根（与把整
/// 块盘登记成来源同一形态）：写哪里由 sidecar 解析器按作品目录决定，「作品目录里
/// 有没有混着别的作品」靠调用方传入的完整已知视频集合判定
/// （[videoScrapeKnownPathsFor]），所以边界放宽不会让 tvshow.nfo 写进混装目录。
String videoScrapeRootFor(
  SourceLibraryRow scope,
  Iterable<String> memberPaths,
) {
  if (!isSourcelessVideoScrapeScope(scope)) return scope.rootPath;
  final String? first = memberPaths.firstOrNull;
  if (first == null) return '';
  return p.rootPrefix(p.normalize(p.absolute(first)));
}

/// sidecar 解析器要的「已知视频集合」（用来证明作品目录没混进别的作品）。
///
/// 来源范围是该来源扫到的全部视频；无来源范围的边界是整块盘，只拿无来源视频不足以
/// 证明专属目录，所以给库里全部本机视频。
List<String> videoScrapeKnownPathsFor(
  SourceLibraryRow scope,
  Iterable<VideoBookRow> allBooks,
) => <String>[
  for (final VideoBookRow book in allBooks)
    if (isSourcelessVideoScrapeScope(scope)
        ? isLocalVideoFilePath(book.videoPath)
        : book.sourceId == scope.id)
      book.videoPath,
];
