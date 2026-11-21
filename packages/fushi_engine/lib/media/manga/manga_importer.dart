import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_compute/fushi_compute.dart' show FfcImageFormat;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/image_kernels.dart';
import 'package:fushi_engine/media/manga/import/image_size_probe.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_legacy_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi_engine/foundation/engine_log.dart';

/// 页图来源目录归谁——决定页图是**拷**进书目录还是**移**进去。
enum MangaPageSource {
  /// 用户自己的目录（选中的页图文件夹、`.mokuro` 同级页图、来源库）：只读，逐页拷贝，
  /// 绝不动原文件。所有入口的默认值。
  borrowed,

  /// 调用方自己建的临时目录、导入完即整个删掉（压缩包解出的 staging、PDF 栅格化 /
  /// EPUB 铺页的暂存目录）：页图直接**移动**进书目录。同卷是一次 rename、不占额外
  /// 空间；跨卷（临时目录与书目录不在同一文件系统）才回退成「拷贝 + 删源」。
  ///
  /// 此前这些暂存目录也走拷贝：导入一个 4 GiB 的包，磁盘峰值是「原包 + 暂存 4 GiB +
  /// 书目录 4 GiB」，空间紧的平板会在拷贝中途写满。
  disposable,
}

/// 已知漫画页图扩展名（mokuro 惯例）＝漫画页图共享表（基集 + `.avif`）。
///
/// 与整卷 OCR 的白名单 `kMangaOcrImageExtensions`（manga_ocr_folder_job.dart）
/// 同源取共享表：导入这道关认的页图，OCR 那道关必须能扫（BUG-1121——两表曾各自
/// 手写漂移，bmp 漫画 OCR 静默缺页），守卫测试钉死两关口径一致。
const Set<String> kMangaImageExtensions = kMangaPageImageExtensions;

/// **载体分类**判据：[paths] 中至少有一个 `.mokuro` 文件，且其同级目录（含一层子目录）
/// 里有图片来源——即「这看起来是一卷 mokuro 漫画」，用于对话框即时禁用按钮 / 拖入分流。
///
/// **不是导入必定成功的保证**，也不该被当成保证使用：页图能不能对上取决于 `.mokuro` 里
/// 的 `img_path` 惯例（见 [resolveMokuroPageRoot]），而那要读并解析可能几 MB 的 JSON，
/// 不能塞进一个每帧都可能被调的同步判据里。真正的校验在 [MangaImporter.importFromMokuroPath]
/// 内：解析页图根 + 逐页校验，失败时给出指名道姓的可诊断错误。
///
/// BUG-1830 之前这里与导入器是**两套**判据（这里探一层子目录、导入器硬编码同级），
/// 于是卷子目录布局「门放行、执行必失败」。现在导入器认识两种惯例，门与执行不再打架；
/// 门保持宽松且**廉价**，是有意的分工，不是遗漏。
///
/// 纯判定（仅同步文件系统探测，无平台通道、无 async），便于单测与对话框即时禁用按钮。
bool mangaImportCanImport(List<String> paths) {
  for (final String path in paths) {
    // mokuro 旧版产物（`.html` + `_ocr/`）：页图就在同名卷目录里。
    if (isLegacyMokuroHtmlVolume(path)) {
      if (_dirHasMangaImage(Directory(legacyMokuroImageDir(path)))) return true;
      continue;
    }
    if (p.extension(path).toLowerCase() != '.mokuro') continue;
    final Directory parent = Directory(p.dirname(path));
    if (!parent.existsSync()) continue;
    for (final FileSystemEntity entity in parent.listSync()) {
      if (entity is File && _isMangaImageFile(entity.path)) return true;
      if (entity is Directory) {
        try {
          final bool hasImage = entity.listSync().any(
            (FileSystemEntity e) => e is File && _isMangaImageFile(e.path),
          );
          if (hasImage) return true;
        } catch (_) {
          // 无权限/瞬时 IO：跳过该子目录，继续探测其它来源。
        }
      }
    }
  }
  return false;
}

bool _dirHasMangaImage(Directory dir) {
  try {
    return dir
        .listSync(recursive: true)
        .any((FileSystemEntity e) => e is File && _isMangaImageFile(e.path));
  } catch (_) {
    return false;
  }
}

bool _isMangaImageFile(String path) =>
    kMangaImageExtensions.contains(p.extension(path).toLowerCase());

/// 从 `.mokuro`（v0.2+）+ 同级图片导入一本漫画，落进 `EpubBooks` 表（`format='manga'`，
/// 第三种「书」），复用整套书架 / 进度 / 删除管线，而非另建平行表。
///
/// 落盘与 [EpubImporter] 同一套（BUG-4840）：页图与 `manga.json` 先备进书库根下本次
/// 导入独占的 `.tmp-*` 暂存目录，再在落位锁内「重取快照 → 挪进 `<bookKey>/` → 插行」。
/// 书目录在落位之前不存在于别人看得见的名字下，失败回滚只删本次自己建的东西。
///
/// 落库列映射（与 PDF 同语义）：
/// - `epubPath` = `manga.json`（书目录内页/框结构文件名，阅读器 `extractDir/epubPath` 还原）。
/// - `extractDir` = 书目录（`<fushi_books>/<bookKey>/`）。
/// - `coverPath` = 第一页页图的相对路径（`images/...`，书架封面复用同一解析）。
/// - `chapterCount` = 页数；`chaptersJson = '[]'`。
/// - `mangaReadingMode` = null（导入时留空 = 跟随阅读器按页图长宽比自动判定）。
class MangaImporter {
  MangaImporter._();

