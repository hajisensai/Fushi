/// 漫画整卷 OCR 的目录任务核心：枚举页图（自然序、含一层子目录）→
/// [MangaOcrPipeline]（检测→排序→识别，逐页断点缓存落盘）→
/// 组 [MokuroPayload] 写 `<目录>/manga_ocr_out/manga.json`。
///
/// 本层与 isolate / 平台无关：检测器/识别器经窄接口注入，测试用 fake 直接
/// 在进程内跑；生产由 `manga_ocr_service_impl.dart` 包在后台 isolate 里调用。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/media_extensions.dart';
import 'package:hibiki/src/ocr/manga_ocr_pipeline.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';

/// OCR 产物目录名（在被扫描目录内，枚举时必须排除自己）。
const String kMangaOcrOutDirName = 'manga_ocr_out';

/// 逐页断点缓存子目录名（`manga_ocr_out/_pages/`）。
const String kMangaOcrPagesCacheDirName = '_pages';

/// Separates local ONNX cache entries from network/CLI engines.
// v2 bakes EXIF orientation before detection. v1 coordinates were measured
// against the encoded pixel matrix while Chromium displayed the oriented page,
// so portrait pages with orientation metadata had a shifted lookup layer.
const String kLocalMangaOcrEngineSignature = 'local-onnx-v2-oriented';

/// 产物文件名（`manga_ocr_out/manga.json`）。
const String kMangaOcrOutputFileName = 'manga.json';

/// 页图扩展名白名单（小写比较）＝图片扩展名基集，与漫画导入的
/// `kMangaImageExtensions`（manga_importer.dart）同源对齐。
///
/// BUG-1121：此前这里手写整表、比导入白名单少 `.bmp` / `.gif`——导入能收的
/// bmp 漫画整卷 OCR 时 bmp 页被静默跳过、产物 manga.json 缺页无任何提示。
/// 解码端非瓶颈：[decodeMangaPageFile] 走 `img.decodeImage` 内容嗅探，
/// 本就支持这两种格式。
const Set<String> kMangaOcrImageExtensions = kImageExtensionsBase;

/// 一张待 OCR 的页图：磁盘文件 + manga.json 用的正斜杠相对 url。
class MangaOcrPageFile {
  const MangaOcrPageFile({required this.file, required this.relativeUrl});

  final File file;

  /// 相对被扫描目录的正斜杠路径（`p001.jpg` / `vol1/p001.jpg`）。
  final String relativeUrl;
}

/// 自然序比较：数字段按数值比、其余按（不区分大小写的）字典序，
/// 让 `p2.jpg < p10.jpg`（纯字典序会排反）。
int naturalCompare(String a, String b) {
  final String la = a.toLowerCase();
  final String lb = b.toLowerCase();
  int i = 0;
  int j = 0;
  while (i < la.length && j < lb.length) {
    final int ca = la.codeUnitAt(i);
    final int cb = lb.codeUnitAt(j);
    final bool da = _isDigit(ca);
    final bool db = _isDigit(cb);
    if (da && db) {
      // 各自吃完整个数字段，按数值比较（等值时短的在前，保持稳定）。
      final int si = i;
      final int sj = j;
      while (i < la.length && _isDigit(la.codeUnitAt(i))) {
        i++;
      }
      while (j < lb.length && _isDigit(lb.codeUnitAt(j))) {
        j++;
      }
      final String na = la.substring(si, i).replaceFirst(RegExp('^0+'), '');
      final String nb = lb.substring(sj, j).replaceFirst(RegExp('^0+'), '');
      if (na.length != nb.length) {
        return na.length - nb.length;
      }
      final int cmp = na.compareTo(nb);
      if (cmp != 0) {
        return cmp;
      }
      // 数值相等（如 001 vs 1）：位数少的在前，保证全序稳定。
      if ((i - si) != (j - sj)) {
        return (i - si) - (j - sj);
      }
    } else {
      if (ca != cb) {
        return ca - cb;
      }
      i++;
      j++;
    }
  }
  return (la.length - i) - (lb.length - j);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// 枚举 [root] 下的页图：顶层文件 + **一层**子目录内的文件（更深不递归），
/// 排除 [kMangaOcrOutDirName] 产物目录，按相对路径自然序排序。
List<MangaOcrPageFile> enumerateMangaPages(Directory root) {
  final List<MangaOcrPageFile> pages = <MangaOcrPageFile>[];
  void addFile(File file) {
    final String ext = p.extension(file.path).toLowerCase();
    if (!kMangaOcrImageExtensions.contains(ext)) {
      return;
    }
    final String relative = p.relative(file.path, from: root.path);
    pages.add(
      MangaOcrPageFile(file: file, relativeUrl: normalizeMangaUrl(relative)),
    );
  }

  for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
    if (entity is File) {
      addFile(entity);
    } else if (entity is Directory) {
      if (p.basename(entity.path) == kMangaOcrOutDirName) {
        continue;
      }
      for (final FileSystemEntity child
          in entity.listSync(followLinks: false)) {
        if (child is File) {
          addFile(child);
        }
      }
    }
  }
  pages.sort((MangaOcrPageFile a, MangaOcrPageFile b) =>
      naturalCompare(a.relativeUrl, b.relativeUrl));
  return pages;
}

