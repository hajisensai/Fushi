import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages on-disk storage of extracted EPUB content.
///
/// Layout: `<appDocDir>/hoshi_books/<bookId>/`
///   - `META-INF/`, OPF, chapter HTML, images, CSS, fonts (extracted from ZIP)
///   - `original.epub` (optional — kept for re-export)
class EpubStorage {
  static String? _cachedBaseDir;

  /// Base directory for all extracted books.
  static Future<String> baseDirectory() async {
    if (_cachedBaseDir != null) return _cachedBaseDir!;
    final Directory appDir = await getApplicationDocumentsDirectory();
    _cachedBaseDir = p.join(appDir.path, 'hoshi_books');
    return _cachedBaseDir!;
  }

  /// Directory for a specific book. Creates it if it doesn't exist.
  static Future<String> bookDirectory(int bookId) async {
    final String base = await baseDirectory();
    final String dir = p.join(base, bookId.toString());
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      d.createSync(recursive: true);
    }
    return dir;
  }

  /// Path for a specific book — does NOT create the directory.
  static Future<String> bookPath(int bookId) async {
    final String base = await baseDirectory();
    return p.join(base, bookId.toString());
  }

  /// Delete a book's extracted directory.
  static Future<void> deleteBook(int bookId) async {
    final String base = await baseDirectory();
    final Directory dir = Directory(p.join(base, bookId.toString()));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Check if a book's extracted directory exists and has content.
  static Future<bool> bookExists(int bookId) async {
    final String base = await baseDirectory();
    final Directory dir = Directory(p.join(base, bookId.toString()));
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }

  /// List all book IDs that have extracted directories on disk.
  static Future<List<int>> listBookIds() async {
    final String base = await baseDirectory();
    final Directory baseDir = Directory(base);
    if (!baseDir.existsSync()) return <int>[];
    return baseDir
        .listSync()
        .whereType<Directory>()
        .map((d) => int.tryParse(p.basename(d.path)))
        .whereType<int>()
        .toList();
  }
}