  /// Import a folder of naturally sorted page images as an immediately
  /// readable manga. OCR blocks start empty and can be filled by any whole
  /// volume engine later; an OCR failure therefore never removes the book.
  ///
  /// [sourceMetadata] 原样写进书行的 `sourceMetadata`。纯图 EPUB 卷经这里落库时由
  /// [MangaArchiveImporter.importArchive] 传 OPF 系列描述符（`encodeEpubSeriesMetadata`）：
  /// 页图拷出来后原 EPUB 不在书目录里，存量回填读不到 OPF，导入这一刻是唯一能留下
  /// 系列声明的时机（iycDWb7ys6：分卷名里没有系列线索时靠它归合集）。
  static Future<String> importFromImageFolder({
    required FushiDatabase db,
    required String imageDirPath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
    String? sourceMetadata,
    MangaPageSource pageSource = MangaPageSource.borrowed,
  }) async {
    final Directory root = Directory(imageDirPath);
    final String proposedTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : (p.basename(root.path).isEmpty ? 'manga' : p.basename(root.path));
    // 跳过策略在逐页读尺寸之前判重（manga-10）：重导一个大半已入库的文件夹时，
    // 已有的卷不再把每页读一遍才被跳过。目录不在时照旧报「not found」。
    if (root.existsSync()) {
      await precheckSkippedDuplicate(
        db: db,
        proposedTitle: proposedTitle,
        policy: policy,
      );
    }
    final MokuroPayload payload = await payloadFromImageFolder(root);
    return _copyAndInsert(
      db: db,
      srcDir: root,
      payload: payload,
      proposedTitle: proposedTitle,
      policy: policy,
      onProgress: onProgress,
      sourceId: sourceId,
      sourceMetadata: sourceMetadata,
      pageSource: pageSource,
    );
  }

  /// [DuplicatePolicy.skip] 的导入前预检（manga-10）：[proposedTitle] 已在书库里时抛
  /// [DuplicateImportCancelledException]，否则什么都不做。只读一次瘦投影书目快照。
  ///
  /// 给「定书名之前要先做重活」的入口用（压缩包整包解压、页图文件夹逐页读尺寸）；
  /// 落位时 [EpubImporter.placeUnderResolvedTitle] 的判重照旧保留。其它策略直接返回，
  /// 不碰数据库（[DuplicatePolicy.ask] 的「先做完再问」次序不变）。
  static Future<void> precheckSkippedDuplicate({
    required FushiDatabase db,
    required String proposedTitle,
    required DuplicatePolicy policy,
  }) async {
    if (policy is! SkipDuplicate) return;
    final List<EpubBookMeta> books = await db.getEpubBookMetas();
    throwIfSkippedDuplicate(
      existingTitles: <String>[for (final EpubBookMeta b in books) b.title],
      proposedTitle: proposedTitle,
      policy: policy,
    );
  }

  /// 「一个装着页图的文件夹」→ [MokuroPayload] 的**唯一**枚举/解码口径：自然序枚举
  /// [root] 下的页图，逐张解码取真实宽高（`bakeOrientation` 后，EXIF 旋转过的页不会
  /// 把宽高读反），OCR 框留空。
  ///
  /// 抽成公开函数是因为「导入一本新漫画」与「把已在库的书就地转成漫画」
  /// （`book_format_rebuild.dart`）用的是同一批页图事实：两处各写一遍枚举/解码，
  /// 排序或宽高口径一旦漂开，转化产出的 `manga.json` 就与导入产出的不是同一种东西。
  static Future<MokuroPayload> payloadFromImageFolder(Directory root) async {
    if (!root.existsSync()) {
      throw MangaImportException('Manga image folder not found: ${root.path}');
    }
    final List<MangaOcrPageFile> files = enumerateMangaPages(root);
    if (files.isEmpty) {
      throw const MangaImportException('Manga image folder has no pages');
    }
    final List<MokuroImage> pages = <MokuroImage>[];
    for (final MangaOcrPageFile page in files) {
      pages.add(
        MokuroImage(
          url: page.relativeUrl,
          size: await pageSizeOfFile(page.file, page.relativeUrl),
          blocks: const <MokuroBlock>[],
        ),
      );
    }
    return MokuroPayload(images: pages);
  }

  /// 探尺寸时先读的前缀长度：JPEG 的 APP 段（EXIF / ICC）单段上限 64 KiB，给两段
  /// 的余量；漫画页多在 1~5 MB，前缀只占其中几个百分点。
  static const int kPageSizeProbePrefixBytes = 128 * 1024;

