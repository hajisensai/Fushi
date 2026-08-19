import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_time_format.dart';

/// 已知漫画页图扩展名（mokuro 惯例）＝图片扩展名基集。
///
/// 与整卷 OCR 的白名单 `kMangaOcrImageExtensions`（manga_ocr_folder_job.dart）
/// 同源取基集：导入这道关认的页图，OCR 那道关必须能扫（BUG-1121——两表曾各自
/// 手写漂移，bmp 漫画 OCR 静默缺页），守卫测试钉死两关口径一致。
const Set<String> kMangaImageExtensions = kImageExtensionsBase;

/// 是否可作为 mokuro 漫画导入：[paths] 中至少有一个 `.mokuro` 文件，且其同级目录里有图片
/// 来源。图片来源识别一层深，覆盖 mokuro 的两种惯例布局：
/// - `<卷名>.mokuro` 配 `<卷名>/`（或 `images/`）子目录，图片在该子目录内；
/// - 图片直接平铺在 `.mokuro` 同级目录。
///
/// 纯判定（仅同步文件系统探测，无平台通道、无 async），便于单测与对话框即时禁用按钮。
bool mangaImportCanImport(List<String> paths) {
  for (final String path in paths) {
    if (p.extension(path).toLowerCase() != '.mokuro') continue;
    final Directory parent = Directory(p.dirname(path));
    if (!parent.existsSync()) continue;
    for (final FileSystemEntity entity in parent.listSync()) {
      if (entity is File && _isMangaImageFile(entity.path)) return true;
      if (entity is Directory) {
        try {
          final bool hasImage = entity.listSync().any(
              (FileSystemEntity e) => e is File && _isMangaImageFile(e.path));
          if (hasImage) return true;
        } catch (_) {
          // 无权限/瞬时 IO：跳过该子目录，继续探测其它来源。
        }
      }
    }
  }
  return false;
}

bool _isMangaImageFile(String path) =>
    kMangaImageExtensions.contains(p.extension(path).toLowerCase());

