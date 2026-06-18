import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/src/startup/test_environment.dart';

/// Manages on-disk storage of extracted EPUB content.
///
/// Layout: `<appDocDir>/hoshi_books/<bookKey>/`
///   - `META-INF/`, OPF, chapter HTML, images, CSS, fonts (extracted from ZIP)
///   - `original.epub` (optional — kept for re-export)
///
/// NOTE: pre-v16 books were stored under `<appDocDir>/hoshi_books/<int id>/`.
/// Those directories are NOT renamed on migration — the truth is the
/// `epub_books.extract_dir` column. Use [bookDirectory]/[bookPath] only when
/// importing a NEW book; to locate an EXISTING book read its `extractDir`
/// column and operate on that absolute path (e.g. [deleteBookDir]).
class EpubStorage {
  static String? _cachedBaseDir;

  /// Base directory for all extracted books.
  static Future<String> baseDirectory() async {
    if (_cachedBaseDir != null) return _cachedBaseDir!;
    final Directory appDir = hibikiTestDirectory('app-documents') ??
        await getApplicationDocumentsDirectory();
    _cachedBaseDir = p.join(appDir.path, 'hoshi_books');
    return _cachedBaseDir!;
  }

  /// Directory for a NEW book (keyed by its bookKey). Creates it if missing.
  static Future<String> bookDirectory(String bookKey) async {
    final String base = await baseDirectory();
    final String dir = p.join(base, bookKey);
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      d.createSync(recursive: true);
    }
    return dir;
  }

  /// Path for a NEW book — does NOT create the directory.
  static Future<String> bookPath(String bookKey) async {
    final String base = await baseDirectory();
    return p.join(base, bookKey);
  }

  /// Delete an extracted directory by its absolute path (the stored
  /// `extract_dir` column). Use this to remove an existing book whose on-disk
  /// folder name may still be a legacy int id.
  static Future<void> deleteBookDir(String extractDir) async {
    if (extractDir.isEmpty) return;
    final Directory dir = Directory(extractDir);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Check whether an extracted directory at [extractDir] exists and has
  /// content.
  static Future<bool> bookDirExists(String extractDir) async {
    if (extractDir.isEmpty) return false;
    final Directory dir = Directory(extractDir);
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }
}
