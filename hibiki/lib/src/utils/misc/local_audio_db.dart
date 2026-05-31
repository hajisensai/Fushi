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

  /// Looks up [expression] (preferring an exact [reading] match) across the
  /// given read-only [dbPaths], writes the first matching audio blob into
  /// [cacheDir], and returns the written file path — or null if nothing matched
  /// or any error occurred. Synchronous: a single indexed lookup + small blob
  /// write is fast enough for the main isolate.
  static String? queryAndExtract({
    required List<String> dbPaths,
    required String expression,
    required String reading,
    required Directory cacheDir,
  }) {
    if (expression.isEmpty) return null;
    for (final String dbPath in dbPaths) {
      if (dbPath.isEmpty || !File(dbPath).existsSync()) continue;
      Database? db;
      try {
        db = sqlite3.open(dbPath, mode: OpenMode.readOnly);

        // 1. Metadata: prefer an exact expression+reading match, else any
        //    entry for the expression (mirrors the native handler).
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
        if (rows.isEmpty) continue;
        final Object? file = rows.first['file'];
        final Object? source = rows.first['source'];
        if (file is! String || source is! String) continue;

        // 2. Blob: the audio bytes for that (file, source).
        final ResultSet blobRows = db.select(
          'SELECT data FROM android WHERE file = ? AND source = ? LIMIT 1',
          <Object?>[file, source],
        );
        if (blobRows.isEmpty) continue;
        final Object? data = blobRows.first['data'];
        if (data is! Uint8List || data.isEmpty) continue;

        final String ext = file.endsWith('.opus') ? '.opus' : '.mp3';
        final File out = File('${cacheDir.path}/local_audio$ext');
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(data);
        return out.path;
      } catch (e, stack) {
        ErrorLogService.instance.log('LocalAudioDb.queryAndExtract', e, stack);
      } finally {
        db?.dispose();
      }
    }
    return null;
  }
}
