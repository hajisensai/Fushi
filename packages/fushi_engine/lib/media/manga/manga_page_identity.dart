/// 漫画页的**身份**：整卷 OCR 任务与阅读器之间对页只认它，不认页号。
///
/// 两边的页表不是同一份：任务按 `enumerateMangaPages(书目录)` 自己枚举页图，阅读器
/// 用书的 `manga.json`。书目录里多一张不在页表里的图（封面、残留文件），任务的第 P
/// 张就是阅读器的第 P-1 页——拿裸页号互用，OCR 结果就挂到邻页上，点词查出别页的词、
/// 框也错位（反馈 -5BJ11GqOk）。页身份是「相对书目录的页图路径」，两边各自从自己
/// 的 url 算出来，同一张图恒得同一个值。
library;

import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// [url] → 页身份：相对书目录（整卷 OCR 的 `imageDirPath`，= `extractDir`）的正斜杠
/// 路径，恒以 `images/` 开头。
///
/// 同时吃两种 url：阅读器页表（`manga.json`）的存量写法——本仓导入器写的
/// `images/foo.jpg`、旧版 `.mokuro` 的裸 `foo.jpg`（阅读器按 `<书目录>/images` 解析，
/// 见 [MangaStorage.pageRelativePath]）；以及 OCR 任务的 `relativeUrl`（相对书目录，
/// 页图都在 `images/` 下）。口径与阅读器解析页图的方式一致：同一个 url，阅读器显示
/// 的是哪张图，身份就指向哪张图。
String mangaPageId(String url) =>
    '${MangaStorage.kImagesDirName}/'
    '${MangaStorage.pageRelativePath(normalizeMangaUrl(url))}';

/// [pageId] 在 [pageUrls]（某一方的页表，按页序）里的下标；不在表里为 null。
int? mangaPageIndexOf(Iterable<String> pageUrls, String pageId) {
  int index = 0;
  for (final String url in pageUrls) {
    if (mangaPageId(url) == pageId) return index;
    index++;
  }
  return null;
}

/// 把整卷 OCR 结果 [result] 按页身份对到卷的页表 [volume] 上（[alignMangaOcrResult]
/// 的产物）。
class MangaOcrAlignment {
  const MangaOcrAlignment({
    required this.payload,
    required this.matched,
    required this.dropped,
  });

  /// 页表、页序与 [volume] 完全相同的整卷结果。
  final MokuroPayload payload;

  /// 拿到了 OCR 结果的卷页数。
  final int matched;

  /// 结果里不属于卷页表的页数（书目录里的多余图），已丢弃。
  final int dropped;
}

/// 按页身份把 [result] 并进卷的页表 [volume]：页表与页序以 [volume] 为准（任务多
/// 识别的图不进页表），对上的页换成 [result] 的那一页，对不上的页保持 [volume] 原样。
/// OCR 元数据取 [result] 的，PDF 文字层版本取两者中非空的那个（文字层块本身由写盘
/// 时的 `preservePdfTextLayer` 按 url 并回）。
///
/// 一页都对不上（结果与这卷不是同一批页图）时抛 [StateError]：照旧整份替换会把
/// 别的页表写进这卷，而静默丢掉整卷结果又会让任务报「完成」却什么都没识别。
MangaOcrAlignment alignMangaOcrResult({
  required MokuroPayload volume,
  required MokuroPayload result,
}) {
  final Map<String, MokuroImage> byId = <String, MokuroImage>{};
  for (final MokuroImage page in result.images) {
    byId.putIfAbsent(mangaPageId(page.url), () => page);
  }
  int matched = 0;
  final Set<String> used = <String>{};
  final List<MokuroImage> images = <MokuroImage>[];
  for (final MokuroImage page in volume.images) {
    final String id = mangaPageId(page.url);
    final MokuroImage? recognized = byId[id];
    if (recognized == null) {
      images.add(page);
      continue;
    }
    matched++;
    used.add(id);
    images.add(recognized);
  }
  if (matched == 0 && result.images.isNotEmpty && volume.images.isNotEmpty) {
    throw StateError(
      'OCR result pages do not match the volume page table '
      '(${result.images.length} result pages, '
      '${volume.images.length} volume pages)',
    );
  }
  return MangaOcrAlignment(
    payload: MokuroPayload(
      images: images,
      ocr: result.ocr,
      pdfTextLayerVersion:
          result.pdfTextLayerVersion ?? volume.pdfTextLayerVersion,
    ),
    matched: matched,
    dropped: byId.length - used.length,
  );
}
