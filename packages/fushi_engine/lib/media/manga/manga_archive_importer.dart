import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_series.dart'
    show encodeEpubSeriesMetadata;
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart'
    show ZipExtractionCap, ZipExtractionLimitException;

/// 解出总量预算的下限：小包（几十 MB 的 CBZ）按比例算出来的预算太紧，给一个固定底。
const int _minimumArchiveExpandedBytes = 2 * 1024 * 1024 * 1024;

/// 解出总量相对**压缩包自身大小**的最大倍数。
///
/// 总量上限防的是解压炸弹（几 MB 的包声明 / 解出几十 GB 填满磁盘），不是「漫画太大」。
/// 页图本身就是压缩格式（JPEG / PNG / WebP / AVIF），进 zip 几乎压不动，真实漫画包的
/// 解出量≈包体积；8 倍给 BMP / TIFF 这类能压的页留足余量，而炸弹的压缩比在几百到上千。
///
/// 此前这里是一个与包大小无关的绝对 2 GiB：任何解出超过 2 GiB 的正常漫画包（高分辨率
/// 合集、4K 扫图卷）一律报「Manga archive is too large」（不能导入 2G 以上的 zip）。
const int _maximumArchiveExpansionRatio = 8;

/// 单个页图条目解压后的上限。
///
/// 真实漫画页即便是 600 dpi 的跨页 PNG / 无损 WebP 也在几十 MB 量级；256 MB 给足
/// 余量，同时不让单个条目独吞 2 GB 总预算——超过它的「页」在下游解码 / 生成封面
/// 时本来也会把内存打爆，不是能读的页。
const int _maximumArchiveEntryBytes = 256 * 1024 * 1024;
const int _maximumMokuroBytes = 64 * 1024 * 1024;

/// zip 分支解压的字节上限（按**实际解出**的字节计，不按中央目录声明的大小）。
///
/// 生产路径一律用默认值；可注入只是为了让测试用小上限证明「超限立即中止」，
/// 而不必真的造几 GB 的包。
class MangaArchiveExtractionLimits {
  const MangaArchiveExtractionLimits({
    this.maxTotalBytes,
    this.maxEntryBytes = _maximumArchiveEntryBytes,
    this.minTotalBytes = _minimumArchiveExpandedBytes,
    this.maxExpansionRatio = _maximumArchiveExpansionRatio,
  });

  /// 一次导入里所有解出条目（页图 + 包内 `.mokuro`）的实际字节总和上限。
  ///
  /// null（生产默认）= 按压缩包大小推出：见 [totalBudgetFor]。
  final int? maxTotalBytes;

  /// 按包体积推预算时的下限（默认 2 GiB）。
  final int minTotalBytes;

  /// 按包体积推预算时的倍数（默认 8，见 [_maximumArchiveExpansionRatio]）。
  final int maxExpansionRatio;

  /// 单个页图条目的实际字节上限（包内 `.mokuro` 另受 64 MB 清单上限约束）。
  final int maxEntryBytes;

  /// 体积为 [archiveBytes] 的压缩包允许解出的总字节数：显式 [maxTotalBytes] 优先，
  /// 否则 `max(minTotalBytes, 包体积 × maxExpansionRatio)`。
  int totalBudgetFor(int archiveBytes) {
    final int? fixed = maxTotalBytes;
    if (fixed != null) return fixed;
    final int proportional = archiveBytes * maxExpansionRatio;
    return proportional > minTotalBytes ? proportional : minTotalBytes;
  }
}

/// 体积为 [archiveBytes] 的漫画压缩包默认允许解出的总字节数：
/// `max(2 GiB, 包体积 × 8)`（理由见 [_maximumArchiveExpansionRatio]）。ZIP 与 7-Zip
/// 两条分支、导入与探测共用这一个口径。
int mangaArchiveExpandedBudget(int archiveBytes) =>
    const MangaArchiveExtractionLimits().totalBudgetFor(archiveBytes);

class _MokuroSource {
  const _MokuroSource({
    required this.name,
    required this.json,
    required this.manifestDir,
    required this.preference,
  });

  final String name;
  final String json;
  final String manifestDir;
  final int preference;
}

class _MokuroArchiveCandidate {
  const _MokuroArchiveCandidate({
    required this.source,
    required this.payload,
    required this.root,
    required this.pageEntries,
    required this.score,
  });

  final _MokuroSource source;
  final MokuroPayload payload;

  /// 清单顶层对象（标题 / 卷号），与 [payload] 出自同一次解析（manga-29b）。
  final Map<String, Object?> root;
  final List<ArchiveFile> pageEntries;
  final int score;
}

class _ArchivePageSet {
  const _ArchivePageSet(this.entries, this.score);

  final List<ArchiveFile> entries;
  final int score;
}

/// 流式打开的 zip：[archive] 的条目内容惰性读自 [input]，所以 [input] 必须活到
/// 最后一次 `.content` 之后；[close] 关句柄并释放缓冲。
///
/// [headers] 把条目（以它的 `rawContent` 对象身份为键——`ArchiveFile` 构造时直接
/// 借用 `ZipFile.rawContent`，是同一个对象）映射回中央目录记录：流式解压要的本地
/// 头偏移 / 压缩方法 / 压缩大小 / 加密位只在那里，`ArchiveFile` 不公开它们。
class _OpenedArchive {
  _OpenedArchive(
    this.path,
    this.length,
    this.archive,
    this.input,
    this.headers,
  );

  final String path;
  final Archive archive;
  final InputFileStream input;
  final Map<InputStreamBase, ZipFileHeader> headers;

  /// 压缩包文件本身的字节数（解出总量预算按它推）。开包时从文件取：
  /// `InputFileStream.length` 是**剩余**字节数，读完中央目录后已不是包体积。
  final int length;

  ZipFileHeader? headerOf(ArchiveFile entry) {
    final InputStreamBase? raw = entry.rawContent;
    return raw == null ? null : headers[raw];
  }

  /// [entry] 的解压后大小，**以中央目录为准**。
  ///
  /// `ArchiveFile.size` 取自 `ZipFile.uncompressedSize`：带数据描述符（通用位 3）
  /// 的条目会被 archive 3.6.1 用描述符里读出的值覆盖，而它一律按 4 字节读——ZIP64
  /// 描述符的大小字段是 8 字节，读出来的「解压后大小」就成了压缩大小的高 32 位
  /// （通常是 0），流式解压随即按「超出声明大小」报损坏。中央目录（含 ZIP64 extra）
  /// 才是规范里的权威记录。
  int declaredSize(ArchiveFile entry) =>
      headerOf(entry)?.uncompressedSize ?? entry.size;

  /// [entry] 的 CRC-32，同 [declaredSize] 以中央目录为准。
  int? declaredCrc32(ArchiveFile entry) =>
      headerOf(entry)?.crc32 ?? entry.crc32;

  void close() {
    archive.clearSync();
    input.closeSync();
  }
}

/// 归一化名 → 条目的索引（大小写敏感 / 折叠两张表各建一次）。
///
/// mokuro 页匹配之前对每个候选根、每一页都线性扫全部图片条目，且在最内层循环里
/// 反复 `_normalizeArchiveName`（normalizeMangaUrl + 两个 RegExp + Uri.decode）：
/// 约 12·N² 次归一化，2000 页的卷是几千万次。这里每个条目只归一化一次。
class _ArchiveImageIndex {
  _ArchiveImageIndex(List<ArchiveFile> images) {
    for (final ArchiveFile image in images) {
      final String normalized = MangaArchiveImporter._normalizeArchiveName(
        image.name,
      );
      (exact[normalized] ??= <ArchiveFile>[]).add(image);
      (folded[normalized.toLowerCase()] ??= <ArchiveFile>[]).add(image);
    }
  }

  final Map<String, List<ArchiveFile>> exact = <String, List<ArchiveFile>>{};
  final Map<String, List<ArchiveFile>> folded = <String, List<ArchiveFile>>{};
}

const Set<String> _kSevenZipMangaArchiveExtensions = <String>{
  '.rar',
  '.cbr',
  '.cb7',
};

/// 走 `package:archive` ZIP 容器分支的扩展名（带点、小写）：只有这一路读包内 /
/// 包旁的 `.mokuro` 文字层，7-Zip 分支不读（见 [MangaArchiveImporter.importArchive]）。
const Set<String> kMangaZipContainerExtensions = <String>{
  '.cbz',
  '.zip',
  '.epub',
};

/// [MangaArchiveImporter.importArchive] 能把它当「一整卷」导入的单文件扩展名
/// （带点、小写）。app 的手动导入载体表、来源库扫描与无头服务端库扫描都从这里取，
/// 不各自手抄——此前来源库扫描只抄了 `rar` / `cbr` / `cb7`，漫画来源里的
/// `.cbz` / `.zip` 卷全被静默跳过。
///
/// `.zip` / `.epub` 光看扩展名分不清是不是页图包（词典包 / 文字书同形），批量
/// 收录前必须先过 [MangaArchiveImporter.looksLikeImageArchive]。
const Set<String> kMangaArchiveFileExtensions = <String>{
  ...kMangaZipContainerExtensions,
  ..._kSevenZipMangaArchiveExtensions,
};