  /// 页图文件 [file] 的宽高（已按显示方向）：先只读前
  /// [kPageSizeProbePrefixBytes] 字节，能凭前缀定论的格式（[probeImageSizeFromPrefix]：
  /// PNG、头部在前缀内的 JPEG）直接返回；其余读全量走 [_pageSize]（manga-29c，此前
  /// 每页整张读进内存只为读头）。
  static Future<MokuroSize> pageSizeOfFile(
    File file,
    String relativeUrl,
  ) async {
    final RandomAccessFile handle = await file.open();
    final int length;
    final Uint8List prefix;
    try {
      length = await handle.length();
      prefix = await handle.read(kPageSizeProbePrefixBytes);
    } finally {
      await handle.close();
    }
    final ({int width, int height})? header = probeImageSizeFromPrefix(prefix);
    if (header != null) {
      return MokuroSize(header.width.toDouble(), header.height.toDouble());
    }
    final Uint8List bytes = prefix.length >= length
        ? prefix
        : await file.readAsBytes();
    if (isMangaTranscodedPage(file.path)) {
      // 导入时要转成 PNG 的页（TIFF）：尺寸必须与转码产物一致，而转码按原生解码器
      // 读到的方向标签转正——尺寸也只问原生内核（Dart 头探测不看 TIFF 方向）。
      return _nativePageSize(bytes, relativeUrl);
    }
    return _pageSize(bytes, relativeUrl);
  }

  /// [path] 是不是导入时转码成 PNG 落盘的页图（[kMangaImportTranscodedPageExtensions]）。
  static bool isMangaTranscodedPage(String path) =>
      kMangaImportTranscodedPageExtensions.contains(
        p.extension(path).toLowerCase(),
      );

  /// 把 [src]（[isMangaTranscodedPage] 的页图）在后台 isolate 里转成 PNG 写到 [dest]。
  /// 解不开抛 [MangaImportException]（与探尺寸失败同一种「坏页」错误）。
  static Future<void> transcodePageFile(
    File src,
    File dest,
    String relativeUrl,
  ) async {
    final Uint8List bytes = await src.readAsBytes();
    final Uint8List? png = await Isolate.run(() => encodeImageAsPng(bytes));
    if (png == null) {
      throw MangaImportException('Could not decode manga page: $relativeUrl');
    }
    await dest.writeAsBytes(png, flush: true);
  }

  static MokuroSize _nativePageSize(Uint8List bytes, String relativeUrl) {
    final ({int width, int height, FfcImageFormat format})? native =
        probeImageNative(bytes);
    if (native == null) {
      throw MangaImportException('Could not decode manga page: $relativeUrl');
    }
    return MokuroSize(native.width.toDouble(), native.height.toDouble());
  }

  /// 页图宽高（已按显示方向）：先走 Dart 头部探测（[probeOrientedImageSize]，JPEG /
  /// PNG / WebP 等），认不出的格式交给原生内核只读头（[probeImageNative]，含 AVIF——
  /// 它的 irot 宽高互换在原生侧完成）。原生也认不出才算坏页。
  ///
  /// 以前的回退是 `package:image` 整张解码：AVIF 页到这里直接抛「Could not decode」，
  /// 整卷导入失败。
  static MokuroSize _pageSize(Uint8List bytes, String relativeUrl) {
    final ({int width, int height})? header = probeOrientedImageSize(bytes);
    if (header != null) {
      return MokuroSize(header.width.toDouble(), header.height.toDouble());
    }
    final ({int width, int height, FfcImageFormat format})? native =
        probeImageNative(bytes);
    if (native == null) {
      throw MangaImportException('Could not decode manga page: $relativeUrl');
    }
    return MokuroSize(native.width.toDouble(), native.height.toDouble());
  }

  /// 第一遍（纯校验，零副作用）：为 [payload] 的每页规划书目录内的 destRel
  /// （`images/...`，sanitize + 保留子目录 + 去重 + 防穿越），并校验源图在 [srcDir]
  /// 里确实存在。返回值与 `payload.images` 一一对应、同序。
  ///
  /// 与 [copyMangaArtifacts] 拆成两步不是为了好看：调用方（导入器）必须在**建书目录
  /// 与问用户同名冲突之前**跑完校验，否则一次注定失败的导入会先弹一个同名弹窗、
  /// 再留下一个空书目录。
  static List<String> planMangaDestRels({
    required Directory srcDir,
    required MokuroPayload payload,
  }) {
    final List<String> destRels = <String>[];
    final Set<String> usedDestRels = <String>{};
    for (final MokuroImage page in payload.images) {
      // sanitizeRelSegments 对含 `..` 的 img_path 抛 MangaImportException（防穿越红线）。
      final List<String> segments = MangaStorage.sanitizeRelSegments(page.url);
      // TIFF 页落盘成 PNG（[copyMangaArtifacts] 转码），destRel 先换好扩展名：
      // manga.json 的 url 与书目录里的文件名一致，且与同名 `.png` 页一起去重。
      if (segments.isNotEmpty && isMangaTranscodedPage(segments.last)) {
        final String last = segments.last;
        segments[segments.length - 1] =
            p.withoutExtension(last) +
            mangaStoredPageExtension(p.extension(last));
      }
      destRels.add(MangaStorage.uniqueDestRel(segments, usedDestRels));
      final File src = mokuroPageFile(srcDir.path, page.url);
      if (!src.existsSync()) {
        throw MangaImportException('Missing manga page image: ${page.url}');
      }
    }
    return destRels;
  }

