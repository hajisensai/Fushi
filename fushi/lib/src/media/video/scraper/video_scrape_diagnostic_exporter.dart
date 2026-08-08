/// 视频刮削诊断包导出器。
///
/// 包只收集排查刮削所需的最小证据：来源相对目录树、原始 NFO、文件名解析结果
/// 和已落库的刮削摘要。视频、字幕、图片、数据库、配置和绝对路径均不进入包。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:fushi/src/media/metadata/credential_redaction.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

class VideoScrapeDiagnosticExportResult {
  const VideoScrapeDiagnosticExportResult({
    required this.outputFile,
    required this.fileCount,
    required this.nfoCount,
    required this.omittedNfoCount,
  });

  final File outputFile;
  final int fileCount;
  final int nfoCount;
  final int omittedNfoCount;
}

class VideoScrapeDiagnosticExporter {
  const VideoScrapeDiagnosticExporter({
    this.fileSystem = const LocalSourceFileSystem(),
    this.maxEntries = 50000,
    this.maxSingleNfoBytes = 2 * 1024 * 1024,
    this.maxTotalNfoBytes = 16 * 1024 * 1024,
  })  : assert(maxEntries >= 0),
        assert(maxSingleNfoBytes >= 0),
        assert(maxTotalNfoBytes >= 0);

  final SourceFileSystem fileSystem;
  final int maxEntries;
  final int maxSingleNfoBytes;
  final int maxTotalNfoBytes;

  Future<VideoScrapeDiagnosticExportResult> export({
    required SourceLibraryRow source,
    required List<VideoBookRow> books,
    required List<VideoScrapeMetaRow> scrapeMetadata,
    required File outputFile,
    required String applicationVersion,
    required String platform,
    DateTime? exportedAt,
  }) async {
    if (source.transport != 'local' || source.mediaKind != 'video') {
      throw ArgumentError('Diagnostics require a local video source');
    }
    final String root = p.normalize(p.absolute(source.rootPath));
    final List<String> collectionErrors = <String>[];
    List<SourceFileEntry> discovered = const <SourceFileEntry>[];
    try {
      discovered = await fileSystem.listFiles(
        source.rootPath,
        recursive: source.recursive,
      );
    } catch (error) {
      collectionErrors.add(_sanitizeText(error.toString(), root));
    }

    final List<_SafeFileEntry> safeFiles = <_SafeFileEntry>[];
    int unsafePathCount = 0;
    for (final SourceFileEntry entry in discovered) {
      if (entry.isDirectory) continue;
      final String? relative = _safeRelativePath(root, entry.path);
      if (relative == null) {
        unsafePathCount++;
        continue;
      }
      safeFiles.add(_SafeFileEntry(
        relativePath: relative,
        sourcePath: entry.path,
        sizeBytes: entry.sizeBytes,
      ));
    }
    safeFiles.sort((_SafeFileEntry a, _SafeFileEntry b) =>
        a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()));
    final int omittedTreeEntries =
        safeFiles.length > maxEntries ? safeFiles.length - maxEntries : 0;
    final List<_SafeFileEntry> exportedFiles =
        safeFiles.take(maxEntries).toList(growable: false);

    final Set<String> directories = <String>{};
    final List<Map<String, Object?>> tree = <Map<String, Object?>>[];
    for (final _SafeFileEntry entry in exportedFiles) {
      String parent = p.posix.dirname(entry.relativePath);
      while (parent != '.') {
        directories.add(parent);
        parent = p.posix.dirname(parent);
      }
      tree.add(<String, Object?>{
        'path': entry.relativePath,
        'type': 'file',
        'sizeBytes': entry.sizeBytes,
      });
    }
    final List<String> sortedDirectories = directories.toList()..sort();
    tree.insertAll(
        0,
        sortedDirectories.map((String path) =>
            <String, Object?>{'path': path, 'type': 'directory'}));

