import 'dart:io';

import 'package:path/path.dart' as p;

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
    final String current = File(absolutePath).readAsStringSync();
    final String original = File(originalPath).readAsStringSync();
    return current != original;
  }
}

class BookCssRepository {
  BookCssRepository(this.extractDir);

  final String extractDir;

  List<CssFileEntry> discoverCssFiles() {
    final Directory dir = Directory(extractDir);
    if (!dir.existsSync()) return const [];

    final List<File> cssFiles = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          final String ext = p.extension(f.path).toLowerCase();
          return ext == '.css' && !f.path.endsWith('.original');
        })
        .toList();

    final List<String> relativePaths = cssFiles.map((f) {
      return p.relative(f.path, from: extractDir).replaceAll(r'\', '/');
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

  String readCss(CssFileEntry entry) {
    return File(entry.absolutePath).readAsStringSync();
  }

  /// Safe write: backup original if needed, write via temp+rename,
  /// delete .original if content matches original.
  void saveCss(CssFileEntry entry, String content) {
    final File target = File(entry.absolutePath);
    final File original = File(entry.originalPath);

    // Step 1: backup if no .original exists and content actually differs
    if (!original.existsSync()) {
      final String currentContent = target.readAsStringSync();
      if (currentContent == content) return; // no-op
      original.writeAsStringSync(currentContent, flush: true);
    }

    // Step 2: write via temp → rename
    final File temp = File('${entry.absolutePath}.tmp');
    temp.writeAsStringSync(content, flush: true);
    temp.renameSync(entry.absolutePath);

    // Step 3: if content equals original, delete .original
    if (original.existsSync()) {
      final String originalContent = original.readAsStringSync();
      if (originalContent == content) {
        original.deleteSync();
      }
    }
  }

  void resetFile(CssFileEntry entry) {
    final File original = File(entry.originalPath);
    if (!original.existsSync()) return;
    final File temp = File('${entry.absolutePath}.tmp');
    temp.writeAsStringSync(original.readAsStringSync(), flush: true);
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