/// [archivePath] 旁边可能的 `.mokuro` sidecar 路径：`book.mokuro`（换扩展名）与
/// `book.cbz.mokuro`（追加扩展名，少数工具这么写），精确同名，不做模糊匹配——
/// 否则一个批量目录会把第 1 卷绑到相邻第 2 卷的 manifest 上。
///
/// 只对 [kMangaZipContainerExtensions] 有意义。导入器自己按这份列表找 sidecar；
/// 扫描规划层用同一份列表把这些 `.mokuro` 划给包、不再另当一卷导入，两边才不会
/// 一边说「它属于包」一边又没读到它。[context] 给网络来源传 `p.url`。
List<String> mangaArchiveMokuroSidecarPaths(
  String archivePath, {
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final List<String> paths = <String>[];
  for (final String candidate in <String>[
    ctx.setExtension(archivePath, '.mokuro'),
    '$archivePath.mokuro',
  ]) {
    if (!paths.contains(candidate)) paths.add(candidate);
  }
  return paths;
}

/// Yomitan/Yomichan 词典包的**结构**标记：包根下的数据库文件名前缀。
///
/// 与 C++ 导入器 `native/fushidicts/fushidicts_src/importer.cpp` 的
/// `get_files()` 用同一组前缀（`term_bank_` / `kanji_bank_` /
/// `term_meta_bank_` / `kanji_meta_bank_` / `tag_bank_`）——判据只有一处真相，
/// 这里不自创第二套。
const List<String> _kYomitanBankPrefixes = <String>[
  'term_bank_',
  'kanji_bank_',
  'term_meta_bank_',
  'kanji_meta_bank_',
  'tag_bank_',
];

/// Yomitan 词典包的清单文件名（包根）。`prepareNameYomichanFormat` 就靠它读
/// 词典标题。
const String _kYomitanIndexEntry = 'index.json';

/// 7-Zip-backed extractor for RAR/CBR/CB7 comic archives.
///
/// Windows releases bundle `7za.exe`; macOS/Linux may use `7za`/`7z` from
/// PATH. The listing pass validates every member path and sums image sizes
/// before extraction, while include filters ensure non-image payloads are
/// never written to the temporary directory.
class MangaSevenZipExtractor {
  MangaSevenZipExtractor({
    DiscoveryProcessRunner? runProcess,
    String? sevenZipOverride,
  }) : _runProcess = runProcess ?? Process.run,
       _locator = DiscoveryArchiveExtractor(
         runProcess: runProcess,
         sevenZipOverride: sevenZipOverride,
       );

  final DiscoveryProcessRunner _runProcess;
  final DiscoveryArchiveExtractor _locator;

  /// 把 [archivePath] 里的页图解进 [staging]，返回解出的页图个数。
  Future<int> extractImages({
    required String archivePath,
    required Directory staging,
  }) async {
    final String? sevenZip = await _locator.findSevenZip();
    if (sevenZip == null) {
      throw const MangaImportException(
        'RAR/CBR/CB7 import requires 7-Zip (7za or 7z)',
      );
    }

    final ProcessResult listing = await _runProcess(sevenZip, <String>[
      'l',
      '-slt',
      '-sccUTF-8',
      '-p-',
      archivePath,
    ]);
    if (listing.exitCode != 0) {
      throw MangaImportException(
        'Could not list manga archive (7z exit ${listing.exitCode})',
      );
    }
    final int budget = mangaArchiveExpandedBudget(
      await File(archivePath).length(),
    );
    _validateListing(listing.stdout.toString(), budget);

    final List<String> imageFilters = <String>[
      for (final String extension in kMangaImageExtensions) '-ir!*$extension',
    ];
    final ProcessResult extraction = await _runProcess(sevenZip, <String>[
      'x',
      '-y',
      '-aoa',
      '-p-',
      '-sccUTF-8',
      '-ssc-',
      '-smemx2g',
      '-o${staging.path}',
      ...imageFilters,
      archivePath,
    ]);
    if (extraction.exitCode != 0) {
      throw MangaImportException(
        'Could not extract manga archive (7z exit ${extraction.exitCode})',
      );
    }
    return _validateExtractedImages(staging, budget);
  }

  void _validateListing(String output, int budget) {
    final String normalized = output.replaceAll('\r\n', '\n');
    final int marker = normalized.indexOf('\n----------\n');
    if (marker < 0) {
      throw const MangaImportException('Could not parse 7-Zip archive listing');
    }
    final String records = normalized.substring(marker + 12);
    int imageCount = 0;
    int expandedImageBytes = 0;
    for (final String block in records.split(RegExp(r'\n\s*\n'))) {
      final Map<String, String> fields = <String, String>{};
      for (final String line in block.split('\n')) {
        final int separator = line.indexOf(' = ');
        if (separator <= 0) continue;
        fields[line.substring(0, separator)] = line.substring(separator + 3);
      }
      final String? entryPath = fields['Path'];
      if (entryPath == null || entryPath.isEmpty) continue;
      if (sanitizeArchiveEntryPath(entryPath) == null ||
          fields.containsKey('Symbolic Link')) {
        throw MangaImportException('Unsafe manga archive entry: $entryPath');
      }
      final String attributes = fields['Attributes'] ?? '';
      if (attributes.toUpperCase().contains('D')) continue;
      final String extension = p.posix
          .extension(entryPath.replaceAll('\\', '/'))
          .toLowerCase();
      if (!kMangaImageExtensions.contains(extension)) continue;
      final int? size = int.tryParse(fields['Size'] ?? '');
      if (size == null || size < 0) {
        throw MangaImportException(
          'Invalid manga archive entry size: $entryPath',
        );
      }
      expandedImageBytes += size;
      if (expandedImageBytes > budget) {
        throw const MangaImportException('Manga archive is too large');
      }
      imageCount++;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }

  Future<int> _validateExtractedImages(Directory staging, int budget) async {
    int imageCount = 0;
    int expandedImageBytes = 0;
    await for (final FileSystemEntity entity in staging.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw MangaImportException('Unsafe manga archive link: ${entity.path}');
      }
      if (entity is! File ||
          !kMangaImageExtensions.contains(
            p.extension(entity.path).toLowerCase(),
          )) {
        continue;
      }
      expandedImageBytes += await entity.length();
      if (expandedImageBytes > budget) {
        throw const MangaImportException('Manga archive is too large');
      }
      imageCount++;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
    return imageCount;
  }
}

/// 扩展名是漫画载体、内容却不是漫画（文字 `.epub`）——由导入阶段自己的判据给出。
///
/// 与其它 [MangaImportException]（坏包、超限、缺页）分开，是因为批量导入不再对
/// `.epub` 预定性（manga-3），「不是漫画」只能从导入这一步得知；汇总里它要计为
/// 跳过（不是漫画），而不是导入失败。
class MangaArchiveNotMangaException extends MangaImportException {
  /// 用可读 [message] 构造。
  const MangaArchiveNotMangaException(super.message);
}

abstract final class MangaArchiveImporter {
  /// [book]（已解压的 EPUB）是不是「纯图漫画」：每个 `linear && !isNav` 章节都只有
  /// 图片、且图片扩展名都在 [kMangaImageExtensions] 内。
  ///
  /// 公开是因为「一本已在库的 EPUB 能不能转成漫画」问的是同一个问题，而那本书在
  /// 盘上**只有解压树、没有独立 `.epub`**（BUG-088），走不了 [looksLikeImageArchive]
  /// 的压缩包入口。判据只能有一份，否则「导入时算漫画、转化时不算」这种自相矛盾
  /// 迟早出现。
  static bool isPureImageEpub(EpubBook book) => _isPureImageEpub(book);

  /// 按 spine 顺序把 [book] 的页图铺进 [staging]（`page_%06d.<ext>` 自然序）。
  ///
  /// 与 [isPureImageEpub] 同理公开：导入压缩包与「就地把书转成漫画」必须产出同一
  /// 批页、同一种排序，否则同一本书从两条路进来页序不同。
  static Future<void> copyEpubPages(EpubBook book, Directory staging) =>
      _copyEpubPages(book, staging);

  /// [epubProbeDir]：`.epub` 定性探测的解压落点，见 [imageEpubRejection]。
  static bool looksLikeImageArchive(
    String archivePath, {
    String? epubProbeDir,
  }) {
    final String extension = p.extension(archivePath).toLowerCase();
    if (_kSevenZipMangaArchiveExtensions.contains(extension)) {
      return true;
    }
    if (extension == '.epub') {
      return _looksLikeImageEpub(archivePath, probeDir: epubProbeDir);
    }
    _OpenedArchive? opened;
    try {
      opened = _open(archivePath);
      final Archive archive = opened.archive;
      bool hasImage = false;
      bool hasDictionaryIndex = false;
      bool hasDictionaryBank = false;
      bool hasMokuro = false;
      bool hasMarkup = false;
      for (final ArchiveFile entry in archive) {
        _validateEntry(entry);
        if (!entry.isFile) continue;
        final String name = entry.name;
        if (name == _kYomitanIndexEntry) {
          hasDictionaryIndex = true;
          continue;
        }
        if (_kYomitanBankPrefixes.any(name.startsWith)) {
          hasDictionaryBank = true;
          continue;
        }
        final String extension = p.extension(name).toLowerCase();
        if (extension == '.mokuro') {
          hasMokuro = true;
          continue;
        }
        if (kMangaImageExtensions.contains(extension)) {
          hasImage = true;
        } else if (<String>{
          '.opf',
          '.xhtml',
          '.html',
          '.htm',
        }.contains(extension)) {
          hasMarkup = true;
        }
      }
      // 词典包一票否决，优先于「有图片就算漫画」。
      //
      // Yomitan 允许词典**自带图片**（structured-content 的 `image` 节点；C++
      // 导入器 `get_files()` 把非 bank/非 index.json 的条目一律收成
      // `media_files`）。只看「包里有没有图片」的话，一本带插图的词典包会被判成
      // 图片包：拖进书架 → 静默导成一本只有插图的垃圾「漫画」，而词典**根本没
      // 被导入**。那是用户数据被糟蹋，比多点两下严重得多。
      //
      // 判据要 index.json **和**至少一个 `*_bank_*.json` 同时在场：单有
      // index.json 不算（打包工具随手生成的清单也叫这名），bank 前缀才是
      // Yomitan 独有的结构指纹。
      if (hasDictionaryIndex && hasDictionaryBank) {
        return false;
      }
      // Mokuro legacy bundles commonly retain the generated HTML/CSS/JS next
      // to the modern `.mokuro` payload. The manifest is a stronger manga
      // signal than those compatibility files are a text-book signal.
      return hasImage && (hasMokuro || !hasMarkup);
    } catch (e) {
      // 打不开的包在导入框里表现为「不支持的文件格式 .zip」——此前这里静默 false，
      // 反馈日志里没有任何导入相关条目（Shift_JIS 文件名的包就是这样无声失败的）。
      engineLog.logDiagnostic(
        'MangaArchiveImporter',
        'ZIP not recognised as image manga: ${p.basename(archivePath)}: '
            'probe failed: $e',
      );
      return false;
    } finally {
      opened?.close();
    }
  }

  static Future<String> importArchive({
    required FushiDatabase db,
    required String archivePath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
    int? sourceId,
    MangaSevenZipExtractor? sevenZipExtractor,
    MangaArchiveExtractionLimits limits = const MangaArchiveExtractionLimits(),
  }) async {
    final String extension = p.extension(archivePath).toLowerCase();
    // 入库标题在任何解压之前就定得下来（调用方给的标题，缺省为文件名）；mokuro 与
    // 页图目录两条落库分支拿的是同一个值，下面的预检与落位判重因此看的是同一个名字。
    final String volumeTitle =
        (title?.trim().isNotEmpty == true
                ? title!
                : p.basenameWithoutExtension(archivePath))
            .trim();
    // 跳过策略先判重再解压（manga-10）：重导一个大半已入库的文件夹时，已有的卷
    // 不再整包解压、读完每页才被跳过。
    if (volumeTitle.isNotEmpty) {
      await MangaImporter.precheckSkippedDuplicate(
        db: db,
        proposedTitle: volumeTitle,
        policy: policy,
      );
    }
    _OpenedArchive? opened;
    _ZipEntryStreamer? streamer;
    // 暂存在书库根下的 `.tmp-*`（BUG-4840），不放系统临时目录：与书目录同卷，页图
    // 进书目录是 rename 而不是「跨卷拷贝 + 删源」；崩溃留下的残留也归导入残留清扫管
    // （桌面端系统临时目录里的残留，app 内既看不见也清不掉）。
    final Directory staging = Directory(
      await EpubImporter.createStagingDir(db),
    );
    Directory? epubExtraction;
    // 纯图 EPUB 的 OPF 系列声明（见 [MangaImporter.importFromImageFolder] 的
    // `sourceMetadata`）；其它载体没有 OPF，保持 null。
    String? epubSeriesMetadata;
    // 进度总量 = 解压 + 入库（manga-29a）：此前只有最后的入库阶段报进度，解压一个
    // 大包时进度条一直停在 0。
    final _ArchiveImportProgress progress = _ArchiveImportProgress(onProgress);
    try {
      if (_kSevenZipMangaArchiveExtensions.contains(extension)) {
        // 7-Zip 一次进程调用解完，中途没有逐条进度；解完按页数一次推满解压段。
        final int extracted =
            await (sevenZipExtractor ?? MangaSevenZipExtractor()).extractImages(
              archivePath: archivePath,
              staging: staging,
            );
        progress.beginExtraction(extracted, expectedPages: extracted);
        progress.finishExtraction();
      } else {
        opened = _open(archivePath, decodeLegacyNames: true);
        final Archive archive = opened.archive;
        // 中央目录声明的大小只能当**快速预检**：它可以谎报（声明 1 KB、实际
        // inflate 出几 GB）。真正的上限在 [_ZipEntryStreamer] 里按实际解出的
        // 字节强制执行，条目也是边解边写盘、不整条进内存。
        final int budget = limits.totalBudgetFor(opened.length);
        int expandedBytes = 0;
        for (final ArchiveFile entry in archive) {
          _validateEntry(entry);
          expandedBytes += opened.declaredSize(entry);
          if (expandedBytes > budget) {
            throw const MangaImportException('Manga archive is too large');
          }
        }
        final _ZipEntryStreamer entries = streamer =
            await _ZipEntryStreamer.open(opened, limits);

        // A Mokuro CBZ/ZIP is still an image archive, but its `.mokuro` member
        // is the authoritative selectable-text layer. The old path discarded
        // every non-image member and rebuilt an empty payload, permanently
        // throwing away OCR that the user had already generated.
        //
        // Resolve the manifest before extraction, then materialise the matched
        // pages under the manifest's own `img_path` names. This normalisation
        // makes root-level, wrapper-directory, `<volume>/`, Windows-separator,
        // and consistently wrapped repacks all enter the existing, hardened
        // mokuro import pipeline without teaching that pipeline about ZIP
        // containers. Once a manifest is present, malformed, missing-page,
        // and ambiguous layouts fail loudly instead of repeating the original
        // silent OCR data loss.
        //
        // 这一段**只在 ZIP 分支内**：`_findMokuroCandidate` 吃的是 `package:archive`
        // 解出来的 `Archive`，而 RAR/CBR/CB7 走上面的 7-Zip 分支、根本没有 `Archive`
        // 对象。把它放在分支外对可空 `archive` 做隐式判断只会把「7z 包里的 mokuro
        // 不被识别」这个能力空洞伪装成已支持（见 docs/bugs/BUG-2018）。
        final _MokuroArchiveCandidate? mokuro = await _findMokuroCandidate(
          archive,
          archivePath,
          entries,
        );
        if (mokuro != null) {
          progress.beginExtraction(
            mokuro.pageEntries.length,
            expectedPages: mokuro.payload.images.length,
          );
          await _extractMokuroCandidate(mokuro, staging, entries, progress);
          progress.finishExtraction();
          // 清单在 [_findMokuroCandidate] 里已经解析过一次，直接把解析结果交下去
          // （manga-29b）：此前要先写回 staging、再由 importFromMokuroPath 读盘重新
          // parseMokuro + jsonDecode 顶层，一份清单解析三遍。
          return await MangaImporter.importMokuroDocument(
            db: db,
            document: (payload: mokuro.payload, root: mokuro.root),
            // 只用来定位页图根（卷名）与回退标题，文件本身不必存在。
            mokuroPath: p.join(
              staging.path,
              '${p.basenameWithoutExtension(archivePath)}.mokuro',
            ),
            title: volumeTitle.isNotEmpty
                ? volumeTitle
                : p.basenameWithoutExtension(archivePath),
            policy: policy,
            onProgress: progress.ingest,
            sourceId: sourceId,
            // staging 是本函数自己建、finally 里整个删掉的目录。
            pageSource: MangaPageSource.disposable,
          );
        }

        if (extension == '.epub') {
          final int imageEntries = _imageEntryCount(archive);
          if (imageEntries == 0) {
            _rejectEpub(archivePath, 'no image entries in the archive');
          }
          epubExtraction = Directory(await EpubImporter.createStagingDir(db));
          progress.beginExtraction(
            archive.where((ArchiveFile e) => e.isFile).length,
            expectedPages: imageEntries,
          );
          // HBK-AUDIT-013：解析、解压、定性、页图清单与挪页整段在一次后台 isolate
          // 里做，中央目录与 OPF / spine 各只读 / 解析一次。此前在调用 isolate（App
          // 里是 UI isolate）上同步跑两遍 parseSyncFromPath，再在 UI isolate 上逐章
          // 扫页图引用，几百页的整卷导入期间界面卡住。
          final ({String? rejection, String? seriesMetadata}) staged =
              await _stageImageEpubInBackground(
                archivePath: archivePath,
                extractionPath: epubExtraction.path,
                stagingPath: staging.path,
                maxTotalBytes: budget,
                maxEntryBytes: limits.maxEntryBytes,
                onEntryExtracted: progress.entryExtracted,
              );
          final String? rejection = staged.rejection;
          if (rejection != null) _rejectEpub(archivePath, rejection);
          progress.finishExtraction();
          epubSeriesMetadata = staged.seriesMetadata;
        } else {
          final int images = _imageEntryCount(archive);
          progress.beginExtraction(images, expectedPages: images);
          await _extractArchiveImages(archive, staging, entries, progress);
          progress.finishExtraction();
        }
      }

      return await MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: staging.path,
        title: volumeTitle.isNotEmpty
            ? volumeTitle
            : p.basenameWithoutExtension(archivePath),
        policy: policy,
        onProgress: progress.ingest,
        sourceId: sourceId,
        sourceMetadata: epubSeriesMetadata,
        pageSource: MangaPageSource.disposable,
      );
    } finally {
      // 先关源包句柄（中途抛出时正在写的页文件句柄已在
      // [_ZipEntryStreamer.extractToFile] 自己的 finally 里关掉），再删 staging：
      // 超限 / 损坏中止时写了一半的页随 staging 一起删掉，Windows 上也不会因句柄
      // 未关而删不掉。
      await streamer?.close();
      opened?.close();
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      final Directory? extraction = epubExtraction;
      if (extraction != null && extraction.existsSync()) {
        await extraction.delete(recursive: true);
      }
    }
  }

  /// 纯图 EPUB 整卷导入的 EPUB 段（HBK-AUDIT-013）：在 [extractionPath] 下读一次中央
  /// 目录、先只解 container / OPF / spine 文档并解析一次，判纯图（manga-3：文字
  /// EPUB 在页图落盘之前就被否决，不为一本小说把几百 MB 插图写进暂存）；是漫画才用
  /// **同一份**中央目录与解析结果补解页图，按 spine 顺序把页图挪进 [stagingPath]
  /// （`page_NNNNNN.<ext>`）。
  ///
  /// 返回否决理由（null = 是纯图漫画、页图已就位）与 OPF 系列声明
  /// （[encodeEpubSeriesMetadata]）。只碰文件、不碰数据库与日志装配点，可在后台
  /// isolate 里跑（[importArchive] 经 [_stageImageEpubInBackground] 调它）；直接调
  /// 只供测试计数。
  ///
  /// [maxTotalBytes] / [maxEntryBytes]：与 ZIP 分支同一套「按实际解出字节」的上限
  /// （manga-23），两段共用同一个 [ZipExtractionCap]（按累计字节计），总量仍是一份
  /// 预算；超限抛 [MangaImportException]。
  ///
  /// BUG-3845：SVG 内容文档作 spine 的固定版式漫画也收成页（与 [imageEpubRejection]
  /// 同一解析口径，判得成就导得进）。
  @visibleForTesting
  static Future<({String? rejection, String? seriesMetadata})> stageImageEpub({
    required String archivePath,
    required String extractionPath,
    required String stagingPath,
    required int maxTotalBytes,
    required int maxEntryBytes,
    required void Function() onEntryExtracted,
  }) async {
    final ZipExtractionCap cap = ZipExtractionCap(
      maxTotalBytes: maxTotalBytes,
      maxEntryBytes: maxEntryBytes,
    );
    final EpubStagedExtraction extraction;
    try {
      extraction = EpubParser.openStagedFromPath(
        archivePath,
        extractionPath,
        includeSvgSpineDocuments: true,
        cap: cap,
        deferEntry: _isPageImageEntry,
        onEntryExtracted: onEntryExtracted,
      );
    } on ZipExtractionLimitException catch (e) {
      throw MangaImportException('Manga archive is too large (${e.message})');
    }
    try {
      final EpubBook book = extraction.book;
      final String? rejection = _pureImageEpubRejection(book);
      if (rejection != null) {
        return (rejection: rejection, seriesMetadata: null);
      }
      try {
        extraction.extractDeferred();
      } on ZipExtractionLimitException catch (e) {
        throw MangaImportException('Manga archive is too large (${e.message})');
      }
      // 挪页之前先关源包句柄。解压树本次独占、导入完即删：页图直接挪进 staging
      // （同卷一次 rename），不再「读进内存再写一遍」（manga-23）。
      extraction.close();
      await _copyEpubPages(
        book,
        Directory(stagingPath),
        moveFromExtraction: true,
      );
      return (
        rejection: null,
        seriesMetadata: encodeEpubSeriesMetadata(book.series),
      );
    } finally {
      extraction.close();
    }
  }

  /// 在一次性后台 isolate 里跑 [stageImageEpub]。每落盘一个条目经端口回调一次
  /// [onEntryExtracted]（解压段进度逐条推进）；返回前把端口里的进度事件收完。
  static Future<({String? rejection, String? seriesMetadata})>
  _stageImageEpubInBackground({
    required String archivePath,
    required String extractionPath,
    required String stagingPath,
    required int maxTotalBytes,
    required int maxEntryBytes,
    required void Function() onEntryExtracted,
  }) async {
    final ReceivePort events = ReceivePort('manga-epub-stage-progress');
    final Completer<void> drained = Completer<void>();
    events.listen((Object? message) {
      if (message == null) {
        drained.complete();
      } else {
        onEntryExtracted();
      }
    });
    try {
      final ({String? rejection, String? seriesMetadata}) result =
          await _runStageImageEpubIsolate(
            archivePath: archivePath,
            extractionPath: extractionPath,
            stagingPath: stagingPath,
            maxTotalBytes: maxTotalBytes,
            maxEntryBytes: maxEntryBytes,
            progress: events.sendPort,
          );
      // 同一端口 FIFO：结束标记之前的进度事件都已投递。
      await drained.future;
      return result;
    } finally {
      events.close();
    }
  }

  /// [Isolate.run] 的闭包单独放在只有可跨 isolate 参数的函数里：与
  /// [_stageImageEpubInBackground] 里捕获 [Completer] / 回调的监听闭包不共享上下文。
  static Future<({String? rejection, String? seriesMetadata})>
  _runStageImageEpubIsolate({
    required String archivePath,
    required String extractionPath,
    required String stagingPath,
    required int maxTotalBytes,
    required int maxEntryBytes,
    required SendPort progress,
  }) => Isolate.run(() async {
    try {
      return await stageImageEpub(
        archivePath: archivePath,
        extractionPath: extractionPath,
        stagingPath: stagingPath,
        maxTotalBytes: maxTotalBytes,
        maxEntryBytes: maxEntryBytes,
        onEntryExtracted: () => progress.send(true),
      );
    } finally {
      progress.send(null);
    }
  }, debugName: 'manga-epub-stage');

  /// [archive] 里页图条目（扩展名在 [kMangaImageExtensions] 内的文件）的个数。
  static int _imageEntryCount(Archive archive) {
    int count = 0;
    for (final ArchiveFile entry in archive) {
      if (entry.isFile &&
          kMangaImageExtensions.contains(
            p.extension(entry.name).toLowerCase(),
          )) {
        count += 1;
      }
    }
    return count;
  }

  static Future<void> _extractArchiveImages(
    Archive archive,
    Directory staging,
    _ZipEntryStreamer entries,
    _ArchiveImportProgress progress,
  ) async {
    int imageCount = 0;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile ||
          !kMangaImageExtensions.contains(
            p.extension(entry.name).toLowerCase(),
          )) {
        continue;
      }
      final List<String> segments = entry.name
          .replaceAll('\\', '/')
          .split('/')
          .where((String part) => part.isNotEmpty && part != '.')
          .toList();
      final File output = File(p.joinAll(<String>[staging.path, ...segments]));
      await output.parent.create(recursive: true);
      await entries.extractToFile(entry, output);
      progress.entryExtracted();
      imageCount += 1;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }

  static Future<_MokuroArchiveCandidate?> _findMokuroCandidate(
    Archive archive,
    String archivePath,
    _ZipEntryStreamer entries,
  ) async {
    final String archiveStem = p.basenameWithoutExtension(archivePath);
    final List<_MokuroSource> sources = <_MokuroSource>[];
    bool foundMokuro = false;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile || p.extension(entry.name).toLowerCase() != '.mokuro') {
        continue;
      }
      // 清单 JSON 同样流式读、按实际字节封顶 64 MB，并核对 CRC 与声明大小：超限 /
      // 坏清单会让页匹配整体失败，早点当「不是候选」跳过（与原先的 CRC 跳过同义）。
      final Uint8List? content = await entries.readManifest(
        entry,
        _maximumMokuroBytes,
      );
      if (content == null) continue;
      final String normalizedName = _normalizeArchiveName(entry.name);
      final List<String> nameSegments = normalizedName.split('/');
      if (nameSegments.any(
            (String segment) => segment.toLowerCase() == '__macosx',
          ) ||
          p.posix.basename(normalizedName).startsWith('._')) {
        continue;
      }
      foundMokuro = true;
      final String manifestStem = p.posix.basenameWithoutExtension(
        normalizedName,
      );
      try {
        sources.add(
          _MokuroSource(
            name: normalizedName,
            json: utf8.decode(content),
            manifestDir: _archiveDirname(normalizedName),
            preference: manifestStem.toLowerCase() == archiveStem.toLowerCase()
                ? 1200
                : 100,
          ),
        );
      } on FormatException {
        // Reported below if no other valid manifest can represent the volume.
      }
    }

    // Readers in the wild use both self-contained CBZs and the older
    // `book.cbz` + `book.mokuro` sidecar layout. Only exact archive-name
    // sidecars are considered, so a batch directory cannot bind vol. 1 to a
    // neighbouring vol. 2 manifest. Also accept `book.cbz.mokuro`, used by a
    // few tools that append rather than replace the extension.
    final List<String> sidecarPaths = mangaArchiveMokuroSidecarPaths(
      archivePath,
    );
    final Set<String> seenSidecars = <String>{};
    for (final String sidecarPath in sidecarPaths) {
      if (!seenSidecars.add(p.normalize(sidecarPath))) continue;
      final File sidecar = File(sidecarPath);
      if (!sidecar.existsSync()) continue;
      foundMokuro = true;
      if (sidecar.lengthSync() > _maximumMokuroBytes) continue;
      try {
        sources.add(
          _MokuroSource(
            name: p.basename(sidecarPath),
            json: sidecar.readAsStringSync(),
            manifestDir: '',
            preference: sidecarPath == sidecarPaths.first ? 1100 : 1000,
          ),
        );
      } on FormatException {
        // Reported below if no other valid manifest can represent the volume.
      }
    }

    final List<ArchiveFile> images = <ArchiveFile>[
      for (final ArchiveFile entry in archive)
        if (entry.isFile &&
            kMangaImageExtensions.contains(
              p.extension(entry.name).toLowerCase(),
            ))
          entry,
    ];
    final List<_MokuroArchiveCandidate> candidates =
        <_MokuroArchiveCandidate>[];
    for (final _MokuroSource source in sources) {
      try {
        final MokuroDocument document = parseMokuroDocument(source.json);
        final MokuroPayload payload = document.payload;
        if (payload.images.isEmpty) continue;
        final _ArchivePageSet? pages = _matchArchivePages(
          images,
          source: source,
          payload: payload,
        );
        if (pages != null) {
          candidates.add(
            _MokuroArchiveCandidate(
              source: source,
              payload: payload,
              root: document.root,
              pageEntries: pages.entries,
              score: source.preference + pages.score,
            ),
          );
        }
      } on FormatException {
        // Reported below if no other valid manifest can represent the volume.
      }
    }
    if (candidates.isEmpty) {
      if (foundMokuro) {
        throw const MangaImportException(
          'Mokuro OCR metadata is invalid or does not match the archive pages',
        );
      }
      return null;
    }
    candidates.sort((_MokuroArchiveCandidate a, _MokuroArchiveCandidate b) {
      final int byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.source.name.compareTo(b.source.name);
    });
    if (candidates.length > 1 && candidates[0].score == candidates[1].score) {
      throw const MangaImportException(
        'Mokuro archive contains multiple equally matching manifests',
      );
    }
    return candidates.first;
  }

  static _ArchivePageSet? _matchArchivePages(
    List<ArchiveFile> images, {
    required _MokuroSource source,
    required MokuroPayload payload,
  }) {
    final List<String> pageUrls = <String>[
      for (final MokuroImage page in payload.images)
        _normalizeArchiveName(page.url),
    ];
    if (pageUrls.any((String url) => url.isEmpty)) return null;
    final String manifestStem = p.posix.basenameWithoutExtension(source.name);
    final List<({String root, int score})> roots = <({String root, int score})>[
      (root: source.manifestDir, score: 500),
      if (source.manifestDir.isNotEmpty && manifestStem.isNotEmpty)
        (root: '${source.manifestDir}/$manifestStem', score: 490),
      (root: '', score: 480),
      if (manifestStem.isNotEmpty) (root: manifestStem, score: 470),
      if (source.manifestDir.isNotEmpty)
        (root: '${source.manifestDir}/images', score: 450),
      (root: 'images', score: 440),
    ];

    // Infer arbitrary wrapper roots from the first page, but keep one root for
    // the whole book. This supports repacks without ever matching each page
    // from a different volume directory.
    final String firstUrl = pageUrls.first;
    for (final ArchiveFile image in images) {
      final String name = _normalizeArchiveName(image.name);
      if (name == firstUrl) continue;
      final String suffix = '/$firstUrl';
      if (name.endsWith(suffix)) {
        roots.add((
          root: name.substring(0, name.length - suffix.length),
          score: 400,
        ));
      }
    }

    final Map<String, int> uniqueRoots = <String, int>{};
    for (final ({String root, int score}) candidate in roots) {
      final String root = candidate.root
          .replaceAll(RegExp(r'/+'), '/')
          .replaceAll(RegExp(r'^/|/$'), '');
      final int? previous = uniqueRoots[root];
      if (previous == null || candidate.score > previous) {
        uniqueRoots[root] = candidate.score;
      }
    }

    final List<_ArchivePageSet> matches = <_ArchivePageSet>[];
    final _ArchiveImageIndex index = _ArchiveImageIndex(images);
    uniqueRoots.forEach((String root, int rootScore) {
      final List<ArchiveFile>? exact = _pagesAtRoot(
        index,
        root: root,
        pageUrls: pageUrls,
        caseSensitive: true,
      );
      if (exact != null) {
        matches.add(_ArchivePageSet(exact, rootScore));
        return;
      }
      final List<ArchiveFile>? folded = _pagesAtRoot(
        index,
        root: root,
        pageUrls: pageUrls,
        caseSensitive: false,
      );
      if (folded != null) {
        matches.add(_ArchivePageSet(folded, rootScore - 20));
      }
    });
    if (matches.isEmpty) return null;
    matches.sort(
      (_ArchivePageSet a, _ArchivePageSet b) => b.score.compareTo(a.score),
    );
    if (matches.length > 1 && matches[0].score == matches[1].score) {
      return null;
    }
    return matches.first;
  }

  static List<ArchiveFile>? _pagesAtRoot(
    _ArchiveImageIndex index, {
    required String root,
    required List<String> pageUrls,
    required bool caseSensitive,
  }) {
    final List<ArchiveFile> matches = <ArchiveFile>[];
    final Set<ArchiveFile> used = <ArchiveFile>{};
    for (final String pageUrl in pageUrls) {
      final String expected = root.isEmpty ? pageUrl : '$root/$pageUrl';
      final List<ArchiveFile> found = caseSensitive
          ? index.exact[expected] ?? const <ArchiveFile>[]
          : index.folded[expected.toLowerCase()] ?? const <ArchiveFile>[];
      if (found.length != 1 || !used.add(found.single)) return null;
      matches.add(found.single);
    }
    return matches;
  }

  static Future<void> _extractMokuroCandidate(
    _MokuroArchiveCandidate candidate,
    Directory staging,
    _ZipEntryStreamer entries,
    _ArchiveImportProgress progress,
  ) async {
    for (int index = 0; index < candidate.payload.images.length; index++) {
      final MokuroImage page = candidate.payload.images[index];
      final ArchiveFile entry = candidate.pageEntries[index];
      // 铺出来的目录随后原样交给 importFromMokuroPath 解析，所以落盘名必须与那一侧
      // 的读取口径（MangaImporter.mokuroPageFile，纯按原始 img_path 拆段）逐字节
      // 同构。这里曾用 MangaStorage.sanitizeRelSegments —— 它是**书目录内**的
      // destRel 口径：会剥掉前导 `images/` 段、还会用 safeWindowsFileName 改写字符，
      // 于是 `img_path: images/001.png` 被写成 `<staging>/001.png`，读取侧却去找
      // `<staging>/images/001.png`，整卷导入必报 Missing manga page image。
      // 防穿越不靠那次 sanitize：`..` 在这里显式拒绝。
      if (_hasTraversalSegment(page.url)) {
        throw MangaImportException(
          'Unsafe manga image path (traversal): ${page.url}',
        );
      }
      final File output = MangaImporter.mokuroPageFile(staging.path, page.url);
      await output.parent.create(recursive: true);
      await entries.extractToFile(entry, output);
      progress.entryExtracted();
    }
  }

  /// `img_path` 是否含 `..` 段（与 [MangaStorage.sanitizeRelSegments] 同判据，
  /// 拆段规则与 [MangaImporter.mokuroPageFile] 保持一致）。
  static bool _hasTraversalSegment(String rawUrl) => rawUrl
      .split(RegExp(r'[\\/]+'))
      .any((String segment) => segment.trim() == '..');

  static String _normalizeArchiveName(String raw) {
    String normalized = normalizeMangaUrl(raw).replaceAll(RegExp(r'^\./+'), '');
    try {
      normalized = Uri.decodeComponent(normalized);
    } on ArgumentError {
      // Keep the literal name; invalid percent escapes may still be valid ZIP
      // entry characters and can be matched byte-for-byte.
    } on FormatException {
      // Same, for escapes that are syntactically valid but decode to invalid
      // UTF-8 (`%FF`): ArgumentError does not cover those.
    }
    return normalized;
  }

  static String _archiveDirname(String normalizedName) {
    final String dirname = p.posix.dirname(normalizedName);
    return dirname == '.' ? '' : dirname;
  }

  static bool _looksLikeImageEpub(String archivePath, {String? probeDir}) {
    final String? rejection = imageEpubRejection(
      archivePath,
      probeDir: probeDir,
    );
    if (rejection != null) logEpubRejection(archivePath, rejection);
    return rejection == null;
  }

  /// 测试计数：[imageEpubRejection]（纯图 EPUB 定性探测）被调用的次数。用来钉
  /// 「批量导入不对 `.epub` 预定性」（manga-3）——判据交给导入阶段的那一遍解析，
  /// 探测次数应为 0。只在本 isolate 内计数。
  @visibleForTesting
  static int debugEpubProbeCount = 0;

  /// `.epub` 是不是纯图漫画的**定性探测**：返回否决理由，null = 是纯图漫画。
  ///
  /// 不写日志，由调用方决定在哪个 isolate 记（后台 isolate 里 [engineLog] 没装配，
  /// 记了也落不到反馈日志里，见 `manga_archive_probe.dart`）。
  ///
  /// [probeDir]：container / OPF / spine 文档的解压落点（页图条目不落盘）。给了就
  /// 用它、**不删**（调用方建的目录归调用方收，app 内传书库根下的 `.tmp-*`，崩溃
  /// 残留归导入残留清扫管）；不给才退回系统临时目录、用完即删（只剩没有库句柄的
  /// 同步调用方）。
  static String? imageEpubRejection(String archivePath, {String? probeDir}) {
    debugEpubProbeCount += 1;
    Directory? ownedExtraction;
    _OpenedArchive? opened;
    try {
      opened = _open(archivePath);
      final Archive archive = opened.archive;
      final int budget = mangaArchiveExpandedBudget(opened.length);
      int expandedBytes = 0;
      int imageCount = 0;
      for (final ArchiveFile entry in archive) {
        _validateEntry(entry);
        expandedBytes += opened.declaredSize(entry);
        if (expandedBytes > budget) {
          return 'declared expanded size exceeds $budget bytes';
        }
        if (entry.isFile &&
            kMangaImageExtensions.contains(
              p.extension(entry.name).toLowerCase(),
            )) {
          imageCount += 1;
        }
      }
      if (imageCount == 0) {
        return 'no image entries in the archive';
      }
      // 中央目录看完就关：下面的整包解析自己再开一次文件。
      opened.close();
      opened = null;
      final String extractionPath =
          probeDir ??
          (ownedExtraction = Directory.systemTemp.createTempSync(
            'fushi_manga_epub_probe_',
          )).path;
      // BUG-3845：spine 直接是 SVG 内容文档（每页 `<svg><image>`）的漫画，默认
      // 书籍口径会把每项都跳过、整本 0 章；漫画只取页图，SVG 项照收。
      //
      // 页图条目不落盘（manga-23）：判据（[_pureImageEpubRejection]）只看 spine
      // 文档里的文字与图片引用，不读页图字节。此前探测把整本解压一遍、导入再解压
      // 一遍，而每次导入前都先探测——纯图 EPUB 的页图被白解一整遍。与 ZIP 包的探测
      // 只看条目名、不为页图解压同一取舍。
      final EpubBook book = EpubParser.parseSyncFromPath(
        archivePath,
        extractionPath,
        includeSvgSpineDocuments: true,
        extractEntry: _isNotPageImageEntry,
      );
      return _pureImageEpubRejection(book);
    } catch (e) {
      // OjZ-K53WBY：此前这里静默 false，用户只看到「不是漫画」，反馈里没有任何
      // 可定位的线索（解析失败？哪一页有文字？哪张图扩展名不认？）。
      return 'probe failed: $e';
    } finally {
      opened?.close();
      final Directory? dir = ownedExtraction;
      if (dir != null && dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  }

  /// 条目名不是页图（[kMangaImageExtensions]）：纯图判据只看 container / OPF /
  /// spine 文档，页图字节不必落盘。
  static bool _isNotPageImageEntry(String name) =>
      !kMangaImageExtensions.contains(p.extension(name).toLowerCase());

  /// 条目名是页图（[_isNotPageImageEntry] 的反面）：整卷导入定性通过后才补解。
  static bool _isPageImageEntry(String name) => !_isNotPageImageEntry(name);

  static bool _isPureImageEpub(EpubBook book) =>
      _pureImageEpubRejection(book) == null;

  /// 纯图片 EPUB 判定的**否决理由**（null = 是纯图片漫画）。与 [_isPureImageEpub]
  /// 同一判据，只是把「为什么不是」说出来，供诊断日志用（OjZ-K53WBY）。
  static String? _pureImageEpubRejection(EpubBook book) {
    final List<int> contentChapters = <int>[
      for (int index = 0; index < book.chapters.length; index++)
        if (book.chapters[index].linear && !book.chapters[index].isNav) index,
    ];
    if (contentChapters.isEmpty) {
      return 'no linear non-nav spine chapters '
          '(${book.chapters.length} chapters total)';
    }
    for (final int index in contentChapters) {
      final String chapterHref = book.chapters[index].href;
      if (!book.isImageOnlyChapter(index)) {
        return 'chapter #$index $chapterHref is not image-only (has text)';
      }
      final List<String> refs = book.chapterImageSrcs(index);
      if (refs.isEmpty) return 'chapter #$index $chapterHref has no image';
      for (final String ref in refs) {
        final String href = resolveImageHref(chapterHref, ref);
        final String extension = p.extension(normalizeHref(href)).toLowerCase();
        if (!kMangaImageExtensions.contains(extension)) {
          return 'chapter #$index $chapterHref references non-page image '
              '$href (extension "$extension")';
        }
      }
    }
    return null;
  }

  /// 导入阶段判定 [archivePath] 不是纯图 EPUB：记诊断日志并抛
  /// [MangaArchiveNotMangaException]（批量导入据此计「不是漫画」而不是「失败」）。
  static Never _rejectEpub(String archivePath, String reason) {
    logEpubRejection(archivePath, reason);
    throw MangaArchiveNotMangaException(
      'EPUB is not a pure image manga: $reason',
    );
  }

  /// 把 EPUB「不是纯图漫画」的理由记进诊断日志（OjZ-K53WBY）。公开给后台探测入口
  /// 在主 isolate 上记。
  static void logEpubRejection(String archivePath, String reason) {
    engineLog.logDiagnostic(
      'MangaArchiveImporter',
      'EPUB not recognised as image manga: ${p.basename(archivePath)}: $reason',
    );
  }

  /// [moveFromExtraction]：[book] 的解压树归调用方独占、用完即删时为 true，页图从
  /// 解压树直接**挪**进 [staging]（同卷一次 rename，manga-23），不再读进内存再写一
  /// 遍；同一张图被多页引用时第二次起从已挪到的位置拷。公开的 [copyEpubPages] 用于
  /// 就地转化在库的书，解压树是书本身，只能拷。
  static Future<void> _copyEpubPages(
    EpubBook book,
    Directory staging, {
    bool moveFromExtraction = false,
  }) async {
    int page = 0;
    final Map<String, File> moved = <String, File>{};
    for (int index = 0; index < book.chapters.length; index++) {
      final EpubChapter chapter = book.chapters[index];
      if (!chapter.linear || chapter.isNav) continue;
      for (final String ref in book.chapterImageSrcs(index)) {
        final String href = resolveImageHref(chapter.href, ref);
        final String extension = p.extension(normalizeHref(href)).toLowerCase();
        final File output = File(
          p.join(
            staging.path,
            'page_${page.toString().padLeft(6, '0')}$extension',
          ),
        );
        if (moveFromExtraction &&
            await _moveEpubResource(book, href, output, moved)) {
          page += 1;
          continue;
        }
        Uint8List? bytes = book.readResource(href);
        if (bytes == null) {
          try {
            bytes = book.readResource(Uri.decodeComponent(href));
          } on ArgumentError {
            // Keep the original href; the missing-resource error below is more
            // useful than an invalid percent-escape error.
          } on FormatException {
            // Same, for `%FF`-style escapes (valid syntax, invalid UTF-8).
          }
        }
        if (bytes == null) {
          throw MangaImportException('EPUB manga page not found: $href');
        }
        await output.writeAsBytes(bytes, flush: true);
        page += 1;
      }
    }
    if (page == 0) {
      throw const MangaImportException('EPUB manga has no spine images');
    }
  }

  /// 把 [href] 指向的解压树文件挪到 [output]（[moved]：已挪走的源 → 新位置）。找不到
  /// 对应的盘上文件时返回 false，由调用方走读字节的老路（报「page not found」）。
  /// 查找口径与 [EpubBook.readResource] 一致：先原样，再 percent-decode 一次。
  static Future<bool> _moveEpubResource(
    EpubBook book,
    String href,
    File output,
    Map<String, File> moved,
  ) async {
    final List<String> candidates = <String>[href];
    try {
      final String decoded = Uri.decodeComponent(href);
      if (decoded != href) candidates.add(decoded);
    } on ArgumentError {
      // 非法 percent 转义：只按原样找。
    } on FormatException {
      // `%FF` 这类语法合法、解不成 UTF-8 的转义：同上。
    }
    for (final String candidate in candidates) {
      final String normalized = normalizeHref(candidate);
      // 资源表的路径由解析器做过根内校验；表外的回退走 [EpubBook.rootFilePath]，
      // `../别的书/page.jpg` 这类越出解压根的引用得 null，不挪（挪是破坏性的）。
      final String? path =
          book.resources[normalized]?.filePath ?? book.rootFilePath(normalized);
      if (path == null) continue;
      final String key = p.canonicalize(path);
      final File? earlier = moved[key];
      if (earlier != null) {
        await earlier.copy(output.path);
        return true;
      }
      final File source = File(path);
      if (!source.existsSync()) continue;
      await MangaImporter.movePageFile(source, output);
      moved[key] = output;
      return true;
    }
    return false;
  }

  /// 以文件流打开 zip：只读中央目录，条目内容在首次访问 `.content` 时才按需
  /// 解压。用完必须 [_OpenedArchive.close]（关文件句柄 + 释放已解压缓冲）。
  ///
  /// 之前是 `readAsBytesSync` + `Uint8List.fromList` 再拷一份 + `decodeBytes(verify:
  /// true)`：整包读进内存两份、再对每个条目 inflate + CRC 一遍——而三个调用方里两个
  /// （[looksLikeImageArchive] / [_looksLikeImageEpub]）只看条目名，且它们在
  /// 对话框里被同步调用、每次选中/拖入都跑；一本 500 MB 的 CBZ 要在 UI isolate
  /// 上白白解压两三次。
  ///
  /// [decodeLegacyNames]：把没带 UTF-8 标志的条目名按真实本地编码重解（见
  /// [_decodeLegacyNames]）。只有要写盘的导入路径打开：探测（[looksLikeImageArchive] /
  /// [_looksLikeImageEpub]）也会打开 zip 遍历条目名，但只看扩展名，用逐字节名字即可。
  static _OpenedArchive _open(
    String archivePath, {
    bool decodeLegacyNames = false,
  }) {
    final File file = File(archivePath);
    if (!file.existsSync()) {
      throw MangaImportException('Manga archive not found: $archivePath');
    }
    final InputFileStream input = InputFileStream(archivePath);
    try {
      final ZipDecoder decoder = ZipDecoder();
      final Archive archive = decoder.decodeBuffer(input);
      final Map<InputStreamBase, ZipFileHeader> headers =
          Map<InputStreamBase, ZipFileHeader>.identity();
      for (final ZipFileHeader header in decoder.directory.fileHeaders) {
        final InputStreamBase? raw = header.file?.rawContent;
        if (raw != null) headers[raw] = header;
      }
      if (decodeLegacyNames) {
        _decodeLegacyNames(file, decoder.directory, archive);
      }
      return _OpenedArchive(
        archivePath,
        file.lengthSync(),
        archive,
        input,
        headers,
      );
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }

  /// 通用位 11（EFS）：置位时条目名按 UTF-8 写。
  static const int _kZipUtf8NameFlag = 0x800;
  static const int _kCentralHeaderSignature = 0x02014b50;
  static const int _kCentralHeaderBytes = 46;

  /// 没带 UTF-8 标志的条目名按打包机器的真实本地编码重解（design-zip-cp932-names）。
  ///
  /// 日文 / 中文 Windows 的压缩工具按 Shift_JIS / GBK 写名字、不置通用位 11。archive 3.6.1
  /// 把这种名字逐字节当 Latin-1 字符存（BUG-4658 的补丁），然后**先**把 `\` 换成 `/`：
  /// Shift_JIS 第二字节是 0x5C 的字（「表」「ソ」）因此被多切出一级目录；第二字节 0x7C 的
  /// 字（「ポ」）变成 `|`，Windows 上写盘失败、整本导入不了。
  ///
  /// 所以这里不从 `ArchiveFile.name` 反推字节（`\` 与 `/` 已经混在一起），而是从中央目录
  /// 重新读出每条记录的原始名字字节，整包没带标志的名字一起交给 Rust 内核
  /// （[LegacyTextDecoder]，与曲库 ID3 乱码修复同一套判据）判编码、解码，再改写条目名。
  /// 流式解压按中央目录记录的本地头偏移定位条目，不看名字，改名不影响取数据。
  /// 判不出编码、或中央目录与 archive 解出的记录对不上时什么都不改（维持逐字节行为）。
  static void _decodeLegacyNames(
    File file,
    ZipDirectory directory,
    Archive archive,
  ) {
    final List<ZipFileHeader> fileHeaders = directory.fileHeaders;
    bool needed = false;
    for (final ZipFileHeader header in fileHeaders) {
      if ((header.generalPurposeBitFlag & _kZipUtf8NameFlag) == 0 &&
          header.filename.codeUnits.any((int c) => c >= 0x80)) {
        needed = true;
        break;
      }
    }
    if (!needed) return;

    final List<Uint8List>? rawNames = _readCentralDirectoryNames(
      file,
      directory,
    );
    if (rawNames == null) return;

    final List<int> legacy = <int>[];
    for (int i = 0; i < fileHeaders.length; i++) {
      final ZipFileHeader header = fileHeaders[i];
      if ((header.generalPurposeBitFlag & _kZipUtf8NameFlag) != 0) continue;
      final Uint8List raw = rawNames[i];
      if (!raw.any((int b) => b >= 0x80)) continue;
      // 与 archive 读出的名字逐条核对：中央目录位置算错（如带前缀数据的自解压包）时
      // 宁可不改。
      final String? asUtf8 = _strictUtf8(raw);
      if ((asUtf8 ?? String.fromCharCodes(raw)) != header.filename) return;
      // 不带标志但本身是合法 UTF-8 的名字（macOS「压缩」、部分 Linux 工具就这么写）
      // archive 已经按 UTF-8 解对了，不进 legacy 批：本地编码判据没有排除 UTF-8 的
      // 维度，送进去会被判成 Shift_JIS 解成乱码，Mokuro 清单的 img_path 也就对不上。
      if (asUtf8 != null) continue;
      legacy.add(i);
    }
    if (legacy.isEmpty) return;

    final ({LegacyTextEncoding encoding, List<String> texts})? decoded =
        LegacyTextDecoder.decodeBatch(<Uint8List>[
          for (final int i in legacy) rawNames[i],
        ]);
    if (decoded == null) {
      engineLog.logDiagnostic(
        'MangaArchiveImporter',
        'ZIP ${p.basename(file.path)}: ${legacy.length} entry names without '
            'the UTF-8 flag, encoding not detected; kept byte-for-byte',
      );
      return;
    }

    final Map<InputStreamBase, ArchiveFile> entries =
        Map<InputStreamBase, ArchiveFile>.identity();
    for (final ArchiveFile entry in archive) {
      final InputStreamBase? raw = entry.rawContent;
      if (raw != null) entries[raw] = entry;
    }
    for (int k = 0; k < legacy.length; k++) {
      final ZipFileHeader header = fileHeaders[legacy[k]];
      final InputStreamBase? raw = header.file?.rawContent;
      final ArchiveFile? entry = raw == null ? null : entries[raw];
      if (entry == null) continue;
      entry.name = decoded.texts[k].replaceAll('\\', '/');
      // 与 ZipDecoder 同一判据：非 Unix 打包的条目靠名字末尾的 `/` 判目录。逐字节名里
      // 结尾的 0x5C 尾字节曾被当成 `/`。
      if (header.versionMadeBy >> 8 != 3) {
        entry.isFile = !entry.name.endsWith('/');
      }
    }
    engineLog.logDiagnostic(
      'MangaArchiveImporter',
      'ZIP ${p.basename(file.path)}: ${legacy.length} entry names decoded as '
          '${decoded.encoding.name}',
    );
  }

  /// 严格 UTF-8 解码，解不开返回 null。archive 3.6.1 读名字也是这个口径：解得开就用，
  /// 否则逐字节转字符。
  static String? _strictUtf8(Uint8List raw) {
    try {
      return utf8.decode(raw);
    } on FormatException {
      return null;
    }
  }

  /// 中央目录里每条记录的原始名字字节，与 [ZipDirectory.fileHeaders] 同序；结构对不上返回
  /// null。偏移 / 大小取 archive 解析好的值（已含 ZIP64 EOCD 的真值）。
  static List<Uint8List>? _readCentralDirectoryNames(
    File file,
    ZipDirectory directory,
  ) {
    final int count = directory.fileHeaders.length;
    final int size = directory.centralDirectorySize;
    final RandomAccessFile handle = file.openSync();
    final Uint8List bytes;
    try {
      handle.setPositionSync(directory.centralDirectoryOffset);
      bytes = handle.readSync(size);
    } finally {
      handle.closeSync();
    }
    if (bytes.length != size) return null;
    final ByteData data = ByteData.sublistView(bytes);
    final List<Uint8List> names = <Uint8List>[];
    int offset = 0;
    for (int i = 0; i < count; i++) {
      if (offset + _kCentralHeaderBytes > size ||
          data.getUint32(offset, Endian.little) != _kCentralHeaderSignature) {
        return null;
      }
      final int nameLength = data.getUint16(offset + 28, Endian.little);
      final int extraLength = data.getUint16(offset + 30, Endian.little);
      final int commentLength = data.getUint16(offset + 32, Endian.little);
      final int nameStart = offset + _kCentralHeaderBytes;
      if (nameStart + nameLength > size) return null;
      names.add(
        Uint8List.sublistView(bytes, nameStart, nameStart + nameLength),
      );
      offset = nameStart + nameLength + extraLength + commentLength;
    }
    return names;
  }

  static void _validateEntry(ArchiveFile entry) {
    final String normalized = entry.name.replaceAll('\\', '/');
    final List<String> segments = normalized.split('/');
    if (entry.isSymbolicLink ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        segments.any((String part) => part == '..')) {
      throw MangaImportException('Unsafe manga archive entry: ${entry.name}');
    }
  }
}

/// 压缩包导入的进度（manga-29a）：总量 = 解压段 + 入库段。
///
/// 解压段每解出一个条目推进一格；入库段（[MangaImporter] 逐页挪进书目录）的
/// `(done, total)` 平移到解压段之后。解压时入库段的格数先按页图条目数估，入库开始
/// 后换成真实页数（两者通常相等）。
class _ArchiveImportProgress {
  _ArchiveImportProgress(this._report);

  final void Function(int done, int total)? _report;
  int _extractTotal = 0;
  int _extractDone = 0;
  int _expectedPages = 0;

  void beginExtraction(int units, {required int expectedPages}) {
    _extractTotal = units;
    _extractDone = 0;
    _expectedPages = expectedPages;
    _emit();
  }

  void entryExtracted() {
    if (_extractDone < _extractTotal) _extractDone += 1;
    _emit();
  }

  void finishExtraction() {
    _extractDone = _extractTotal;
    _emit();
  }

  void _emit() => _report?.call(_extractDone, _extractTotal + _expectedPages);

  /// 交给入库阶段的回调：`(done, total)` 平移到解压段之后。
  void Function(int done, int total)? get ingest {
    final void Function(int done, int total)? report = _report;
    if (report == null) return null;
    return (int done, int total) =>
        report(_extractTotal + done, _extractTotal + total);
  }
}

/// 条目内容与 zip 记录不符（大小 / CRC / deflate 流损坏）。仍是
/// [MangaImportException]：页图路径照常让整次导入失败；只有读 `.mokuro` 清单时
/// 被 [_ZipEntryStreamer.readManifest] 识别成「这份清单不是候选」。
class _CorruptZipEntry extends MangaImportException {
  const _CorruptZipEntry(super.message);
}

/// 按条目流式解压 zip：自己从源文件读原始压缩数据，method 0 直接拷、method 8 走
/// `dart:io` 的 raw inflate 分块转换，边解边计数、边算 CRC、边写盘。
///
/// `package:archive` 3.x 的 `ArchiveFile.content` 会把整条 inflate 进内存，且它的
/// 解压长度只受中央目录**声明**的大小约束——声明可以谎报，于是一个 1 KB 声明的
/// 条目能在内存里涨到几 GB。这里的上限全部按**实际解出的字节**执行：
///
/// * 实际字节一超过声明大小就中止（声明本身已被要求 ≤ 单条上限），所以单条在
///   内存里最多是一个 inflate 分片的产出（[_inflateSliceBytes] × 最大压缩比
///   ≈ 8 MB），之后立即写盘；
/// * 所有条目累计的实际字节受 [MangaArchiveExtractionLimits.totalBudgetFor] 约束；
/// * 解完后实际字节必须**等于**声明大小、CRC32 必须一致，否则按损坏包报错。
///
/// CRC 用 Rust 内核的 [ffcCrc32]，按分片整块续算（每个输出分片一次 FFI 调用，
/// 不逐字节跨 FFI）。
class _ZipEntryStreamer {
  _ZipEntryStreamer._(
    this._opened,
    this._source,
    this._sourceLength,
    MangaArchiveExtractionLimits limits,
  ) : _limits = limits,
      _maxTotalBytes = limits.totalBudgetFor(_sourceLength);

  /// 每次从源文件读的原始压缩字节数。
  static const int _readBufferBytes = 64 * 1024;

  /// 每次喂给 inflater 的压缩字节数。deflate 最大压缩比约 1032:1，一个 8 KB 分片
  /// 最多同步产出约 8 MB，这就是两次写盘之间内存里最多攒下的解压字节。
  static const int _inflateSliceBytes = 8 * 1024;

  static const int _localHeaderSignature = 0x04034b50;
  static const int _localHeaderBytes = 30;

  final _OpenedArchive _opened;
  final RandomAccessFile _source;
  final int _sourceLength;
  final MangaArchiveExtractionLimits _limits;

  /// 本次导入允许实际解出的总字节数（[MangaArchiveExtractionLimits.totalBudgetFor]）。
  final int _maxTotalBytes;

  /// 本次导入已经实际解出的字节数（跨条目累计）。
  int _expandedBytes = 0;

  static Future<_ZipEntryStreamer> open(
    _OpenedArchive opened,
    MangaArchiveExtractionLimits limits,
  ) async {
    final RandomAccessFile source = await File(opened.path).open();
    try {
      return _ZipEntryStreamer._(opened, source, await source.length(), limits);
    } catch (_) {
      await source.close();
      rethrow;
    }
  }

  Future<void> close() => _source.close();

  /// 把 [entry] 流式解到 [output]。中途任何失败都会先关掉 [output] 的句柄再抛出；
  /// 写了一半的文件由调用方随 staging 目录一起删除。
  Future<void> extractToFile(ArchiveFile entry, File output) async {
    final RandomAccessFile sink = await output.open(mode: FileMode.writeOnly);
    try {
      await _stream(
        entry,
        _limits.maxEntryBytes,
        (Uint8List chunk) => sink.writeFrom(chunk),
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 把 `.mokuro` 清单读进内存（≤ [maxBytes]）。声明超限、内容与记录不符时返回
  /// null（「不是候选」）；不支持的压缩 / 加密、总量超限照常抛出。
  Future<Uint8List?> readManifest(ArchiveFile entry, int maxBytes) async {
    if (_opened.declaredSize(entry) > maxBytes) return null;
    final BytesBuilder bytes = BytesBuilder(copy: false);
    try {
      await _stream(entry, maxBytes, (Uint8List chunk) async {
        bytes.add(chunk);
      });
    } on _CorruptZipEntry {
      return null;
    }
    return bytes.takeBytes();
  }

  Future<void> _stream(
    ArchiveFile entry,
    int entryLimit,
    Future<void> Function(Uint8List chunk) onChunk,
  ) async {
    final String name = entry.name;
    final ZipFileHeader? header = _opened.headerOf(entry);
    final int? compressedSize = header?.compressedSize;
    final int? localHeaderOffset = header?.localHeaderOffset;
    if (header == null || compressedSize == null || localHeaderOffset == null) {
      throw MangaImportException('Could not locate manga archive entry: $name');
    }
    if ((header.generalPurposeBitFlag & 0x1) != 0 ||
        ((header.file?.flags ?? 0) & 0x1) != 0) {
      throw MangaImportException(
        'Unsupported manga archive entry (encrypted): $name',
      );
    }
    final int method = header.compressionMethod;
    if (method != ZipFile.zipCompressionStore &&
        method != ZipFile.zipCompressionDeflate) {
      throw MangaImportException(
        'Unsupported manga archive entry (compression method $method): $name',
      );
    }

    // 声明大小先过一遍上限：诚实的超大条目不必白解。谎报的条目由下面按实际
    // 字节的检查兜住。
    final int declared = _opened.declaredSize(entry);
    if (declared > entryLimit) {
      throw MangaImportException(
        'Manga archive entry is too large: $name '
        '(declares $declared bytes, limit $entryLimit)',
      );
    }
    _ensureWithinTotal(_expandedBytes + declared);

    final int dataStart = await _dataStart(localHeaderOffset, name);
    if (compressedSize < 0 || dataStart + compressedSize > _sourceLength) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (truncated data): $name',
      );
    }

    int produced = 0;
    int crc = 0;
    final List<Uint8List> pending = <Uint8List>[];
    void accept(List<int> chunk) {
      produced += chunk.length;
      if (produced > declared) {
        throw _CorruptZipEntry(
          'Corrupt manga archive entry (expands beyond its declared '
          '$declared bytes): $name',
        );
      }
      _ensureWithinTotal(_expandedBytes + produced);
      pending.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }

    Future<void> drain() async {
      for (final Uint8List chunk in pending) {
        crc = ffcCrc32(chunk, crc);
        await onChunk(chunk);
      }
      pending.clear();
    }

    final ByteConversionSink? inflater = method == ZipFile.zipCompressionDeflate
        ? ZLibDecoder(raw: true).startChunkedConversion(_ChunkSink(accept))
        : null;
    final Uint8List buffer = Uint8List(_readBufferBytes);
    int remaining = compressedSize;
    await _source.setPosition(dataStart);
    try {
      while (remaining > 0) {
        final int want = remaining < buffer.length ? remaining : buffer.length;
        final int read = await _source.readInto(buffer, 0, want);
        if (read <= 0) {
          throw _CorruptZipEntry(
            'Corrupt manga archive entry (truncated data): $name',
          );
        }
        remaining -= read;
        if (inflater == null) {
          accept(Uint8List.fromList(Uint8List.sublistView(buffer, 0, read)));
          await drain();
          continue;
        }
        for (int offset = 0; offset < read; offset += _inflateSliceBytes) {
          final int end = offset + _inflateSliceBytes < read
              ? offset + _inflateSliceBytes
              : read;
          inflater.addSlice(buffer, offset, end, false);
          await drain();
        }
      }
      inflater?.close();
      await drain();
    } on FormatException catch (error) {
      // dart:io 的 inflater 对坏 deflate 流抛 `FormatException: Filter error`。
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (bad deflate data: ${error.message}): '
        '$name',
      );
    }

    if (produced != declared) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (size mismatch: declares $declared bytes, '
        'contains $produced): $name',
      );
    }
    final int? expectedCrc = _opened.declaredCrc32(entry);
    if (expectedCrc != null && crc != expectedCrc) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (CRC mismatch): $name',
      );
    }
    _expandedBytes += produced;
  }

  void _ensureWithinTotal(int bytes) {
    if (bytes > _maxTotalBytes) {
      throw MangaImportException(
        'Manga archive is too large (expands beyond '
        '$_maxTotalBytes bytes)',
      );
    }
  }

  /// 本地文件头之后、压缩数据开始处的偏移。文件名 / extra 长度以本地头为准
  /// （与 `package:archive` 的 `ZipFile` 读法一致，它们可以与中央目录不同）。
  Future<int> _dataStart(int localHeaderOffset, String name) async {
    if (localHeaderOffset < 0 ||
        localHeaderOffset + _localHeaderBytes > _sourceLength) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (bad local header offset): $name',
      );
    }
    await _source.setPosition(localHeaderOffset);
    final Uint8List bytes = await _source.read(_localHeaderBytes);
    if (bytes.length != _localHeaderBytes) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (truncated local header): $name',
      );
    }
    final ByteData view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.little) != _localHeaderSignature) {
      throw _CorruptZipEntry(
        'Corrupt manga archive entry (bad local header signature): $name',
      );
    }
    final int nameLength = view.getUint16(26, Endian.little);
    final int extraLength = view.getUint16(28, Endian.little);
    return localHeaderOffset + _localHeaderBytes + nameLength + extraLength;
  }
}

/// 把 inflater 的每个输出分片同步交给 [_onChunk]（它可以抛异常，从而在超限的
/// 那一片当场中止 inflate）。
class _ChunkSink implements Sink<List<int>> {
  _ChunkSink(this._onChunk);

  final void Function(List<int> chunk) _onChunk;

  @override
  void add(List<int> chunk) => _onChunk(chunk);

  @override
  void close() {}
}