    final List<_NfoFile> nfoFiles = <_NfoFile>[];
    int omittedNfoCount = 0;
    int totalNfoBytes = 0;
    for (final _SafeFileEntry entry in exportedFiles) {
      if (p.extension(entry.relativePath).toLowerCase() != '.nfo') continue;
      final int? size = entry.sizeBytes;
      if (size == null ||
          size > maxSingleNfoBytes ||
          totalNfoBytes + size > maxTotalNfoBytes) {
        omittedNfoCount++;
        continue;
      }
      nfoFiles.add(_NfoFile(
        archivePath: 'nfo/${entry.relativePath}',
        sourcePath: entry.sourcePath,
        sizeBytes: size,
      ));
      totalNfoBytes += size;
    }

    final Map<String, VideoScrapeMetaRow> metaByUid =
        <String, VideoScrapeMetaRow>{
      for (final VideoScrapeMetaRow row in scrapeMetadata) row.bookUid: row,
    };
    final List<Map<String, Object?>> scrapeData = <Map<String, Object?>>[];
    for (final VideoBookRow book in books) {
      final String? relative = _safeRelativePath(root, book.videoPath);
      final ParsedMediaName parsed =
          FilenameParser.parse(p.basename(book.videoPath));
      final VideoScrapeMetaRow? meta = metaByUid[book.bookUid];
      scrapeData.add(<String, Object?>{
        'relativePath': relative,
        'outsideSource': relative == null,
        'libraryTitle': book.title,
        'filenameParse': <String, Object?>{
          'title': parsed.title,
          'secondaryTitle': parsed.secondaryTitle,
          'episode': parsed.episode,
          'season': parsed.season,
          'year': parsed.year,
          'releaseGroup': parsed.releaseGroup,
          'resolution': parsed.resolution,
          'isMovieHint': parsed.isMovieHint,
        },
        'scrapeStatus': meta == null ? 'missing' : 'matched',
        if (meta != null)
          'scrapeMetadata': <String, Object?>{
            'source': meta.source,
            'subjectId': meta.subjectId,
            'title': meta.title,
            'originalTitle': meta.originalTitle,
            'airDate': meta.airDate,
            'episodeNumber': meta.episodeNumber,
            'detailUrl': meta.detailUrl == null
                ? null
                : redactCredentialsInText(meta.detailUrl!),
            'scrapedAt': meta.scrapedAt.toUtc().toIso8601String(),
          },
      });
    }
    scrapeData.sort((Map<String, Object?> a, Map<String, Object?> b) =>
        ((a['relativePath'] as String?) ?? '')
            .compareTo((b['relativePath'] as String?) ?? ''));

    final String? lastScanError = source.lastScanError == null
        ? null
        : _sanitizeText(source.lastScanError!, root);
    final Map<String, Object?> manifest = <String, Object?>{
      'format': 'fushi.video-scrape-diagnostics',
      'schemaVersion': 1,
      'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'applicationVersion': applicationVersion,
      'platform': platform,
      'source': <String, Object?>{
        'transport': 'local',
        'recursive': source.recursive,
        'rootAvailable': await Directory(source.rootPath).exists(),
        'lastScanError': lastScanError,
      },
      'counts': <String, Object?>{
        'files': exportedFiles.length,
        'directories': directories.length,
        'libraryItems': scrapeData.length,
        'nfoIncluded': nfoFiles.length,
        'nfoBytes': totalNfoBytes,
      },
      'limits': <String, Object?>{
        'maxEntries': maxEntries,
        'maxSingleNfoBytes': maxSingleNfoBytes,
        'maxTotalNfoBytes': maxTotalNfoBytes,
      },
      'omissions': <String, Object?>{
        'mediaContent': true,
        'subtitles': true,
        'images': true,
        'database': true,
        'configuration': true,
        'absolutePaths': true,
        'treeEntriesOverLimit': omittedTreeEntries,
        'nfoFilesOverLimit': omittedNfoCount,
        'unsafePaths': unsafePathCount,
      },
      'collectionErrors': collectionErrors,
    };
    final String treeText = tree
        .map((Map<String, Object?> entry) =>
            entry['type'] == 'directory' ? '${entry['path']}/' : entry['path'])
        .join('\n');
    final Map<String, String> textFiles = <String, String>{
      'README.txt': _readme,
      'manifest.json': const JsonEncoder.withIndent('  ').convert(manifest),
      'tree.json': const JsonEncoder.withIndent('  ').convert(tree),
      'directory-tree.txt': '$treeText\n',
      'scrape-data.json':
          const JsonEncoder.withIndent('  ').convert(scrapeData),
    };

