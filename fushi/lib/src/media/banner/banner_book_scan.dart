/// 「横幅…」面板的「书中」候选：从书自己的图里挑能当横幅的。
///
/// - 漫画：`manga.json` 自带每页的像素尺寸（OCR 产物记下的，不解码图片），横版页
///   （跨页 / 宽页）入选。整卷几百页也只是读一个 JSON。
/// - EPUB：插图表（[EpubBook.images]，阅读器 / 插图册共用的那份盘上缓存）按书序取前
///   [kBannerEpubScanLimit] 张，只读文件头量尺寸；轻小说卷首的彩页（前
///   [kBannerEpubFrontPlates] 张大图，不论横竖）与扫描窗口内的横版图入选。封面与行内
///   小图（外字、装饰符号）不进。
///
/// 两条扫描都是 isolate 入口（[scanMangaBookForBanners] / [scanEpubImagesForBanners]），
/// 由调用方经 `compute` 放到后台跑；选择判据是纯函数（[selectWideMangaPages] /
/// [selectEpubBannerImages]），单测直接喂尺寸。候选数封顶 [kBannerBookCandidateLimit]。
library;

import 'dart:io';

import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/illustration_aspect_probe.dart';

/// 横幅的目标宽高比（详情页海报面板 / 首页系列色块都按 16:9 左右铺）。
const double kBannerAspect = 16 / 9;

/// 宽高比不低于它的页 / 图算「横版」（跨页约 1.4，单页约 0.7）。
const double kBannerWideMinAspect = 1.2;

/// 「书中」候选的上限（网格里一屏多一点；更多也挑不过来）。
const int kBannerBookCandidateLimit = 24;

/// EPUB 卷首彩页：书序里前这么多张非封面大图不论横竖都给。
const int kBannerEpubFrontPlates = 6;

/// EPUB 只量书序里前这么多张图（彩页都在卷首；长篇几百张插图不必全量）。
const int kBannerEpubScanLimit = 80;

/// 图比 16:9 窄（竖图、跨页）时要让用户框一块 16:9；够宽的（在线横幅本身就是
/// 横幅形状）原样用，展示层按 cover 裁。
bool bannerNeedsCrop({required int width, required int height}) =>
    width > 0 && height > 0 && width / height < kBannerAspect - 0.01;

/// 一张「书中」候选。
class BannerBookPick {
  const BannerBookPick({
    required this.path,
    required this.width,
    required this.height,
    required this.ordinal,
    required this.isPage,
  });

  /// 图片文件绝对路径（已过书目录穿越守卫、文件存在）。
  final String path;
  final int width;
  final int height;

  /// 1 起：漫画是页号，EPUB 是书序里第几张图（标签用）。
  final int ordinal;

  /// true = 漫画页；false = EPUB 插图。
  final bool isPage;

  bool get wide => height > 0 && width / height >= kBannerWideMinAspect;
}

/// 漫画页里横版的那些（下标，书序）。尺寸缺失 / 非法的页跳过。
List<int> selectWideMangaPages(
  List<({int width, int height})> pages, {
  int limit = kBannerBookCandidateLimit,
}) {
  final List<int> out = <int>[];
  for (int i = 0; i < pages.length && out.length < limit; i++) {
    final ({int width, int height}) page = pages[i];
    if (page.width <= 0 || page.height <= 0) continue;
    if (page.width / page.height >= kBannerWideMinAspect) out.add(i);
  }
  return out;
}