/// 从 `.mokuro`（v0.2+）+ 同级图片导入一本漫画，落进 `EpubBooks` 表（`format='manga'`，
/// 第三种「书」），复用整套书架 / 进度 / 删除管线，而非另建平行表。
///
/// 与 [PdfImporter] 同款范式：封面/元数据在解析阶段先算出，`bookKey`（= 净化标题，
/// `EpubBooks` 主键）在拷贝落盘前解析，失败即整体回滚已插入的行与已建的书目录。
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
  static Future<String> importFromImageFolder({
    required FushiDatabase db,
    required String imageDirPath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) async {
    final Directory root = Directory(imageDirPath);
    final MokuroPayload payload = await payloadFromImageFolder(root);
    final String proposedTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : (p.basename(root.path).isEmpty ? 'manga' : p.basename(root.path));
    return _copyAndInsert(
      db: db,
      srcDir: root,
      payload: payload,
      proposedTitle: proposedTitle,
      policy: policy,
      onProgress: onProgress,
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
      final img.Image? decoded = img.decodeImage(await page.file.readAsBytes());
      if (decoded == null) {
        throw MangaImportException(
          'Could not decode manga page: ${page.relativeUrl}',
        );
      }
      final img.Image oriented = img.bakeOrientation(decoded);
      pages.add(
        MokuroImage(
          url: page.relativeUrl,
          size: Size(oriented.width.toDouble(), oriented.height.toDouble()),
          blocks: const <MokuroBlock>[],
        ),
      );
    }
    return MokuroPayload(images: pages);
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
      destRels.add(MangaStorage.uniqueDestRel(segments, usedDestRels));
      final File src = _sourceFile(srcDir.path, page.url);
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
  }) async {
    // 逐页 await 让主 isolate 有机会喂进度不卡 UI。
    final int total = payload.images.length;
    final List<MokuroImage> rewritten = <MokuroImage>[];
    for (int i = 0; i < total; i++) {
      final MokuroImage page = payload.images[i];
      final String destRel = destRels[i];
      final File src = _sourceFile(srcDir.path, page.url);
      final File dest = MangaStorage.destFile(bookDir, destRel);
      dest.parent.createSync(recursive: true);
      await src.copy(dest.path);
      rewritten.add(
        MokuroImage(url: destRel, size: page.size, blocks: page.blocks),
      );
      onProgress?.call(i + 1, total);
    }

    // 写序列化页/框结构（url 已改写为 destRel；mangaPayloadToJson 保留 lines_coords）。
    final Map<String, Object?> serialized =
        mangaPayloadToJson(MokuroPayload(images: rewritten, ocr: payload.ocr));
    await File(p.join(bookDir, MangaStorage.kMangaJsonFileName))
        .writeAsString(jsonEncode(serialized), flush: true);

    return (pageCount: total, coverRel: destRels.first);
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
  }) async {
    if (!mangaImportCanImport(<String>[mokuroPath])) {
      throw const MangaImportException('Not a valid Mokuro manga folder');
    }

    final File mokuroFile = File(mokuroPath);
    final String jsonStr = await mokuroFile.readAsString();
    final MokuroPayload payload = parseMokuro(jsonStr);
    if (payload.images.isEmpty) {
      throw const MangaImportException('Mokuro file has no pages');
    }

    // 顶层标题/卷元数据（parseMokuro 不带这些进模型，故从原始 JSON 顶层读）。顶层若不是对象
    // （罕见的 top-level array/标量）降级为空 root，标题退化文件名，避免 as Map 硬崩。
    final Object? rawRoot = jsonDecode(jsonStr);
    final Map<String, Object?> root =
        rawRoot is Map ? rawRoot.cast<String, Object?>() : <String, Object?>{};

    final Directory srcDir = mokuroFile.parent;

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

    final Directory srcDir =
        imageRootPath != null ? Directory(imageRootPath) : jsonFile.parent;
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
  /// 写 manga.json + 插 `EpubBooks` 行 + 活动事件；任一步失败整体回滚已插行与书目录。
  ///
  /// [srcDir] 是页图来源目录（.mokuro 或 manga.json 的同级目录），[payload] 的每页
  /// `url` 相对它解析。[proposedTitle] 已由各入口按各自规则派生。
  static Future<String> _copyAndInsert({
    required FushiDatabase db,
    required Directory srcDir,
    required MokuroPayload payload,
    required String proposedTitle,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
  }) async {
    // 第一遍：规划每页 destRel（sanitize + 保留子目录 + 去重）并校验源图存在 + 防路径穿越。
    // 全部在任何落盘/落库之前完成——校验失败零副作用，无需回滚。
    final List<String> destRels =
        planMangaDestRels(srcDir: srcDir, payload: payload);

    final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
    final String storedTitle = await resolveDuplicateTitle(
      existingTitles: existingBooks.map((EpubBookRow b) => b.title).toList(),
      proposedTitle: proposedTitle,
      policy: policy,
    );
    final String bookKey = sanitizeTtuFilename(storedTitle);
    final String bookDir = await MangaStorage.bookDirectory(bookKey);

    String? insertedKey;
    try {
      // 第二遍：拷图 + 写 manga.json。封面 = 第一页页图的相对路径（书架封面解析器
      // `p.join(extractDir, coverPath)`）。
      final ({int pageCount, String coverRel}) artifacts =
          await copyMangaArtifacts(
        srcDir: srcDir,
        payload: payload,
        destRels: destRels,
        bookDir: bookDir,
        onProgress: onProgress,
      );
      final int total = artifacts.pageCount;
      final String coverRel = artifacts.coverRel;

      final int importedAtMs = DateTime.now().millisecondsSinceEpoch;
      insertedKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: storedTitle,
          coverPath: Value(coverRel),
          epubPath: MangaStorage.kMangaJsonFileName,
          extractDir: bookDir,
          chapterCount: total,
          chaptersJson: '[]',
          importedAt: importedAtMs,
          format: Value(BookFormat.manga.dbValue),
          // mangaReadingMode 留 absent(null)：跟随阅读器自动判定（P1-L4 契约）。
          sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
        ),
      );

      // 与 EPUB/PDF 一致：写一条「added」活动事件喂首页时间轴。best-effort。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: storedTitle,
          mediaKey: bookKey,
          dateKey: FushiTimeFormat.dayKey(
            DateTime.fromMillisecondsSinceEpoch(importedAtMs),
          ),
          timestampMs: importedAtMs,
        );
      } catch (e) {
        ErrorLogService.instance
            .log('MangaImporter.addActivityEvent', e, StackTrace.current);
      }

      return insertedKey;
    } catch (e) {
      // 回滚：删掉可能已插入的行 + 已建的书目录，避免半成品残留。
      if (insertedKey != null) {
        try {
          await db.deleteEpubBook(insertedKey);
        } catch (rollbackError, stack) {
          ErrorLogService.instance
              .log('MangaImporter.rollbackDelete', rollbackError, stack);
        }
      }
      try {
        final Directory dir = Directory(bookDir);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (cleanupError, stack) {
        ErrorLogService.instance
            .log('MangaImporter.rollbackDir', cleanupError, stack);
      }
      rethrow;
    }
  }

  /// 把相对 [rawUrl]（正斜杠或反斜杠）解析成 [srcDirPath] 下的源图 [File]。
  static File _sourceFile(String srcDirPath, String rawUrl) =>
      File(p.joinAll(<String>[srcDirPath, ...rawUrl.split(RegExp(r'[\\/]+'))]));

  /// 从 mokuro 顶层 `title` + `volume` 派生显示标题（进而派生 bookKey）。组合 `title volume`
  /// 让同系列不同卷得到唯一 bookKey（否则两卷 sanitize 后撞主键、被迫加 `(2)` 后缀）。缺 title
  /// 退化文件名（mokuro 惯例文件名即卷名，天然唯一）。
  ///
  /// 公开是给来源库扫描的网络去重预检用（SourceLibraryScanner 先读远端 `.mokuro`
  /// 派生标题、命中已入库即跳过整卷下载）：预检必须与导入器同一套身份派生，
  /// 不允许出现第二套判重规则。
  static String deriveMokuroTitle(
      Map<String, Object?> root, String mokuroPath) {
    final String title = (root['title'] as String?)?.trim() ?? '';
    final String volume = (root['volume'] as String?)?.trim() ?? '';
    final String base = p.basenameWithoutExtension(mokuroPath);
    if (title.isEmpty) return base.isNotEmpty ? base : 'manga';
    if (volume.isNotEmpty && !title.contains(volume)) return '$title $volume';
    return title;
  }
}