    await _writeZip(outputFile.path, textFiles, nfoFiles);
    return VideoScrapeDiagnosticExportResult(
      outputFile: outputFile,
      fileCount: exportedFiles.length,
      nfoCount: nfoFiles.length,
      omittedNfoCount: omittedNfoCount,
    );
  }

  static const String _readme = '''Fushi video scrape diagnostic package

This package is an export-time snapshot for diagnosing video metadata scraping.
It contains relative file/directory names, filename parsing results, scrape
metadata summaries, and original NFO files. It does not contain video, subtitle,
image, database, app configuration, app credential, or absolute source-path data.

Privacy warning: original NFO files are preserved unchanged. File/directory names
and NFO contents can contain personal information or secrets. Review the package
before posting it publicly.
''';

  static String _sanitizeText(String text, String root) {
    String sanitized = redactCredentialsInText(text);
    final Set<String> variants = <String>{
      root,
      root.replaceAll('\\', '/'),
      root.replaceAll('/', '\\'),
    }..removeWhere((String value) => value.isEmpty);
    for (final String value in variants) {
      sanitized = sanitized.replaceAll(
        RegExp(RegExp.escape(value), caseSensitive: false),
        '<source-root>',
      );
    }
    return sanitized;
  }

  static String? _safeRelativePath(String root, String candidate) {
    final String normalized = p.normalize(p.absolute(candidate));
    if (normalized != root && !p.isWithin(root, normalized)) return null;
    final String relative = p.relative(normalized, from: root);
    if (relative == '.' || p.isAbsolute(relative)) return null;
    final List<String> parts = p.split(relative);
    if (parts.any((String part) => part == '..' || part.isEmpty)) return null;
    final String archivePath = p.posix.joinAll(parts);
    if (archivePath.startsWith('/') || archivePath.contains('../')) return null;
    return archivePath;
  }

  static Future<void> _writeZip(
    String outputPath,
    Map<String, String> textFiles,
    List<_NfoFile> nfoFiles,
  ) async {
    await Isolate.run(() async {
      final ZipFileEncoder encoder = ZipFileEncoder()..create(outputPath);
      try {
        for (final MapEntry<String, String> entry in textFiles.entries) {
          final List<int> bytes = utf8.encode(entry.value);
          encoder.addArchiveFile(
            ArchiveFile(entry.key, bytes.length, bytes),
          );
        }
        for (final _NfoFile entry in nfoFiles) {
          final File file = File(entry.sourcePath);
          if (!file.existsSync() || file.lengthSync() != entry.sizeBytes) {
            throw StateError(
              'An NFO file changed while the diagnostic package was created',
            );
          }
          await encoder.addFile(
            file,
            entry.archivePath,
            ZipFileEncoder.STORE,
          );
        }
        encoder.closeSync();
      } catch (_) {
        encoder.closeSync();
        try {
          final File partial = File(outputPath);
          if (partial.existsSync()) partial.deleteSync();
        } catch (_) {}
        rethrow;
      }
    });
  }
}

class _SafeFileEntry {
  const _SafeFileEntry({
    required this.relativePath,
    required this.sourcePath,
    required this.sizeBytes,
  });

  final String relativePath;
  final String sourcePath;
  final int? sizeBytes;
}

class _NfoFile {
  const _NfoFile({
    required this.archivePath,
    required this.sourcePath,
    required this.sizeBytes,
  });

  final String archivePath;
  final String sourcePath;
  final int sizeBytes;
}
