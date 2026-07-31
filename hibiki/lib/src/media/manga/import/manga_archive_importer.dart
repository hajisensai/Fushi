import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/src/media/manga/manga_storage.dart';

const int _maximumArchiveExpandedBytes = 2 * 1024 * 1024 * 1024;

/// Yomitan/Yomichan 词典包的**结构**标记：包根下的数据库文件名前缀。
///
/// 与 C++ 导入器 `native/hoshidicts/hoshidicts_src/importer.cpp` 的
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

abstract final class MangaArchiveImporter {
  static bool looksLikeImageArchive(String archivePath) {
    final String extension = p.extension(archivePath).toLowerCase();
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
    required HibikiDatabase db,
    required String archivePath,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) async {
    final Archive archive = _decode(archivePath);
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_manga_archive_');
    Directory? epubExtraction;
    try {
      int expandedBytes = 0;
      for (final ArchiveFile entry in archive) {
        _validateEntry(entry);
        expandedBytes += entry.size;
        if (expandedBytes > _maximumArchiveExpandedBytes) {
          throw const MangaImportException('Manga archive is too large');
        }
      }

      if (p.extension(archivePath).toLowerCase() == '.epub') {
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

      return await MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: staging.path,
        title: title?.trim().isNotEmpty == true
            ? title
            : p.basenameWithoutExtension(archivePath),
        policy: policy,
        onProgress: onProgress,
      );
    } finally {
      archive.clearSync();
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
