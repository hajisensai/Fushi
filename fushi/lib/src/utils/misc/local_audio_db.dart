import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show fnv1a32Hex;
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 本地音频库这次**没能给出答案**的原因。共同点：库里到底有没有这个词，
/// 这次**根本没查出来**——与「库读到了、里面确实没有」是两件事。
enum LocalAudioUnavailableReason {
  /// 库文件被并发写者独占（`SQLITE_BUSY` / `SQLITE_LOCKED`），等满
  /// `busy_timeout` 仍没拿到共享锁。最典型的写者就是我们自己绑定期的
  /// [LocalAudioDb.ensureIndexes]（大库建索引可达数秒）。
  busy,

  /// 调用方的查询预算先于库自己的 `busy_timeout` 到点——库还在忙，
  /// 只是我们不等了。**预算耗尽不是「这个词没有发音」的判据。**
  timedOut,
}

/// 一次本地音频库读操作没能给出答案：忙 / 预算耗尽。
///
/// 根因修复（BUG-1413）：[LocalAudioDb.queryMeta] / [LocalAudioDb.extractBlob]
/// 旧实现把 `SQLITE_BUSY` 和「查不到行」都压成同一个 `null`，调用方无从区分，
/// 用户只看到「暂无发音」，无从知道其实是数据库正忙。把「没有答案」从一个
/// **值**改成一个**类型**后，它与「没有这个词」在编译期就分开了，
/// 调用方不可能再无意中把两者当成一回事。
///
/// 与远端音源的 `RemoteLookupUnreachableError` 是同一套分工：
/// 「不可达 / 没答上」抛异常，「可达但确实没有音频」返回 null。
class LocalAudioUnavailableError implements Exception {
  const LocalAudioUnavailableError({
    required this.reason,
    this.dbPath = '',
    this.detail = '',
  });

  final LocalAudioUnavailableReason reason;

  /// 出问题的库路径；预算耗尽（[LocalAudioUnavailableReason.timedOut]）时调用方
  /// 通常只知道 dbIndex 拿不到路径，留空。
  final String dbPath;

  /// 底层错误的可读描述（如 sqlite 的 `SqliteException` 文本），供错误日志排查。
  final String detail;

  @override
  String toString() {
    final String where = dbPath.isEmpty ? '' : ' db=$dbPath';
    final String why = detail.isEmpty ? '' : ' ($detail)';
    return 'LocalAudioUnavailableError(${reason.name})$where$why';
  }
}