  /// 第二遍（落盘）：把页图从 [srcDir] 拷进 `<bookDir>/images/<destRel>`，再写
  /// `<bookDir>/manga.json`（`url` 已改写成 destRel）。返回页数与封面相对路径
  /// （= 第一页页图，书架封面解析器 `p.join(extractDir, coverPath)` 直接可用）。
  ///
  /// **不碰数据库**：导入走 `insertEpubBook`、转化走 `updateEpubBookFormat`，
  /// 但两者产出的磁盘产物必须逐字节同构，故这一段只有一份实现。
  static Future<({int pageCount, String coverRel})> copyMangaArtifacts({
    required Directory srcDir,
    required MokuroPayload payload,
    required List<String> destRels,
    required String bookDir,
    void Function(int done, int total)? onProgress,
    MangaPageSource pageSource = MangaPageSource.borrowed,
  }) async {
    // 逐页 await 让主 isolate 有机会喂进度不卡 UI。
    final int total = payload.images.length;
    final List<MokuroImage> rewritten = <MokuroImage>[];
    // disposable 模式下已经移走的源 → 它在书目录里的新位置：多页引用同一张源图时，
    // 第二次起从书目录里那份拷（源已经不在原处）。
    final Map<String, File> moved = <String, File>{};
    for (int i = 0; i < total; i++) {
      final MokuroImage page = payload.images[i];
      final String destRel = destRels[i];
      final File src = mokuroPageFile(srcDir.path, page.url);
      final File dest = MangaStorage.destFile(bookDir, destRel);
      dest.parent.createSync(recursive: true);
      if (isMangaTranscodedPage(src.path)) {
        // TIFF：转成 PNG 写进书目录（destRel 已在 [planMangaDestRels] 换成 .png）。
        // disposable 的源留在暂存目录里随它一起删；同一张源被多页引用时照样从书目录
        // 里那份拷，不重复转码。
        final String key = p.canonicalize(src.path);
        final File? earlier = moved[key];
        if (earlier != null) {
          await earlier.copy(dest.path);
        } else {
          await transcodePageFile(src, dest, page.url);
          moved[key] = dest;
        }
        rewritten.add(
          MokuroImage(url: destRel, size: page.size, blocks: page.blocks),
        );
        onProgress?.call(i + 1, total);
        continue;
      }
      switch (pageSource) {
        case MangaPageSource.borrowed:
          await src.copy(dest.path);
        case MangaPageSource.disposable:
          final String key = p.canonicalize(src.path);
          final File? earlier = moved[key];
          if (earlier != null) {
            await earlier.copy(dest.path);
          } else {
            await movePageFile(src, dest);
            moved[key] = dest;
          }
      }
      rewritten.add(
        MokuroImage(url: destRel, size: page.size, blocks: page.blocks),
      );
      onProgress?.call(i + 1, total);
    }

    // 写序列化页/框结构（url 已改写为 destRel；mangaPayloadToJson 保留 lines_coords）。
    final Map<String, Object?> serialized = mangaPayloadToJson(
      MokuroPayload(images: rewritten, ocr: payload.ocr),
    );
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString(jsonEncode(serialized), flush: true);

    return (pageCount: total, coverRel: destRels.first);
  }

  /// 把 [src] 移到 [dest]（覆盖已存在的 [dest]）：同一文件系统内是一次 rename；
  /// 跨文件系统（EXDEV / Windows ERROR_NOT_SAME_DEVICE）回退成拷贝后删源。其它失败
  /// 照常抛出。
  static Future<void> movePageFile(File src, File dest) async {
    try {
      await src.rename(dest.path);
    } on FileSystemException catch (e) {
      if (!_isCrossDevice(e)) rethrow;
      await src.copy(dest.path);
      await src.delete();
    }
  }

  /// rename 失败是不是「源与目标不在同一文件系统」：POSIX `EXDEV`（18）、Windows
  /// `ERROR_NOT_SAME_DEVICE`（17）。
  static bool _isCrossDevice(FileSystemException e) {
    final int? code = e.osError?.errorCode;
    return Platform.isWindows ? code == 17 : code == 18;
  }