/// EPUB 插图里能当横幅的（下标，书序）：跳过封面、量不出尺寸的与行内小图
/// （[isInlineSizedImage]）；前 [frontPlates] 张大图（卷首彩页）不论横竖入选，之后
/// 只要横版。
List<int> selectEpubBannerImages(
  List<({bool cover, int? width, int? height})> images, {
  int frontPlates = kBannerEpubFrontPlates,
  int limit = kBannerBookCandidateLimit,
}) {
  final List<int> out = <int>[];
  int plates = 0;
  for (int i = 0; i < images.length && out.length < limit; i++) {
    final ({bool cover, int? width, int? height}) image = images[i];
    final int w = image.width ?? 0;
    final int h = image.height ?? 0;
    if (image.cover || w <= 0 || h <= 0) continue;
    if (isInlineSizedImage((width: w, height: h))) continue;
    final bool wide = w / h >= kBannerWideMinAspect;
    if (plates < frontPlates) {
      plates++;
      out.add(i);
    } else if (wide) {
      out.add(i);
    }
  }
  return out;
}

/// isolate 入口：读漫画卷的 `manga.json`，返回横版页（文件不在 / 越界的页跳过）。
/// `manga.json` 读不出时抛 [FileSystemException] / [FormatException]。
List<BannerBookPick> scanMangaBookForBanners(
  ({String extractDir, String epubPath}) args,
) {
  final File json = File(p.join(args.extractDir, args.epubPath));
  final MokuroPayload payload = parseMangaJson(json.readAsStringSync());
  final List<MokuroImage> pages = payload.images;
  final String imagesRoot = MangaStorage.imagesDirectory(args.extractDir).path;
  final List<BannerBookPick> out = <BannerBookPick>[];
  // 先按尺寸挑出横版页，再只对入选页 stat 文件；挑的上限放宽一倍，给缺文件的页
  // 留余量，最终仍封顶 [kBannerBookCandidateLimit]。
  final List<int> wide = selectWideMangaPages(<({int width, int height})>[
    for (final MokuroImage page in pages)
      (width: page.size.width.round(), height: page.size.height.round()),
  ], limit: kBannerBookCandidateLimit * 2);
  for (final int i in wide) {
    if (out.length >= kBannerBookCandidateLimit) break;
    final String? path = MangaStorage.resolvePageFilePath(
      imagesRoot,
      MangaStorage.pageRelativePath(pages[i].url),
    );
    if (path == null) continue;
    out.add(
      BannerBookPick(
        path: path,
        width: pages[i].size.width.round(),
        height: pages[i].size.height.round(),
        ordinal: i + 1,
        isPage: true,
      ),
    );
  }
  return out;
}

/// isolate 入口：EPUB 插图（书序的解压目录相对路径 [srcs]，[cover] 同长、标出封面）
/// 只量前 [kBannerEpubScanLimit] 张的文件头，按 [selectEpubBannerImages] 挑。越出
/// 解压目录或文件不在的跳过。
List<BannerBookPick> scanEpubImagesForBanners(
  ({String extractDir, List<String> srcs, List<bool> cover}) args,
) {
  final String root = p.canonicalize(args.extractDir);
  final List<String> paths = <String>[];
  final List<bool> covers = <bool>[];
  final Set<String> seen = <String>{};
  for (int i = 0; i < args.srcs.length; i++) {
    if (paths.length >= kBannerEpubScanLimit) break;
    final String joined = p.normalize(p.join(args.extractDir, args.srcs[i]));
    if (!p.isWithin(root, p.canonicalize(joined))) continue;
    // 同一张图被多章引用（封面页再引一次封面）只算第一次。
    if (!seen.add(p.canonicalize(joined))) continue;
    paths.add(joined);
    covers.add(args.cover[i]);
  }
  final Map<String, ImagePixelSize> sizes = probeIllustrationSizes(paths);
  final List<int> picked =
      selectEpubBannerImages(<({bool cover, int? width, int? height})>[
        for (int i = 0; i < paths.length; i++)
          (
            cover: covers[i],
            width: sizes[paths[i]]?.width,
            height: sizes[paths[i]]?.height,
          ),
      ]);
  return <BannerBookPick>[
    for (final int i in picked)
      BannerBookPick(
        path: paths[i],
        width: sizes[paths[i]]!.width,
        height: sizes[paths[i]]!.height,
        ordinal: i + 1,
        isPage: false,
      ),
  ];
}