/// 页缓存文件名：相对 url 的 `/` 折叠成 `__`（一层子目录不会撞名，除非原名里
/// 本来就带 `__`——那种病态输入两页同名时后写覆盖，属可接受权衡）。
String ocrPageCacheFileName(String relativeUrl) =>
    '${relativeUrl.replaceAll('/', '__')}.json';

/// [OcrPageCache] 的文件实现：`<cacheDir>/<页名>.json`，一页一文件。
/// 键按**页名**而非页号——目录内容变化（增删页）后页号漂移，页名缓存仍能命中。
class MangaOcrFilePageCache implements OcrPageCache {
  MangaOcrFilePageCache({
    required this.cacheDir,
    required this.pageNames,
    required this.pageFiles,
  }) : assert(pageNames.length == pageFiles.length);

  final Directory cacheDir;

  /// 与当前枚举顺序对齐的相对 url 列表（pageIndex → 页名）。
  final List<String> pageNames;
  final List<File> pageFiles;

  File _fileFor(int pageIndex) =>
      File(p.join(cacheDir.path, ocrPageCacheFileName(pageNames[pageIndex])));

  @override
  Future<OcrPageResult?> read(String bookId, int pageIndex) async {
    if (pageIndex < 0 || pageIndex >= pageNames.length) {
      return null;
    }
    final File file = _fileFor(pageIndex);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final FileStat stat = await pageFiles[pageIndex].stat();
      if (json['source_path'] != pageNames[pageIndex] ||
          json['source_size'] != stat.size ||
          json['source_modified_ms'] != stat.modified.millisecondsSinceEpoch) {
        return null;
      }
      final Object? rawResult = json['result'];
      if (rawResult is! Map<String, dynamic>) {
        return null;
      }
      // 缓存里的 pageIndex 是写入时的页号；目录变化后以当前页号为准。
      final OcrPageResult parsed = OcrPageResult.fromJson(rawResult);
      return OcrPageResult(
        pageIndex: pageIndex,
        imageWidth: parsed.imageWidth,
        imageHeight: parsed.imageHeight,
        blocks: parsed.blocks,
      );
    } catch (_) {
      // 损坏缓存当 miss（该页重跑覆盖写）。
      return null;
    }
  }

  @override
  Future<void> write(String bookId, OcrPageResult result) async {
    if (result.pageIndex < 0 || result.pageIndex >= pageNames.length) {
      return;
    }
    await cacheDir.create(recursive: true);
    final FileStat stat = await pageFiles[result.pageIndex].stat();
    final File target = _fileFor(result.pageIndex);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'source_path': pageNames[result.pageIndex],
        'source_size': stat.size,
        'source_modified_ms': stat.modified.millisecondsSinceEpoch,
        'result': result.toJson(),
      }),
      flush: true,
    );
    if (target.existsSync()) {
      await target.delete();
    }
    await temporary.rename(target.path);
  }
}

/// 估算 mokuro `font_size`（像素）：`sqrt(框面积 / 字符数)`——把框视为
/// 字符网格的经典估计，横竖排通用。无字符或零面积返回 0（覆盖层渲染端已有
/// 非零兜底，ERRATA M1）。
double estimateMangaFontSize(OcrBlock block) {
  final int charCount =
      block.lines.fold<int>(0, (int acc, String line) => acc + line.length);
  if (charCount <= 0 || block.box.area <= 0) {
    return 0;
  }
  return math.sqrt(block.box.area / charCount);
}