/// `SQLITE_BUSY` / `SQLITE_LOCKED`：库被别的连接占着，这次没读成。
/// `resultCode` 是主结果码（`extendedResultCode & 0xFF`），故 `BUSY_SNAPSHOT`
/// 之类的扩展码也一并归入。
bool _isBusy(SqliteException e) =>
    e.resultCode == 5 /* SQLITE_BUSY */ ||
    e.resultCode == 6 /* SQLITE_LOCKED */;

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
  /// 用于导入时把关（BUG-779）：`FilePicker` 无扩展名过滤，任何文件（没用的 zip /
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

  /// 两条查询索引的单一真相源（只被 [ensureIndexes] 消费；查询路径
  /// [queryMeta] / [extractBlob] 一律只读打开，**不得**再出现任何 DDL）。
  ///
  /// 用「表 + 列」而非裸 DDL 串描述（BUG-1667）：建索引 DDL 的 `IF NOT EXISTS`
  /// 只按**索引名**判存在，而 Yomitan 本地音频服务器导出的 android.db 自带的
  /// 等价索引叫 `idx_expr_reading` / `idx_android`（实测真库两条都有），名字对不上
  /// 就照建一遍完全重复的索引。要按「有没有等价索引」判，就得知道列。
  ///
  /// （本注释刻意不写出建索引 DDL 的字面量：`local_audio_query_offload_test` 会扫
  /// 全文件断言该字面量只出现在建索引区段内，注释里写一次就会把守卫弄红。）
  static const List<({String name, String table, List<String> columns})>
      _indexSpecs = <({String name, String table, List<String> columns})>[
    (
      name: 'idx_entries_expr_read',
      table: 'entries',
      columns: <String>['expression', 'reading'],
    ),
    (
      name: 'idx_android_file_source',
      table: 'android',
      columns: <String>['file', 'source'],
    ),
  ];

  /// 每个库路径**在途**的建索引任务（key = 调用方传入的解析后路径；整条数据流
  /// —— `LocalAudioManager._configFor` → `TtsChannel.setLocalAudioDbs` →
  /// 本类 —— 用的是同一份 `resolveInternalPath` 结果，字符串一致）。
  /// 用途：① 同一路径重复绑定去重；② [waitForPendingIndexing] 让删除方在删
  /// 库文件前等后台 readWrite 句柄释放（Windows 上删被打开的文件是 errno 32）。
  static final Map<String, Future<void>> _pendingIndexing =
      <String, Future<void>>{};

  /// 等 [dbPath] 上在途的建索引连接结束（没有则立即完成）；[dbPath] 为 null 时
  /// 等**全部**在途任务（测试 teardown 删临时目录前排空用）。永不抛。
  static Future<void> waitForPendingIndexing([String? dbPath]) {
    if (dbPath != null) {
      return _pendingIndexing[dbPath] ?? Future<void>.value();
    }
    return Future.wait(_pendingIndexing.values.toList())
        .then((List<void> _) {});
  }

  /// 绑定期一次性把 [dbPath] 缺失的两条查询索引补上（根因修复：导入的 Yomitan
  /// Local Audio Server 库原本无索引，`SELECT ... WHERE expression=?` 是全表扫描
  /// ——数十万行时单次查词几百 ms。Android 原生 `TtsChannelHandler` 早在
  /// `setLocalAudioDb` 时后台线程建过同名索引；桌面对齐同一做法：
  /// `TtsChannel.setLocalAudioDbs` 绑定库列表时对每个库 unawaited 跑一次本方法）。
  ///
  /// 索引持久化进**库文件**，故建一次后任何连接（含弹窗词典独立 isolate 的只读
  /// 连接）都受益；查询路径因此可以永远 [OpenMode.readOnly] 打开，不再与并发
  /// isolate 抢写锁。首次在大库上建索引可达数秒，DDL 在 [Isolate.run] 里跑，
  /// 不阻塞调用方 isolate。两条 DDL 各自独立 try：某表不存在（如只有 android 表
  /// 的库）时另一条仍能建，互不牵连。任何失败（只读介质 / 无写权限 / 被独占）
  /// 记 [ErrorLogService] 后返回，不抛——建不了不致命，查询仍可跑（只是慢）。
  static Future<void> ensureIndexes(String dbPath) {
    if (dbPath.isEmpty || !File(dbPath).existsSync()) {
      return Future<void>.value();
    }
    // 同一路径已有在途任务：复用（重复绑定去重），不再开第二条写连接。
    final Future<void>? pending = _pendingIndexing[dbPath];
    if (pending != null) return pending;
    // 注册用显式 Completer 而非直接存 `_ensureIndexesImpl(..).whenComplete(..)`
    // 的链式 future：后者在 flutter tester（TestWidgetsFlutterBinding）下实测
    // 会丢失对外部监听者的完成通知（await 它的 waitForPendingIndexing 永不
    // 返回），Completer 形式在同环境下稳定送达。语义完全等价。
    final Completer<void> done = Completer<void>();
    _pendingIndexing[dbPath] = done.future;
    _ensureIndexesImpl(dbPath).whenComplete(() {
      _pendingIndexing.remove(dbPath);
      done.complete();
    });
    return done.future;
  }

  static Future<void> _ensureIndexesImpl(String dbPath) async {
    try {
      await Isolate.run(() {
        // 先只读体检：缺哪条才建哪条。引用模式（BUG-483）下 [dbPath] 是**用户的
        // 原始文件**，「不复制」的用户显然也不想被我们写；真库自带等价索引时，
        // 这里连 readWrite 句柄都不会开（BUG-1667）。
        List<({String name, String table, List<String> columns})> missing;
        try {
          missing = <({String name, String table, List<String> columns})>[];
          final Database probe = sqlite3.open(dbPath, mode: OpenMode.readOnly);
          try {
            for (final ({String name, String table, List<String> columns}) spec
                in _indexSpecs) {
              if (!_hasEquivalentIndex(probe, spec.table, spec.columns)) {
                missing.add(spec);
              }
            }
          } finally {
            probe.dispose();
          }
        } catch (_) {
          // 连只读都开不了（WAL 库拿不到 -shm 等）：退回改前的行为——照旧尝试建全部
          // 索引。这条兜底只在「我们读都读不了」时才走，而那正是旧实现同样会去开
          // readWrite 的场景，故不会比改前更差（Never break userspace）。
          missing = _indexSpecs.toList();
        }
        if (missing.isEmpty) return;

        final Database db = sqlite3.open(dbPath, mode: OpenMode.readWrite);
        try {
          // 建索引的提交需要独占锁；并发查询 isolate 的只读连接正持
          // shared 锁时会立刻 SQLITE_BUSY（默认无 busy handler）→ 被下面的
          // per-DDL catch 吞掉＝索引永远建不出来。busy_timeout 让 sqlite 自己
          // 等读者放锁（读者是毫秒级瞬态），这是 SQLite 标准并发机制。
          db.execute('PRAGMA busy_timeout = 10000');
          for (final ({String name, String table, List<String> columns}) spec
              in missing) {
            try {
              db.execute('CREATE INDEX IF NOT EXISTS ${spec.name} '
                  'ON ${spec.table}(${spec.columns.join(', ')})');
            } catch (_) {
              // 目标表不存在等：建不了不致命，不牵连另一条。
            }
          }
        } finally {
          db.dispose();
        }
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('LocalAudioDb.ensureIndexes', e, stack);
    }
  }

  /// [table] 上是否已存在能服务 `WHERE col0=? AND col1=? ...` 的索引：某个现有
  /// 索引的**前缀列**恰好等于 [columns]（顺序一致）。前缀即可——SQLite 用
  /// `(a,b,c)` 上的索引服务 `a=? AND b=?` 与专门的 `(a,b)` 索引等效。
  ///
  /// 排除两类不可用索引：
  /// - **部分索引**（`CREATE INDEX ... WHERE ...`）：只覆盖部分行，不能替代全量索引；
  ///   由 `PRAGMA index_list` 的 `partial` 列判定。
  /// - **表达式索引**（如真库里的 `idx_entries_unique_audio` 用了 `IFNULL(...)`）：
  ///   `PRAGMA index_info` 对表达式列回 `name = null`，与任何列名都不相等，自然不匹配。
  ///
  /// 任何一步失败（表不存在 / PRAGMA 不可用）都按「没有等价索引」返回 false，
  /// 让调用方走原来的建索引路径——保守方向，绝不因体检失败而少建索引。
  static bool _hasEquivalentIndex(
    Database db,
    String table,
    List<String> columns,
  ) {
    try {
      final ResultSet indexes = db.select('PRAGMA index_list($table)');
      for (final Row index in indexes) {
        // partial 列在 SQLite < 3.8.9 不存在 → null，按「非部分索引」处理。
        final Object? partial = index['partial'];
        if (partial is int && partial != 0) continue;
        final Object? name = index['name'];
        if (name is! String) continue;
        final ResultSet info = db.select('PRAGMA index_info(${_quote(name)})');
        if (info.length < columns.length) continue;
        bool prefixMatches = true;
        for (int i = 0; i < columns.length; i++) {
          // index_info 按 seqno 排序返回；表达式列的 name 为 null → 不匹配。
          if (info[i]['name'] != columns[i]) {
            prefixMatches = false;
            break;
          }
        }
        if (prefixMatches) return true;
      }
    } catch (_) {
      // 表不存在 / PRAGMA 失败：按「没有等价索引」处理，交给建索引路径。
    }
    return false;
  }

  /// SQLite 标识符字面量（`PRAGMA index_info` 不接受占位符，只能拼串）。
  static String _quote(String identifier) =>
      "'${identifier.replaceAll("'", "''")}'";

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
      // 只读打开：索引由绑定期的 [ensureIndexes] 负责，查询路径零 DDL、零写锁
      // ——与弹窗独立 isolate 并发查询绝不互相抢 readWrite 句柄（BUG 根因：
      // 抢锁失败被 catch 吞成 null → 用户看到「暂无发音」）。busy_timeout：
      // [ensureIndexes] 的写提交瞬间持独占锁，读者不等锁会 SQLITE_BUSY 被
      // catch 吞成 null；让 sqlite 自己等写者放锁（提交是瞬态）。
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = 3000');
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
    } on SqliteException catch (e, stack) {
      // BUG-1413：撞锁**不是**「库里没这个词」。旧实现在这里 `return null`，与上面
      // 三处真·未命中的 null 完全同形，调用方（WordAudioResolver）只能当 miss 处理
      // → 用户看到「暂无发音」，无从知道数据库正忙。抛可区分的类型，让「没有答案」
      // 走独立路径；只读连接的 busy_timeout 已经等过了，这里不再重试、不加延迟。
      if (_isBusy(e)) {
        throw LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.busy,
          dbPath: dbPath,
          detail: '$e',
        );
      }
      // 其余 sqlite 错误（缺表 / 损坏 / 无权限）是**稳定**故障，不是瞬态：库要么
      // 一直答不了要么导入时就被 [isUsableAudioSource] 拦下。保持既有 log + null。
      ErrorLogService.instance.log('LocalAudioDb.queryMeta', e, stack);
      return null;
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
    // BUG-1124 迁移：旧弱口径键名的缓存副本原地改名到新键名（对齐
    // AudiobookStorage.ensurePersistDir 的 renameSync 先例）。保住「源库已被
    // 移除时缓存副本仍可复用」的既有语义；ASCII 键新旧同值，不进本分支。
    final String legacyKey = _legacyLocalAudioCacheKey(
      file: file,
      source: source,
    );
    if (legacyKey != key) {
      final File legacy = File('${cacheDir.path}/local_audio_$legacyKey$ext');
      if (legacy.existsSync()) {
        try {
          legacy.renameSync(out.path);
          return out.path;
        } catch (_) {
          // 改名失败（并发占用等）：落回正常提取路径重新写盘，不致命。
        }
      }
    }
    if (dbPath.isEmpty || !File(dbPath).existsSync()) return null;
    Database? db;
    try {
      // 只读打开 + busy_timeout：同 [queryMeta]，索引由 [ensureIndexes] 在
      // 绑定期负责，写提交瞬间的独占锁由 sqlite 自己等。
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = 3000');
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
    } on SqliteException catch (e, stack) {
      // 同 [queryMeta]（BUG-1413）：撞锁是「这次没取成」，不是「这个词条没有音频」。
      // 旧实现的 null 会让 WordAudioResolver 跳过该库继续下一源，最终同样落到
      // 「暂无发音」且用户完全无从分辨。
      if (_isBusy(e)) {
        throw LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.busy,
          dbPath: dbPath,
          detail: '$e',
        );
      }
      ErrorLogService.instance.log('LocalAudioDb.extractBlob', e, stack);
      return null;
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

/// `(source, file)` → 缓存文件名键：FNV-1a 32 位、UTF-8 逐字节强口径。
///
/// BUG-1124 根因修复：旧实现把 16 位 UTF-16 码元整体 XOR 进哈希（FNV-1a 的
/// 字节口径被喂宽单元，CJK 每字符扩散轮数 3→1），真实碰撞对如
/// `jpod\n肌陒衎柚.mp3` 与 `jpod\n汅肘鹾圃.mp3` 同键 → 两个不同词条共用一个
/// 缓存文件，后查的词永远播放先查词条的音频。UTF-8 逐字节口径与
/// [AudiobookStorage] 一致（hibiki_core 单一真相源）。ASCII 键两口径同值，
/// 存量 ASCII 缓存零迁移；CJK 旧键由 [LocalAudioDb.extractBlob] 惰性 rename。
String _localAudioCacheKey({required String file, required String source}) =>
    fnv1a32Hex(utf8.encode('$source\n$file'));

/// BUG-1124 前的弱口径旧键（16 位码元整体 XOR），仅供 [LocalAudioDb.extractBlob]
/// 的惰性迁移路径定位旧缓存文件；新代码不得再用。
String _legacyLocalAudioCacheKey({
  required String file,
  required String source,
}) =>
    fnv1a32Hex('$source\n$file'.codeUnits);