  /// 从 [mokuroPath] 指向的 `.mokuro` 文件导入一本漫画，返回新建的 `bookKey`。
  ///
  /// [title]：由导入对话框传入的用户可编辑标题（优先）；缺省则从 mokuro 顶层 `title`/
  /// `volume` 组合派生，再退化文件名。同名卷冲突走 [resolveDuplicateTitle]（与 EPUB/PDF
  /// 一致）：有 [DuplicatePolicy.ask] 回调则询问用户加后缀/取消，无回调自动加后缀。
  /// [onProgress] 在每复制完一页图片后回报 `(done, total)`。校验失败（非法文件夹 / 路径穿越
  /// / 缺图）抛 [MangaImportException]；用户取消同名弹窗抛 [DuplicateImportCancelledException]。
  static Future<String> importFromMokuroPath({
    required FushiDatabase db,
    required String mokuroPath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
    MangaPageSource pageSource = MangaPageSource.borrowed,
  }) async {
    final File mokuroFile = File(mokuroPath);
    if (!mokuroFile.existsSync()) {
      throw MangaImportException('Mokuro file not found: $mokuroPath');
    }
    // mokuro 0.1 旧版产物（`.html` + `_ocr/`）先拼回 `.mokuro` 形状，之后同一条管线。
    final String jsonStr = isMokuroLegacyHtmlPath(mokuroPath)
        ? await legacyMokuroJson(mokuroPath)
        : await mokuroFile.readAsString();
    return importMokuroDocument(
      db: db,
      document: parseMokuroDocument(jsonStr),
      mokuroPath: mokuroPath,
      title: title,
      policy: policy,
      onProgress: onProgress,
      sourceId: sourceId,
      pageSource: pageSource,
    );
  }

  /// [importFromMokuroPath] 的落库段：清单已经解析好（[document]，一次解析同时带出
  /// 页模型与顶层标题），不再读盘、不再重复解析（manga-29b：压缩包里的清单此前要
  /// 写回暂存目录、再读回来解析两遍）。
  ///
  /// [mokuroPath] 只用来定位页图根（所在目录 + 卷名 = 去扩展名的文件名）与回退标题，
  /// 文件本身不必存在。顶层不是对象时 `root` 为空，标题退化文件名。
  static Future<String> importMokuroDocument({
    required FushiDatabase db,
    required MokuroDocument document,
    required String mokuroPath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
    MangaPageSource pageSource = MangaPageSource.borrowed,
  }) async {
    final MokuroPayload payload = document.payload;
    if (payload.images.isEmpty) {
      throw const MangaImportException('Mokuro file has no pages');
    }
    final Map<String, Object?> root = document.root;
    final File mokuroFile = File(mokuroPath);

    // 页图根**解析**出来，不硬编码成 `.mokuro` 同级（BUG-1830 的根因）：mokuro 的
    // `img_path` 有两种并存惯例，卷子目录布局下裸文件名相对同级解析必然落空。判据与
    // 远端扫描镜像、下游逐页校验共用 [resolveMokuroPageRoot] 一份实现。
    final Directory mokuroDir = mokuroFile.parent;
    final String volumeName = p.basenameWithoutExtension(mokuroPath);
    final List<String>? pageRoot = resolveMokuroPageRoot(
      payload: payload,
      volumeName: volumeName,
      pageExists: (String rel) =>
          mokuroPageFile(mokuroDir.path, rel).existsSync(),
    );
    if (pageRoot == null) {
      // 两种惯例都不成立：把搜过的目录逐条报出来。这条文案是用户唯一能拿到的线索，
      // 只说「缺图」而不说「在哪找的」正是当初排查要靠逐帧截图的原因。
      final String searched = mokuroPageRootCandidates(volumeName: volumeName)
          .map(
            (List<String> candidate) =>
                p.joinAll(<String>[mokuroDir.path, ...candidate]),
          )
          .join(', ');
      throw MangaImportException(
        'Missing manga page image: ${payload.images.first.url} '
        '(searched: $searched)',
      );
    }
    final Directory srcDir = pageRoot.isEmpty
        ? mokuroDir
        : Directory(p.joinAll(<String>[mokuroDir.path, ...pageRoot]));

    // 标题 → 冲突解析 → bookKey（= 净化标题即主键，与 EpubImporter/PdfImporter 同口径）。
    final String proposedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : deriveMokuroTitle(root, mokuroPath);

    return _copyAndInsert(
      db: db,
      srcDir: srcDir,
      payload: payload,
      proposedTitle: proposedTitle,
      policy: policy,
      onProgress: onProgress,
      sourceId: sourceId,
      pageSource: pageSource,
    );
  }

