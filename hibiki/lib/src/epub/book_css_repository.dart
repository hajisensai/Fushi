import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// HBK-AUDIT-101: read a (possibly non-UTF-8) CSS file as text without throwing
/// a FormatException. Malformed bytes are replaced rather than crashing the
/// in-app CSS editor. Callers must check [File.existsSync] beforehand.
String _readTextLenient(File file) {
  return utf8.decode(file.readAsBytesSync(), allowMalformed: true);
}

class CssFileEntry {
  CssFileEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.displayTitle,
  });

  final String absolutePath;
  final String relativePath;
  final String displayTitle;

  String get originalPath => '$absolutePath.original';
  bool get hasOriginal => File(originalPath).existsSync();

  bool isDifferentFromOriginal() {
    if (!hasOriginal) return false;
    // HBK-AUDIT-101: tolerate a missing/non-UTF-8 current CSS file instead of
    // throwing FileSystemException/FormatException.
    final File current = File(absolutePath);
    if (!current.existsSync()) return false;
    return _readTextLenient(current) != _readTextLenient(File(originalPath));
  }
}

/// BUG-040: a CSS file's identity plus its on-disk content captured together,
/// so the editor can populate its tabs without re-touching the filesystem on
/// the UI isolate.
class CssFileSnapshot {
  CssFileSnapshot({required this.entry, required this.content});

  final CssFileEntry entry;
  final String content;
}

class BookCssRepository {
  BookCssRepository(this.extractDir);

  final String extractDir;

  /// BUG-040: discover CSS files and read their contents off the UI thread.
  /// The recursive `listSync` over a fully-extracted EPUB (images/fonts/xhtml —
  /// often thousands of entries) plus the per-file `readAsStringSync` used to
  /// run synchronously inside the editor's `initState`, freezing the first
  /// frame for the entire duration of the page-push transition. The async
  /// `dart:io` walk + reads run the blocking syscalls on the Dart IO thread
  /// pool and deliver results via the event loop, so the UI isolate is never
  /// blocked and frames keep rendering (the editor shows a spinner meanwhile).
  Future<List<CssFileSnapshot>> loadSnapshots() async {
    final List<CssFileEntry> entries = await _discoverCssFilesAsync();
    final List<CssFileSnapshot> snapshots = <CssFileSnapshot>[];
    for (final CssFileEntry entry in entries) {
      snapshots
          .add(CssFileSnapshot(entry: entry, content: await readCss(entry)));
    }
    return snapshots;
  }

  Future<List<CssFileEntry>> _discoverCssFilesAsync() async {
    final Directory dir = Directory(extractDir);
    if (!await dir.exists()) return const [];

    final List<String> cssFilePaths = <String>[];
    await for (final FileSystemEntity entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final String ext = p.extension(entity.path).toLowerCase();
      if (ext == '.css' && !entity.path.endsWith('.original')) {
        cssFilePaths.add(entity.path);
      }
    }
    return _entriesFromCssPaths(cssFilePaths);
  }

  List<CssFileEntry> discoverCssFiles() {
    final Directory dir = Directory(extractDir);
    if (!dir.existsSync()) return const [];

    final List<String> cssFilePaths = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          final String ext = p.extension(f.path).toLowerCase();
          return ext == '.css' && !f.path.endsWith('.original');
        })
        .map((f) => f.path)
        .toList();

    return _entriesFromCssPaths(cssFilePaths);
  }

  /// Pure transform shared by the sync and async discovery paths: map absolute
  /// CSS file paths to sorted [CssFileEntry]s with shortest-unique display
  /// titles.
  List<CssFileEntry> _entriesFromCssPaths(List<String> cssFilePaths) {
    final List<String> relativePaths = cssFilePaths.map((path) {
      return p.relative(path, from: extractDir).replaceAll(r'\', '/');
    }).toList()
      ..sort();

    final Map<String, String> displayTitles =
        _shortestUniqueSuffixes(relativePaths);

    return relativePaths.map((rel) {
      return CssFileEntry(
        absolutePath: p.join(extractDir, rel.replaceAll('/', p.separator)),
        relativePath: rel,
        displayTitle: displayTitles[rel]!,
      );
    }).toList();
  }

  static Map<String, String> _shortestUniqueSuffixes(List<String> paths) {
    final Map<String, String> result = {};

    final Map<String, List<String>> byBasename = {};
    for (final String path in paths) {
      final String base = p.posix.basename(path);
      byBasename.putIfAbsent(base, () => []).add(path);
    }

    for (final entry in byBasename.entries) {
      if (entry.value.length == 1) {
        result[entry.value.first] = entry.key;
      } else {
        for (final String fullPath in entry.value) {
          final List<String> segments = p.posix.split(fullPath);
          String suffix = segments.last;
          for (int i = segments.length - 2; i >= 0; i--) {
            suffix = '${segments[i]}/$suffix';
            final bool unique = entry.value
                .where((other) => other != fullPath && other.endsWith(suffix))
                .isEmpty;
            if (unique) break;
          }
          result[fullPath] = suffix;
        }
      }
    }
    return result;
  }

  String readCssSync(CssFileEntry entry) {
    return File(entry.absolutePath).readAsStringSync();
  }

  Future<String> readCss(CssFileEntry entry) {
    return File(entry.absolutePath).readAsString();
  }

  /// Safe write: backup original if needed, write via temp+rename,
  /// delete .original if content matches original.
  void saveCss(CssFileEntry entry, String content) {
    final File target = File(entry.absolutePath);
    final File original = File(entry.originalPath);

    // Step 1: backup if no .original exists and content actually differs.
    // HBK-AUDIT-101: guard a missing target (book re-extracted/partially
    // deleted) and read with malformed-tolerant UTF-8 so non-UTF-8 CSS does
    // not throw a FileSystemException/FormatException out of saveCss. When the
    // target is absent there is nothing to back up; just proceed to write.
    if (!original.existsSync() && target.existsSync()) {
      final String currentContent = _readTextLenient(target);
      if (currentContent == content) return; // no-op
      original.writeAsStringSync(currentContent, flush: true);
    }

    // Step 2: write via temp → rename
    final File temp = File('${entry.absolutePath}.tmp');
    temp.writeAsStringSync(content, flush: true);
    temp.renameSync(entry.absolutePath);

    // Step 3: if content equals original, delete .original
    if (original.existsSync()) {
      final String originalContent = _readTextLenient(original);
      if (originalContent == content) {
        original.deleteSync();
      }
    }
  }

  void resetFile(CssFileEntry entry) {
    final File original = File(entry.originalPath);
    if (!original.existsSync()) return;
    final File temp = File('${entry.absolutePath}.tmp');
    // HBK-AUDIT-101: read the backup leniently so a non-UTF-8 original does not
    // throw FormatException mid-reset.
    temp.writeAsStringSync(_readTextLenient(original), flush: true);
    temp.renameSync(entry.absolutePath);
    original.deleteSync();
  }

  void resetAll() {
    for (final CssFileEntry entry in discoverCssFiles()) {
      if (entry.hasOriginal) {
        resetFile(entry);
      }
    }
  }
}
