import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

const int _maximumArchiveExpandedBytes = 2 * 1024 * 1024 * 1024;
const int _maximumMokuroBytes = 64 * 1024 * 1024;

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
    required this.pageEntries,
    required this.score,
  });

  final _MokuroSource source;
  final MokuroPayload payload;
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
class _OpenedArchive {
  _OpenedArchive(this.archive, this.input);

  final Archive archive;
  final InputFileStream input;

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
      final String normalized =
          MangaArchiveImporter._normalizeArchiveName(image.name);
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
    _validateListing(listing.stdout.toString());

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
    } catch (_) {
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
  }) async {
    final String extension = p.extension(archivePath).toLowerCase();
    _OpenedArchive? opened;
    final Directory staging = await Directory.systemTemp.createTemp(
      'hibiki_manga_archive_',
    );
    Directory? epubExtraction;
    try {
      if (_kSevenZipMangaArchiveExtensions.contains(extension)) {
        await (sevenZipExtractor ?? MangaSevenZipExtractor()).extractImages(
          archivePath: archivePath,
          staging: staging,
        );
      } else {
        opened = _open(archivePath);
        final Archive archive = opened.archive;
        int expandedBytes = 0;
        for (final ArchiveFile entry in archive) {
          _validateEntry(entry);
          expandedBytes += entry.size;
          if (expandedBytes > _maximumArchiveExpandedBytes) {
            throw const MangaImportException('Manga archive is too large');
          }
        }

        // A Mokuro CBZ/ZIP is still an image archive, but its `.mokuro` member
        // is the authoritative selectable-text layer. The old path discarded
        // every non-image member and rebuilt an empty payload, permanently
        // throwing away OCR that the user had already generated.
        //
        // Resolve the manifest before extraction, then materialise the matched
        // pages under the manifest's own `img_path` names. This normalisation
        // makes root-level, wrapper-directory, `<volume>/`, Windows-separator,
        // and consistently wrapped repacks all enter the existing, hardened
        // `importFromMokuroPath` pipeline without teaching that pipeline about
        // ZIP containers. Once a manifest is present, malformed, missing-page,
        // and ambiguous layouts fail loudly instead of repeating the original
        // silent OCR data loss.
        //
        // 这一段**只在 ZIP 分支内**：`_findMokuroCandidate` 吃的是 `package:archive`
        // 解出来的 `Archive`，而 RAR/CBR/CB7 走上面的 7-Zip 分支、根本没有 `Archive`
        // 对象。把它放在分支外对可空 `archive` 做隐式判断只会把「7z 包里的 mokuro
        // 不被识别」这个能力空洞伪装成已支持（见 docs/bugs/BUG-2018）。
        final _MokuroArchiveCandidate? mokuro = _findMokuroCandidate(
          archive,
          archivePath,
        );
        if (mokuro != null) {
          await _extractMokuroCandidate(mokuro, staging);
          final File manifest = File(
            p.join(
              staging.path,
              '${p.basenameWithoutExtension(archivePath)}.mokuro',
            ),
          );
          await manifest.writeAsString(mokuro.source.json, flush: true);
          return await MangaImporter.importFromMokuroPath(
            db: db,
            mokuroPath: manifest.path,
            title: title?.trim().isNotEmpty == true
                ? title
                : p.basenameWithoutExtension(archivePath),
            policy: policy,
            onProgress: onProgress,
            sourceId: sourceId,
          );
        }

        if (extension == '.epub') {
          epubExtraction = await Directory.systemTemp.createTemp(
            'hibiki_manga_epub_',
          );
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

  static Future<void> _extractArchiveImages(
    Archive archive,
    Directory staging,
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
      await output.writeAsBytes(_verifiedContent(entry), flush: true);
      imageCount += 1;
    }
    if (imageCount == 0) {
      throw const MangaImportException('Manga archive has no images');
    }
  }

  static _MokuroArchiveCandidate? _findMokuroCandidate(
    Archive archive,
    String archivePath,
  ) {
    final String archiveStem = p.basenameWithoutExtension(archivePath);
    final List<_MokuroSource> sources = <_MokuroSource>[];
    bool foundMokuro = false;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile || p.extension(entry.name).toLowerCase() != '.mokuro') {
        continue;
      }
      final Object? content = entry.content;
      if (content is! List<int>) continue;
      if (content.length > _maximumMokuroBytes) continue;
      // 清单 JSON 也做 CRC：坏清单会让页匹配整体失败，早点当「不是候选」跳过。
      final int? expectedCrc = entry.crc32;
      if (expectedCrc != null && getCrc32(content) != expectedCrc) continue;
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
    final List<String> sidecarPaths = <String>[
      p.setExtension(archivePath, '.mokuro'),
      '$archivePath.mokuro',
    ];
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
        final MokuroPayload payload = parseMokuro(source.json);
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
      await output.writeAsBytes(_verifiedContent(entry), flush: true);
    }
  }

  /// 条目内容 + CRC32 校验。
  ///
  /// 流式打开（[_open]）只读中央目录、不 `verify`，整包 CRC 校验随之消失；这里在
  /// 真正要写盘的条目上补回来——字节已经在内存里，CRC 是零额外 IO 的纯计算，而
  /// 探测路径（只看条目名）仍然不用为一个坏包白解压整包。CRC 不符 = 传输截断 /
  /// 位翻转的坏页，宁可整次导入失败也不把垃圾页写进书。
  static List<int> _verifiedContent(ArchiveFile entry) {
    final Object? content = entry.content;
    if (content is! List<int>) {
      throw MangaImportException(
        'Could not extract manga page: ${entry.name}',
      );
    }
    final int? expected = entry.crc32;
    if (expected != null && getCrc32(content) != expected) {
      throw MangaImportException(
        'Corrupt manga archive entry (CRC mismatch): ${entry.name}',
      );
    }
    return content;
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
    }
    return normalized;
  }

  static String _archiveDirname(String normalizedName) {
    final String dirname = p.posix.dirname(normalizedName);
    return dirname == '.' ? '' : dirname;
  }

  static bool _looksLikeImageEpub(String archivePath) {
    Directory? extraction;
    _OpenedArchive? opened;
    try {
      opened = _open(archivePath);
      final Archive archive = opened.archive;
      int expandedBytes = 0;
      int imageCount = 0;
      for (final ArchiveFile entry in archive) {
        _validateEntry(entry);
        expandedBytes += entry.size;
        if (expandedBytes > _maximumArchiveExpandedBytes) {
          return false;
        }
        if (entry.isFile &&
            kMangaImageExtensions.contains(
              p.extension(entry.name).toLowerCase(),
            )) {
          imageCount += 1;
        }
      }
      if (imageCount == 0) {
        return false;
      }
      // 中央目录看完就关：下面的整包解析自己再开一次文件。
      opened.close();
      opened = null;
      extraction = Directory.systemTemp.createTempSync(
        'hibiki_manga_epub_probe_',
      );
      final EpubBook book = EpubParser.parseSyncFromPath(
        archivePath,
        extraction.path,
      );
      return _isPureImageEpub(book);
    } catch (_) {
      return false;
    } finally {
      opened?.close();
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
        if (!kMangaImageExtensions.contains(
          p.extension(normalizeHref(href)).toLowerCase(),
        )) {
          return false;
        }
      }
    }
    return true;
  }

  static Future<void> _copyEpubPages(EpubBook book, Directory staging) async {
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

  /// 以文件流打开 zip：只读中央目录，条目内容在首次访问 `.content` 时才按需
  /// 解压。用完必须 [_OpenedArchive.close]（关文件句柄 + 释放已解压缓冲）。
  ///
  /// 之前是 `readAsBytesSync` + `Uint8List.fromList` 再拷一份 + `decodeBytes(verify:
  /// true)`：整包读进内存两份、再对每个条目 inflate + CRC 一遍——而三个调用方里两个
  /// （[looksLikeImageArchive] / [_looksLikeImageEpub]）只看条目名，且它们在
  /// 对话框里被同步调用、每次选中/拖入都跑；一本 500 MB 的 CBZ 要在 UI isolate
  /// 上白白解压两三次。
  static _OpenedArchive _open(String archivePath) {
    final File file = File(archivePath);
    if (!file.existsSync()) {
      throw MangaImportException('Manga archive not found: $archivePath');
    }
    final InputFileStream input = InputFileStream(archivePath);
    try {
      return _OpenedArchive(ZipDecoder().decodeBuffer(input), input);
    } catch (_) {
      input.closeSync();
      rethrow;
    }
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
