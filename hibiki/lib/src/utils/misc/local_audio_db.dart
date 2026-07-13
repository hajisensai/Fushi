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

  /// 校验 [dbPath] 是不是一个「可用」的本地音频源库：能被 sqlite3 只读打开，且含
  /// 音频 schema 的两张表（`entries` + `android`），且 `android` 至少有一行音频数据。
  ///
  /// 用于导入时把关（BUG-777）：`FilePicker` 无扩展名过滤，任何文件（没用的 zip /
  /// 备份 zip / 随便一个 sqlite）都能被选中，旧实现只复制文件就报「导入成功」，无效性
  /// 要等查询时才在 [listSources]/[queryMeta] 的 catch 里被静默吞掉 → 得到一个空音频源
  /// 却显示成功。导入前调本方法，无效即拒绝 + 给可见反馈，不再制造空音频源。
  ///
  /// 非 SQLite（zip/文本）→ `sqlite3.open` 惰性、首个 query 抛 `SqliteException` → 捕获
  /// 返回 false；缺表 / 空库同样 false。只读打开绝不修改被校验文件。
  static bool isUsableAudioSource(String dbPath) {
    if (dbPath.isEmpty || !File(dbPath).existsSync()) return false;
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final ResultSet tables = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name IN ('entries', 'android')",
      );
      final Set<String> names = <String>{
        for (final Row r in tables)
          if (r['name'] is String) r['name'] as String,
      };
      if (!names.contains('entries') || !names.contains('android')) {
        return false;
      }
      // 至少一行音频字节，否则是「结构对但没内容」的空库 = 用不了。
      return db.select('SELECT 1 FROM android LIMIT 1').isNotEmpty;
    } catch (e, stack) {
      ErrorLogService.instance
          .log('LocalAudioDb.isUsableAudioSource', e, stack);
      return false;
    } finally {
      db?.dispose();
    }
  }

  /// 枚举库内全部子来源名（`SELECT DISTINCT source`），用于「编辑来源」UI。
  /// 返回空表示库为空 / 读失败。
  static List<String> listSources(String dbPath) {
    if (dbPath.isEmpty || !File(dbPath).existsSync()) return const <String>[];
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final ResultSet rows = db.select('SELECT DISTINCT source FROM entries');
      return <String>[
        for (final Row r in rows)
          if (r['source'] is String) r['source'] as String,
      ];
    } catch (e, stack) {
      ErrorLogService.instance.log('LocalAudioDb.listSources', e, stack);
      return const <String>[];
    } finally {
      db?.dispose();
    }
  }

  /// Looks up the `(file, source)` for [expression] in [dbPath], preferring an
  /// exact [reading] match and falling back to any entry for the expression
  /// (mirrors the native handler). Returns null on miss or error.
  ///
  /// [order] = 启用子来源的优先级序（首=最高）。非空时：只在这些来源里选，按
  /// 优先级取第一个命中的；全被过滤掉返回 null。空时保持原「首个命中」行为
  /// （向后兼容无配置的旧库）。
  static ({String file, String source})? queryMeta(
    String dbPath,
    String expression,
    String reading, {
    List<String> order = const <String>[],
  }) {
    if (expression.isEmpty || dbPath.isEmpty || !File(dbPath).existsSync()) {
      return null;
    }
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      // order 为空走快路径（LIMIT 1）；非空要取全部候选行再按序挑。
      final String limit = order.isEmpty ? ' LIMIT 1' : '';
      ResultSet rows = db.select(
        'SELECT file, source FROM entries '
        'WHERE expression = ? AND reading = ?$limit',
        <Object?>[expression, reading],
      );
      if (rows.isEmpty) {
        rows = db.select(
          'SELECT file, source FROM entries WHERE expression = ?$limit',
          <Object?>[expression],
        );
      }
      if (rows.isEmpty) return null;

      final List<({String file, String source})> cands =
          <({String file, String source})>[
        for (final Row r in rows)
          if (r['file'] is String && r['source'] is String)
            (file: r['file'] as String, source: r['source'] as String),
      ];
      if (cands.isEmpty) return null;
      if (order.isEmpty) return cands.first;

      ({String file, String source})? best;
      int bestRank = 1 << 30;
      for (final ({String file, String source}) c in cands) {
        final int rank = order.indexOf(c.source);
        if (rank < 0) continue; // 禁用 / 未列入 → 跳过
        if (rank < bestRank) {
          bestRank = rank;
          best = c;
        }
      }
      return best; // 全被过滤 → null（该库无启用源命中）
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
    // 输出文件名 = (file,source) 的稳定 hash + 扩展名，与 blob 字节一一对应。
    // 已存在即同一字节，先于开库判存：跳过开库 + 读 blob + 写盘，且即便源库已被
    // 移除，缓存副本仍可直接复用（TODO-744：去重复写盘延迟）。
    final String ext = file.endsWith('.opus') ? '.opus' : '.mp3';
    final String key = _localAudioCacheKey(file: file, source: source);
    final File out = File('${cacheDir.path}/local_audio_$key$ext');
    if (out.existsSync()) return out.path;
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

String _localAudioCacheKey({required String file, required String source}) {
  int hash = 0x811c9dc5;
  for (final int codeUnit in '$source\n$file'.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
