import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Pure-Dart reader for the Yomitan "Local Audio Server" SQLite databases used
/// for term-pronunciation audio.
///
/// On Android this lookup is done by the native `TtsChannelHandler`; off Android
/// there is no native handler, so desktop builds query the same SQLite files
/// directly here. The schema (matching the native handler) is:
///   entries(expression, reading, file, source)   -- metadata
///   android(file, source, data BLOB)              -- the audio bytes
/// `data` is an mp3 (or opus when the file name ends in `.opus`) blob.
///
/// Pure sqlite3 means one implementation covers Windows / macOS / Linux
/// identically (sqlite3_flutter_libs provides the native library on all three).
class LocalAudioDb {
  const LocalAudioDb._();

  /// Looks up the `(file, source)` for [expression] in [dbPath], preferring an
  /// exact [reading] match and falling back to any entry for the expression
  /// (mirrors the native handler). Returns null on miss or error.
  static ({String file, String source})? queryMeta(
    String dbPath,
    String expression,
    String reading,
  ) {
    if (expression.isEmpty || dbPath.isEmpty || !File(dbPath).existsSync()) {
      return null;
    }
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      ResultSet rows = db.select(
        'SELECT file, source FROM entries '
        'WHERE expression = ? AND reading = ? LIMIT 1',
        <Object?>[expression, reading],
      );
      if (rows.isEmpty) {
        rows = db.select(
          'SELECT file, source FROM entries WHERE expression = ? LIMIT 1',
          <Object?>[expression],
        );
      }
      if (rows.isEmpty) return null;
      final Object? file = rows.first['file'];
      final Object? source = rows.first['source'];
      if (file is! String || source is! String) return null;
      return (file: file, source: source);
    } catch (e, stack) {
      ErrorLogService.instance.log('LocalAudioDb.queryMeta', e, stack);
      return null;
    } finally {
      db?.dispose();
    }
  }

  /// Extracts the audio blob for `(file, source)` from [dbPath] into [cacheDir]
  /// and returns the written file path (`.opus`/`.mp3`), or null.
  static String? extractBlob({
    required String dbPath,
    required String file,
    required String source,
    required Directory cacheDir,
  }) {
    if (dbPath.isEmpty || !File(dbPath).existsSync()) return null;
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final ResultSet rows = db.select(
        'SELECT data FROM android WHERE file = ? AND source = ? LIMIT 1',
        <Object?>[file, source],
      );
      if (rows.isEmpty) return null;
      final Object? data = rows.first['data'];
      if (data is! Uint8List || data.isEmpty) return null;

      final String ext = file.endsWith('.opus') ? '.opus' : '.mp3';
      final File out = File('${cacheDir.path}/local_audio$ext');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(data);
      return out.path;
    } catch (e, stack) {
      ErrorLogService.instance.log('LocalAudioDb.extractBlob', e, stack);
      return null;
    } finally {
      db?.dispose();
    }
  }

  /// Convenience: query [dbPaths] in order and extract the first match into
  /// [cacheDir]. Returns the written file path, or null. Synchronous: a single
  /// indexed lookup + small blob write is fast enough for the main isolate.
  static String? queryAndExtract({
    required List<String> dbPaths,
    required String expression,
    required String reading,
    required Directory cacheDir,
  }) {
    for (final String dbPath in dbPaths) {
      final ({String file, String source})? meta =
          queryMeta(dbPath, expression, reading);
      if (meta == null) continue;
      final String? path = extractBlob(
        dbPath: dbPath,
        file: meta.file,
        source: meta.source,
        cacheDir: cacheDir,
      );
      if (path != null) return path;
    }
    return null;
  }
}