/// 把逐页 OCR 结果组装成 [MokuroPayload]（url = 原图相对路径，尺寸取自解码
/// 时记录的像素值，块按阅读顺序赋 zIndex）。[pages] 与 [results] 必须等长且
/// 按页序对齐。
MokuroPayload buildMangaPayloadFromResults(
  List<MangaOcrPageFile> pages,
  List<OcrPageResult> results,
) {
  assert(pages.length == results.length);
  final List<MokuroImage> images = <MokuroImage>[];
  for (int i = 0; i < pages.length && i < results.length; i++) {
    final OcrPageResult result = results[i];
    final List<MokuroBlock> blocks = <MokuroBlock>[];
    for (int b = 0; b < result.blocks.length; b++) {
      final OcrBlock block = result.blocks[b];
      blocks.add(MokuroBlock(
        rectangle: Rect.fromLTRB(
          block.box.left,
          block.box.top,
          block.box.right,
          block.box.bottom,
        ),
        // Re-evaluate cached local blocks so pages produced by the older,
        // overly strict 1.5 ratio threshold gain queryable vertical regions
        // without rerunning OCR.
        isVertical: block.vertical || isVerticalBlock(block.box),
        fontSize: estimateMangaFontSize(block),
        zIndex: b,
        lines: block.lines,
      ));
    }
    images.add(MokuroImage(
      url: pages[i].relativeUrl,
      size: Size(
        result.imageWidth.toDouble(),
        result.imageHeight.toDouble(),
      ),
      blocks: blocks,
    ));
  }
  return MokuroPayload(images: images);
}

/// 默认页解码：读文件字节 + `package:image` 自动识别格式。
Future<img.Image> decodeMangaPageFile(File file) async {
  final img.Image? decoded = img.decodeImage(await file.readAsBytes());
  if (decoded == null) {
    throw StateError('failed to decode image: ${file.path}');
  }
  // Browser image rendering honors EXIF orientation. OCR must use the same
  // oriented pixel space, otherwise the percentage overlay and click target
  // are rotated/translated relative to the visible page.
  return img.bakeOrientation(decoded);
}

/// 跑整卷目录任务，返回产出的 `manga.json` 绝对路径。
///
/// - 逐页断点缓存落 `<imageDirPath>/manga_ocr_out/_pages/<页名>.json`
///   （[MangaOcrFilePageCache]），重跑只补缺页。
/// - [cancelToken] 置位后在页/块边界抛 [OcrCancelledException]；已完成页
///   缓存保留。
/// - [onProgress] 逐页回调（含缓存命中页）。
/// - [decodePage] 可注入（测试免真图解码）。
Future<String> runMangaOcrFolderJob({
  required String imageDirPath,
  required OcrDetector detector,
  required OcrRecognizer recognizer,
  OcrCancelToken? cancelToken,
  OcrProgressCallback? onProgress,
  Future<img.Image> Function(File file)? decodePage,
}) async {
  final Directory root = Directory(imageDirPath);
  if (!root.existsSync()) {
    throw ArgumentError('image directory does not exist: $imageDirPath');
  }
  final List<MangaOcrPageFile> pages = enumerateMangaPages(root);
  if (pages.isEmpty) {
    throw StateError('no images found in $imageDirPath');
  }

  final Directory outDir = Directory(p.join(imageDirPath, kMangaOcrOutDirName));
  final Directory cacheDir = Directory(
    p.join(
      outDir.path,
      kMangaOcrPagesCacheDirName,
      kLocalMangaOcrEngineSignature,
    ),
  );
  await cacheDir.create(recursive: true);

  final MangaOcrFilePageCache cache = MangaOcrFilePageCache(
    cacheDir: cacheDir,
    pageNames: <String>[
      for (final MangaOcrPageFile page in pages) page.relativeUrl
    ],
    pageFiles: <File>[for (final MangaOcrPageFile page in pages) page.file],
  );
  final MangaOcrPipeline pipeline = MangaOcrPipeline(
    detector: detector,
    recognizer: recognizer,
    cache: cache,
  );
  final Future<img.Image> Function(File file) decode =
      decodePage ?? decodeMangaPageFile;
  final List<OcrPageResult> results = await pipeline.processBook(
    bookId: 'manga_ocr',
    pageCount: pages.length,
    loadPage: (int pageIndex) => decode(pages[pageIndex].file),
    cancelToken: cancelToken,
    onProgress: onProgress,
  );

  final MokuroPayload generated = buildMangaPayloadFromResults(pages, results);
  final MokuroPayload payload = MokuroPayload(
    images: generated.images,
    ocr: const MangaOcrMetadata(
      engine: 'local_onnx',
      engineSignature: kLocalMangaOcrEngineSignature,
      schemaVersion: 1,
    ),
  );
  final File output = File(p.join(outDir.path, kMangaOcrOutputFileName));
  final File temporary = File('${output.path}.tmp');
  await temporary.writeAsString(
    jsonEncode(mangaPayloadToJson(payload)),
    flush: true,
  );
  if (output.existsSync()) {
    await output.delete();
  }
  await temporary.rename(output.path);
  return output.path;
}
