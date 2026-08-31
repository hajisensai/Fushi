import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';

const int _maximumArchiveExpandedBytes = 2 * 1024 * 1024 * 1024;

const Set<String> _kSevenZipMangaArchiveExtensions = <String>{
  '.rar',
  '.cbr',
  '.cb7',
};

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
  })  : _runProcess = runProcess ?? Process.run,
        _locator = DiscoveryArchiveExtractor(
          runProcess: runProcess,
          sevenZipOverride: sevenZipOverride,
        );

  final DiscoveryProcessRunner _runProcess;
  final DiscoveryArchiveExtractor _locator;

  Future<void> extractImages({
    required String archivePath,
    required Directory staging,
  }) async {
    final String? sevenZip = await _locator.findSevenZip();
    if (sevenZip == null) {
      throw const MangaImportException(
        'RAR/CBR/CB7 import requires 7-Zip (7za or 7z)',
      );
    }

    final ProcessResult listing = await _runProcess(
      sevenZip,
      <String>['l', '-slt', '-sccUTF-8', '-p-', archivePath],
    );
    if (listing.exitCode != 0) {
      throw MangaImportException(
        'Could not list manga archive (7z exit ${listing.exitCode})',
      );
    }
    _validateListing(listing.stdout.toString());

    final List<String> imageFilters = <String>[
      for (final String extension in kMangaImageExtensions)
        '-ir!*$extension',
    ];
    final ProcessResult extraction = await _runProcess(
      sevenZip,
      <String>[
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
      ],
    );
    if (extraction.exitCode != 0) {
      throw MangaImportException(
        'Could not extract manga archive (7z exit ${extraction.exitCode})',
      );
    }
    await _validateExtractedImages(staging);
  }

  void _validateListing(String output) {
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
      final String extension =
          p.posix.extension(entryPath.replaceAll('\\', '/')).toLowerCase();
      if (!kMangaImageExtensions.contains(extension)) continue;
      final int? size = int.tryParse(fields['Size'] ?? '');
      if (size == null || size < 0) {
        throw MangaImportException(
          'Invalid manga archive entry size: $entryPath',
        );
      }
      expandedImageBytes += size;
      if (expandedImageBytes > _maximumArchiveExpandedBytes) {
        throw const MangaImportException('Manga archive is too large');
      }
      imageCount++;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }

  Future<void> _validateExtractedImages(Directory staging) async {
    int imageCount = 0;
    int expandedImageBytes = 0;
    await for (final FileSystemEntity entity
        in staging.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw MangaImportException('Unsafe manga archive link: ${entity.path}');
      }
      if (entity is! File ||
          !kMangaImageExtensions
              .contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      expandedImageBytes += await entity.length();
      if (expandedImageBytes > _maximumArchiveExpandedBytes) {
        throw const MangaImportException('Manga archive is too large');
      }
      imageCount++;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }
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

  static bool looksLikeImageArchive(String archivePath) {
    final String extension = p.extension(archivePath).toLowerCase();
    if (_kSevenZipMangaArchiveExtensions.contains(extension)) {
      return true;
    }
    if (extension == '.epub') {
      return _looksLikeImageEpub(archivePath);
    }
    try {
      final Archive archive = _decode(archivePath);
      bool hasImage = false;
      bool hasDictionaryIndex = false;
      bool hasDictionaryBank = false;
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
        if (kMangaImageExtensions.contains(extension)) {
          hasImage = true;
        } else if (<String>{
          '.opf',
          '.xhtml',
          '.html',
          '.htm',
        }.contains(extension)) {
          return false;
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
      return hasImage;
    } catch (_) {
      return false;
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
  }) async {
    final String extension = p.extension(archivePath).toLowerCase();
    Archive? archive;
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_manga_archive_');
    Directory? epubExtraction;
    try {
      if (_kSevenZipMangaArchiveExtensions.contains(extension)) {
        await (sevenZipExtractor ?? MangaSevenZipExtractor()).extractImages(
          archivePath: archivePath,
          staging: staging,
        );
      } else {
        archive = _decode(archivePath);
        int expandedBytes = 0;
        for (final ArchiveFile entry in archive) {
          _validateEntry(entry);
          expandedBytes += entry.size;
          if (expandedBytes > _maximumArchiveExpandedBytes) {
            throw const MangaImportException('Manga archive is too large');
          }
        }

        if (extension == '.epub') {
          epubExtraction =
              await Directory.systemTemp.createTemp('hibiki_manga_epub_');
          final EpubBook book = EpubParser.parseSyncFromPath(
            archivePath,
            epubExtraction.path,
          );
          if (!_isPureImageEpub(book)) {
            throw const MangaImportException(
              'EPUB contains readable text pages and is not a pure image manga',
            );
          }
          await _copyEpubPages(book, staging);
        } else {
          await _extractArchiveImages(archive, staging);
        }
      }

      return await MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: staging.path,
        title: title?.trim().isNotEmpty == true
            ? title
            : p.basenameWithoutExtension(archivePath),
        policy: policy,
        onProgress: onProgress,
        sourceId: sourceId,
      );
    } finally {
      archive?.clearSync();
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      final Directory? extraction = epubExtraction;
      if (extraction != null && extraction.existsSync()) {
        await extraction.delete(recursive: true);
      }
    }
  }

  static Future<void> _extractArchiveImages(
    Archive archive,
    Directory staging,
  ) async {
    int imageCount = 0;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile ||
          !kMangaImageExtensions
              .contains(p.extension(entry.name).toLowerCase())) {
        continue;
      }
      final List<String> segments = entry.name
          .replaceAll('\\', '/')
          .split('/')
          .where((String part) => part.isNotEmpty && part != '.')
          .toList();
      final File output = File(p.joinAll(<String>[staging.path, ...segments]));
      await output.parent.create(recursive: true);
      final Object? content = entry.content;
      if (content is! List<int>) {
        throw MangaImportException(
          'Could not extract manga page: ${entry.name}',
        );
      }
      await output.writeAsBytes(content, flush: true);
      imageCount += 1;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }

  static bool _looksLikeImageEpub(String archivePath) {
    Directory? extraction;
    Archive? archive;
    try {
      archive = _decode(archivePath);
      int expandedBytes = 0;
      int imageCount = 0;
      for (final ArchiveFile entry in archive) {
        _validateEntry(entry);
        expandedBytes += entry.size;
        if (expandedBytes > _maximumArchiveExpandedBytes) {
          return false;
        }
        if (entry.isFile &&
            kMangaImageExtensions
                .contains(p.extension(entry.name).toLowerCase())) {
          imageCount += 1;
        }
      }
      if (imageCount == 0) {
        return false;
      }
      extraction =
          Directory.systemTemp.createTempSync('hibiki_manga_epub_probe_');
      final EpubBook book = EpubParser.parseSyncFromPath(
        archivePath,
        extraction.path,
      );
      return _isPureImageEpub(book);
    } catch (_) {
      return false;
    } finally {
      archive?.clearSync();
      final Directory? dir = extraction;
      if (dir != null && dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  }

  static bool _isPureImageEpub(EpubBook book) {
    final List<int> contentChapters = <int>[
      for (int index = 0; index < book.chapters.length; index++)
        if (book.chapters[index].linear && !book.chapters[index].isNav) index,
    ];
    if (contentChapters.isEmpty) return false;
    for (final int index in contentChapters) {
      if (!book.isImageOnlyChapter(index)) return false;
      final List<String> refs = book.chapterImageSrcs(index);
      if (refs.isEmpty) return false;
      for (final String ref in refs) {
        final String href = resolveImageHref(book.chapters[index].href, ref);
        if (!kMangaImageExtensions
            .contains(p.extension(normalizeHref(href)).toLowerCase())) {
          return false;
        }
      }
    }
    return true;
  }

  static Future<void> _copyEpubPages(
    EpubBook book,
    Directory staging,
  ) async {
    int page = 0;
    for (int index = 0; index < book.chapters.length; index++) {
      final EpubChapter chapter = book.chapters[index];
      if (!chapter.linear || chapter.isNav) continue;
      for (final String ref in book.chapterImageSrcs(index)) {
        final String href = resolveImageHref(chapter.href, ref);
        Uint8List? bytes = book.readResource(href);
        if (bytes == null) {
          try {
            bytes = book.readResource(Uri.decodeComponent(href));
          } on ArgumentError {
            // Keep the original href; the missing-resource error below is more
            // useful than an invalid percent-escape error.
          }
        }
        if (bytes == null) {
          throw MangaImportException('EPUB manga page not found: $href');
        }
        final String extension = p.extension(normalizeHref(href)).toLowerCase();
        final File output = File(
          p.join(
            staging.path,
            'page_${page.toString().padLeft(6, '0')}$extension',
          ),
        );
        await output.writeAsBytes(bytes, flush: true);
        page += 1;
      }
    }
    if (page == 0) {
      throw const MangaImportException('EPUB manga has no spine images');
    }
  }

  static Archive _decode(String archivePath) {
    final File file = File(archivePath);
    if (!file.existsSync()) {
      throw MangaImportException('Manga archive not found: $archivePath');
    }
    return ZipDecoder().decodeBytes(
      Uint8List.fromList(file.readAsBytesSync()),
      verify: true,
    );
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