  /// 从内部 `manga.json`（[parseMangaJson] 格式，= 内置 OCR 引擎 `ocrFolder` 的产出）
  /// 导入一本漫画。与 [importFromMokuroPath] 共用同一两遍式落库内核 [_copyAndInsert]，
  /// 差异只在**入口格式**：
  /// - 解析走 [parseMangaJson]（`{pages:[{url,width,height,...}]}`）而非 mokuro 的
  ///   `{pages:[{img_path,img_width,...}]}`；
  /// - 图片默认相对 [mangaJsonPath] 同级目录解析；[imageRootPath] 非 null 时改以
  ///   它为根——OCR 引擎（`ocrFolder` / 远程代跑）把 manga.json 落在被扫描目录的
  ///   `manga_ocr_out/` 子目录里，而页 `url` 相对**被扫描目录**（P3 修正：旧注释
  ///   误以为引擎把页图与 manga.json 同放输出目录），向导据此显式传所选文件夹；
  /// - 标题优先取调用方 [title]（向导里的卷名/用户可编辑标题），缺省退化输出目录名——
  ///   manga.json 序列化格式不含顶层 title/volume（[mangaPayloadToJson] 只写 `pages`）。
  ///
  /// 校验失败（缺文件 / 无页 / 缺图 / 路径穿越）抛 [MangaImportException]；同名卷冲突与
  /// 用户取消语义与 [importFromMokuroPath] 完全一致。
  static Future<String> importFromMangaJson({
    required FushiDatabase db,
    required String mangaJsonPath,
    String? imageRootPath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
  }) async {
    final File jsonFile = File(mangaJsonPath);
    if (!jsonFile.existsSync()) {
      throw MangaImportException('Manga JSON not found: $mangaJsonPath');
    }
    final String jsonStr = await jsonFile.readAsString();
    final MokuroPayload payload = parseMangaJson(jsonStr);
    if (payload.images.isEmpty) {
      throw const MangaImportException('Manga JSON has no pages');
    }

    final Directory srcDir = imageRootPath != null
        ? Directory(imageRootPath)
        : jsonFile.parent;
    final String proposedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : (p.basename(srcDir.path).isNotEmpty
              ? p.basename(srcDir.path)
              : 'manga');

    return _copyAndInsert(
      db: db,
      srcDir: srcDir,
      payload: payload,
      proposedTitle: proposedTitle,
      policy: policy,
      onProgress: onProgress,
      sourceId: sourceId,
    );
  }

  /// 两遍式落库内核（[importFromMokuroPath] / [importFromMangaJson] 共用）：
  /// 第一遍纯校验（规划 destRel + 防穿越 + 校验源图存在，零副作用），第二遍拷图 +
  /// 写 manga.json + 落位 + 插 `EpubBooks` 行 + 活动事件；任一步失败整体回滚。
  ///
  /// [srcDir] 是页图来源目录（.mokuro 或 manga.json 的同级目录），[payload] 的每页
  /// `url` 相对它解析。[proposedTitle] 已由各入口按各自规则派生。
  ///
  /// 书目录**不是**边拷边建在 `<fushi_books>/<bookKey>/` 上的（BUG-4840 之前是）：
  /// `EpubStorage.bookDirectory` 存在即复用，于是两次同名导入、或一次导入撞上崩溃
  /// 留下的同名孤儿目录，都在往同一个目录里混写；失败回滚又无条件整个删掉——删的可能
  /// 是赢家那本书，也可能是「找回书库」本可恢复的孤儿。现在的次序：
  ///
  /// 1. 锁外定书名（同名弹窗在这一步，校验失败的导入根本走不到这里）；
  /// 2. 页图 + `manga.json` 备进本次独占的 `.tmp-*`（与书库同卷，落位是一次 rename）；
  /// 3. 落位锁内重取快照，经 [EpubStorage.moveDirIntoPlace] 落位（活行占着的目录
  ///    绝不碰，改落 `~n`；无主的同名目录按 EPUB 的既有取舍带 `.bak` 回滚替换），
  ///    紧接着插行。
  ///
  /// 回滚只删两样：自己的暂存目录、自己刚落位而行没插成的目录。
  static Future<String> _copyAndInsert({
    required FushiDatabase db,
    required Directory srcDir,
    required MokuroPayload payload,
    required String proposedTitle,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
    String? sourceMetadata,
    MangaPageSource pageSource = MangaPageSource.borrowed,
  }) async {
    // 第一遍：规划每页 destRel（sanitize + 保留子目录 + 去重）并校验源图存在 + 防路径穿越。
    // 全部在任何落盘/落库之前完成——校验失败零副作用，无需回滚。
    final List<String> destRels = planMangaDestRels(
      srcDir: srcDir,
      payload: payload,
    );

    String? stagedDir;
    ({int pageCount, String coverRel})? artifacts;
    String? placedDir;
    String? insertedKey;
    try {
      final ({String storedTitle, String bookKey, int importedAtMs}) placed =
          await EpubImporter.placeUnderResolvedTitle(
            db: db,
            proposedTitle: proposedTitle,
            policy: policy,
            // 第二遍：拷图 + 写 manga.json，进暂存目录。书名键在锁内被别人占了要
            // 重新定夺时会再进来一次，已备好的不重做。
            stage: () async {
              if (artifacts != null) return;
              final String dir = await EpubImporter.createStagingDir(db);
              stagedDir = dir;
              artifacts = await copyMangaArtifacts(
                srcDir: srcDir,
                payload: payload,
                destRels: destRels,
                bookDir: dir,
                onProgress: onProgress,
                pageSource: pageSource,
              );
            },
            place:
                (
                  String storedTitle,
                  String bookKey,
                  List<EpubBookMeta> liveBooks,
                ) async {
                  final String bookDir = EpubStorage.moveDirIntoPlace(
                    srcDir: Directory(stagedDir!),
                    targetDir: await MangaStorage.bookPath(bookKey),
                    liveExtractDirs: liveBooks.map(
                      (EpubBookMeta b) => b.extractDir,
                    ),
                  );
                  placedDir = bookDir;
                  final int importedAtMs =
                      DateTime.now().millisecondsSinceEpoch;
                  // 封面 = 第一页页图的相对路径（书架封面解析器
                  // `p.join(extractDir, coverPath)`）。
                  insertedKey = await db.insertEpubBook(
                    bookRowFor(
                      bookKey: bookKey,
                      title: storedTitle,
                      coverRel: artifacts!.coverRel,
                      bookDir: bookDir,
                      pageCount: artifacts!.pageCount,
                      importedAt: importedAtMs,
                      sourceId: sourceId,
                      sourceMetadata: sourceMetadata,
                    ),
                  );
                  return (
                    storedTitle: storedTitle,
                    bookKey: bookKey,
                    importedAtMs: importedAtMs,
                  );
                },
          );

      // 与 EPUB/PDF 一致：写一条「added」活动事件喂首页时间轴。best-effort。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: placed.storedTitle,
          mediaKey: placed.bookKey,
          dateKey: FushiTimeFormat.dayKey(
            DateTime.fromMillisecondsSinceEpoch(placed.importedAtMs),
          ),
          timestampMs: placed.importedAtMs,
        );
      } catch (e) {
        engineLog.log('MangaImporter.addActivityEvent', e, StackTrace.current);
      }

      return placed.bookKey;
    } catch (e) {
      // 回滚：删掉可能已插入的行，以及**本次自己建的**目录——暂存目录，和已经落位
      // 但行没插成的书目录。别人的目录（活行的、孤儿的）从头到尾没被写过。
      final String? inserted = insertedKey;
      if (inserted != null) {
        try {
          await db.deleteEpubBook(inserted);
        } catch (rollbackError, stack) {
          engineLog.log('MangaImporter.rollbackDelete', rollbackError, stack);
        }
      }
      for (final String? own in <String?>[placedDir, stagedDir]) {
        if (own == null) continue;
        try {
          final Directory dir = Directory(own);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } catch (cleanupError, stack) {
          engineLog.log('MangaImporter.rollbackDir', cleanupError, stack);
        }
      }
      rethrow;
    }
  }

  /// 本地漫画书目录 → `EpubBooks` 行：导入（[_copyAndInsert]）与「孤儿书目录
  /// 重新登记」（[registerExistingBookDir]，BUG-4701）共用的唯一行构造口径。
  static EpubBooksCompanion bookRowFor({
    required String bookKey,
    required String title,
    required String coverRel,
    required String bookDir,
    required int pageCount,
    required int importedAt,
    int? sourceId,
    String? sourceMetadata,
  }) {
    return EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      coverPath: Value(coverRel),
      epubPath: MangaStorage.kMangaJsonFileName,
      extractDir: bookDir,
      chapterCount: pageCount,
      chaptersJson: '[]',
      importedAt: importedAt,
      format: Value(BookFormat.manga.dbValue),
      // mangaReadingMode 留 absent(null)：跟随阅读器自动判定（P1-L4 契约）。
      sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
      sourceMetadata: sourceMetadata != null
          ? Value(sourceMetadata)
          : const Value.absent(),
    );
  }

  /// 把盘上已有、但没有书库行的本地漫画书目录 [bookDir]（`manga.json` + `images/`，
  /// 即 [copyMangaArtifacts] 的产物）重新登记成书（BUG-4701）。[bookKey] 由调用方
  /// 给定（= 目录名），不重新派生。页数 = `manga.json` 的页数，封面 = 第一页（与
  /// [copyMangaArtifacts] 返回的 coverRel 同一规则）。`manga.json` 缺失 / 无页抛
  /// [MangaImportException]。
  static Future<String> registerExistingBookDir({
    required FushiDatabase db,
    required String bookKey,
    required String title,
    required String bookDir,
  }) async {
    final File jsonFile = File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    );
    if (!jsonFile.existsSync()) {
      throw MangaImportException('Manga JSON not found: ${jsonFile.path}');
    }
    final MokuroPayload payload = parseMangaJson(await jsonFile.readAsString());
    if (payload.images.isEmpty) {
      throw const MangaImportException('Manga JSON has no pages');
    }
    // 插行持落位锁，理由同 `EpubImporter.registerExtractedBook`：不让登记插进并发
    // 导入的「判归属 → 挪目录」中间。
    return EpubStorage.withBookPlacementLock(
      () => db.insertEpubBook(
        bookRowFor(
          bookKey: bookKey,
          title: title,
          coverRel: payload.images.first.url,
          bookDir: bookDir,
          pageCount: payload.images.length,
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  /// mokuro 0.1 旧版产物 [htmlPath]（`<父>/<卷名>.html`）→ 一份 `.mokuro` 形状的
  /// JSON 文本（见 `mokuro_legacy_html.dart`）。
  ///
  /// 页序与 mokuro 一致：卷目录 `<父>/<卷名>/` 下的页图按自然序枚举（与
  /// [payloadFromImageFolder] 同一个 [enumerateMangaPages]）；每页的文字层取
  /// `<父>/_ocr/<卷名>/<页相对路径去扩展名>.json`，宽高 / 框原样搬过来，`img_path`
  /// 写成相对 `.html` 所在目录的 `<卷名>/<页>`（`.mokuro` 惯例 A），于是下游的页图根
  /// 解析、逐页校验、拷贝与普通 `.mokuro` 卷逐字节同构。某页没有 JSON（mokuro 半途
  /// 失败）时该页照常入卷、文字层为空、宽高从页图头部探测——少一页字好过整卷失败。
  ///
  /// 卷目录或 `_ocr/<卷名>/` 不在，抛 [MangaImportException] 并指出缺的是哪个目录。
  static Future<String> legacyMokuroJson(String htmlPath) async {
    final Directory imageDir = Directory(legacyMokuroImageDir(htmlPath));
    final Directory ocrDir = Directory(legacyMokuroOcrDir(htmlPath));
    for (final Directory required in <Directory>[imageDir, ocrDir]) {
      if (!required.existsSync()) {
        throw MangaImportException(
          'Not a mokuro volume: missing folder ${required.path}',
        );
      }
    }
    final String volumeName = p.basename(imageDir.path);
    final List<MangaOcrPageFile> files = enumerateMangaPages(imageDir);
    if (files.isEmpty) {
      throw MangaImportException(
        'Manga image folder has no pages: ${imageDir.path}',
      );
    }
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (final MangaOcrPageFile page in files) {
      final File json = File(
        p.joinAll(<String>[
          ocrDir.path,
          ...legacyMokuroPageJsonRel(page.relativeUrl).split('/'),
        ]),
      );
      Map<String, Object?>? ocr;
      if (json.existsSync()) {
        final Object? decoded = jsonDecode(await json.readAsString());
        if (decoded is Map) ocr = decoded.cast<String, Object?>();
      }
      final Object? width = ocr?['img_width'];
      final Object? height = ocr?['img_height'];
      final MokuroSize size =
          width is num && height is num && width > 0 && height > 0
          ? MokuroSize(width.toDouble(), height.toDouble())
          : await pageSizeOfFile(page.file, page.relativeUrl);
      final Object? blocks = ocr?['blocks'];
      pages.add(<String, Object?>{
        'img_path': '$volumeName/${page.relativeUrl}',
        'img_width': size.width,
        'img_height': size.height,
        'blocks': blocks is List ? blocks : const <Object?>[],
      });
    }
    return jsonEncode(<String, Object?>{
      ...legacyMokuroRoot(htmlPath),
      'pages': pages,
    });
  }

  /// 把相对 [rawUrl]（正斜杠或反斜杠）解析成 [srcDirPath] 下的源图 [File]。
  ///
  /// 公开是因为「造出一个 mokuro 卷目录」与「读一个 mokuro 卷目录」必须是同一套
  /// 口径：[MangaArchiveImporter] 把压缩包里的页图铺进临时目录时，如果另用一套
  /// 路径派生（例如 `MangaStorage.sanitizeRelSegments`——它会剥掉前导 `images/`
  /// 段、还会改写 Windows 非法字符），铺出来的文件名在读取侧永远找不到，整卷导入
  /// 必报 `Missing manga page image`。写入方与读取方共用本函数即消除该错位。
  static File mokuroPageFile(String srcDirPath, String rawUrl) =>
      File(p.joinAll(<String>[srcDirPath, ...rawUrl.split(RegExp(r'[\\/]+'))]));

  /// 从 mokuro 顶层 `title` + `volume` 派生显示标题（进而派生 bookKey）。组合 `title volume`
  /// 让同系列不同卷得到唯一 bookKey（否则两卷 sanitize 后撞主键、被迫加 `(2)` 后缀）。缺 title
  /// 退化文件名（mokuro 惯例文件名即卷名，天然唯一）。
  ///
  /// 公开是给来源库扫描的网络去重预检用（SourceLibraryScanner 先读远端 `.mokuro`
  /// 派生标题、命中已入库即跳过整卷下载）：预检必须与导入器同一套身份派生，
  /// 不允许出现第二套判重规则。
  static String deriveMokuroTitle(
    Map<String, Object?> root,
    String mokuroPath,
  ) {
    final String title = (root['title'] as String?)?.trim() ?? '';
    final String volume = (root['volume'] as String?)?.trim() ?? '';
    final String base = p.basenameWithoutExtension(mokuroPath);
    if (title.isEmpty) return base.isNotEmpty ? base : 'manga';
    if (volume.isNotEmpty && !title.contains(volume)) return '$title $volume';
    return title;
  }
}
