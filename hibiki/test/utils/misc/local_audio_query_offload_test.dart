import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:hibiki/src/utils/misc/local_audio_db.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';

/// 查词发音性能/并发根因修复的守卫（BUG：慢库无上限阻塞 UI isolate +
/// readWrite 抢锁 fail-open 成「暂无发音」）：
///
/// 1. 查询路径（LocalAudioDb.queryMeta / extractBlob）必须 `OpenMode.readOnly`
///    打开、零 DDL——索引统一由绑定期的 `ensureIndexes` 建（对齐 Android
///    `TtsChannelHandler` 启动后台建索引的做法）。
/// 2. 桌面 `TtsChannel.queryLocalAudio` / `extractLocalAudio` 的同步 SQLite 体
///    必须跑在 `Isolate.run` 里，否则调用方（lookup_audio_playback）的
///    `.timeout(500ms)` 是死代码：async 函数体在首个 await 前同步跑完。
/// 3. `TtsChannel.speak` 已删（全仓零调用者的死代码），不得复活。
String _read(String path) => File(path).readAsStringSync();

/// 取 [source] 中从 [startMarker] 到 [endMarker]（不含）之间的方法体切片。
String _slice(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  final int end = source.indexOf(endMarker, start);
  expect(end, greaterThan(start), reason: '找不到 $endMarker');
  return source.substring(start, end);
}

void main() {
  group('source guards: read-only query path + Isolate.run offload', () {
    final String dbSrc = _read('lib/src/utils/misc/local_audio_db.dart');
    final String ttsSrc = _read('lib/src/utils/misc/tts_channel.dart');

    test('LocalAudioDb.ensureIndexes exists with the exact signature', () {
      expect(
          dbSrc, contains('static Future<void> ensureIndexes(String dbPath)'));
    });

    test('CREATE INDEX DDL only lives in the _indexDdls const, nowhere else',
        () {
      final int ddlConst = dbSrc.indexOf('_indexDdls = <String>[');
      final int ensureStart =
          dbSrc.indexOf('static Future<void> ensureIndexes');
      expect(ddlConst, greaterThanOrEqualTo(0));
      expect(ensureStart, greaterThan(ddlConst));
      final Iterable<Match> hits = 'CREATE INDEX'.allMatches(dbSrc);
      expect(hits.length, 2, reason: '恰好两条索引 DDL（entries + android）');
      for (final Match m in hits) {
        expect(m.start, inInclusiveRange(ddlConst, ensureStart),
            reason: '查询路径（queryMeta/extractBlob）不得再有任何 DDL');
      }
    });

    test('queryMeta opens readOnly and has no DDL / no readWrite', () {
      final String body = _slice(
          dbSrc,
          'static ({String file, String source})? queryMeta(',
          'static String? extractBlob({');
      expect(body, contains('OpenMode.readOnly'));
      expect(body.contains('OpenMode.readWrite'), isFalse);
      expect(body.contains('CREATE INDEX'), isFalse);
    });

    test('extractBlob opens readOnly and has no DDL / no readWrite', () {
      final String body = _slice(dbSrc, 'static String? extractBlob({',
          'static String? queryAndExtract({');
      expect(body, contains('OpenMode.readOnly'));
      expect(body.contains('OpenMode.readWrite'), isFalse);
      expect(body.contains('CREATE INDEX'), isFalse);
    });

    test('readWrite is used exactly once, inside ensureIndexes', () {
      final Iterable<Match> hits = 'OpenMode.readWrite'.allMatches(dbSrc);
      expect(hits.length, 1, reason: '唯一的读写打开点只能是 ensureIndexes 的建索引连接');
      final int ensureStart =
          dbSrc.indexOf('static Future<void> ensureIndexes');
      final int queryStart = dbSrc.indexOf('queryMeta(');
      expect(hits.first.start, greaterThan(ensureStart));
      expect(hits.first.start, lessThan(queryStart));
    });

    test('desktop setLocalAudioDbs kicks ensureIndexes per db (unawaited)', () {
      final String body = _slice(
          ttsSrc,
          'Future<bool> setLocalAudioDbs(List<LocalAudioDbConfig> dbs) async {',
          'Future<bool> setLocalAudioDb(String path)');
      expect(body, contains('unawaited(LocalAudioDb.ensureIndexes('),
          reason: '绑定期后台补索引，对齐 Android 的做法');
    });

    test('desktop queryLocalAudio runs its SQLite body in Isolate.run', () {
      final String body = _slice(
          ttsSrc,
          'Future<Map<String, dynamic>?> queryLocalAudio(',
          'Future<String?> extractLocalAudio(');
      expect(body, contains('Isolate.run('),
          reason: '同步 SQLite 不下放 isolate，调用方 .timeout(500ms) 就是死代码');
      expect(body, contains('LocalAudioDb.queryMeta('));
    });

    test('desktop extractLocalAudio runs its SQLite body in Isolate.run', () {
      final String body = _slice(ttsSrc, 'Future<String?> extractLocalAudio(',
          'Future<bool> playFile(');
      expect(body, contains('Isolate.run('));
      expect(body, contains('LocalAudioDb.extractBlob('));
    });

    test('desktop queryLocalAudio waits out the binding-time index build', () {
      final String body = _slice(
          ttsSrc,
          'Future<Map<String, dynamic>?> queryLocalAudio(',
          'Future<String?> extractLocalAudio(');
      expect(body, contains('LocalAudioDb.waitForPendingIndexing('),
          reason: 'BUG-1365：查询不排在自家 ensureIndexes 写连接之后，'
              '就会撞 CREATE INDEX 的独占锁 → busy 超时 → 吞成 null＝「暂无发音」');
      expect(body.indexOf('LocalAudioDb.waitForPendingIndexing('),
          lessThan(body.indexOf('Isolate.run(')),
          reason: '等必须发生在把查询交给 Isolate.run 之前，等在后面等于没等');
    });

    test('desktop extractLocalAudio waits out the binding-time index build',
        () {
      final String body = _slice(ttsSrc, 'Future<String?> extractLocalAudio(',
          'Future<bool> playFile(');
      expect(body, contains('LocalAudioDb.waitForPendingIndexing('),
          reason: 'BUG-1365：blob 提取同样会撞建索引的写锁');
      expect(body.indexOf('LocalAudioDb.waitForPendingIndexing('),
          lessThan(body.indexOf('Isolate.run(')));
    });

    test('dead code speak stays deleted (zero callers repo-wide)', () {
      expect(ttsSrc.contains('Future<void> speak('), isFalse,
          reason: 'TtsChannel.speak 全仓零调用者，已删除，不得复活');
      expect(ttsSrc.contains("invokeMethod('speak'"), isFalse);
    });
  });

  group('desktop TtsChannel local-audio behavior (real sqlite via Isolate.run)',
      () {
    late Directory tmp;
    late String dbPath;

    void seedDb(String path) {
      final Database db = sqlite3.open(path);
      db.execute('CREATE TABLE entries '
          '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
      db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
      db.execute("INSERT INTO entries VALUES ('勉強','べんきょう','a.mp3','src1')");
      final PreparedStatement stmt =
          db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
      stmt.execute(<Object?>[
        'a.mp3',
        'src1',
        Uint8List.fromList(<int>[1, 2])
      ]);
      stmt.dispose();
      db.dispose();
    }

    bool hasIndex(String path, String name) {
      final Database probe = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        // 与生产查询连接同款 busy_timeout：后台 ensureIndexes 写提交瞬间持
        // 独占锁，不等锁的裸探针会 SQLITE_BUSY 误红。
        probe.execute('PRAGMA busy_timeout = 10000');
        return probe.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
          <Object?>[name],
        ).isNotEmpty;
      } finally {
        probe.dispose();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_tts_offload');
      dbPath = '${tmp.path}/audio.db';
      seedDb(dbPath);
    });

    tearDown(() async {
      await TtsChannel.instance.setLocalAudioDbs(const <LocalAudioDbConfig>[]);
      // setLocalAudioDbs 派发的后台 ensureIndexes 还握着 readWrite 句柄时，
      // Windows 删临时目录是 errno 32；先确定性排空在途任务再删。
      await LocalAudioDb.waitForPendingIndexing();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('setLocalAudioDbs + queryLocalAudio round-trips through Isolate.run',
        () async {
      await TtsChannel.instance.setLocalAudioDbs(
          <LocalAudioDbConfig>[LocalAudioDbConfig(path: dbPath)]);
      final Map<String, dynamic>? hit =
          await TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう');
      expect(hit, isNotNull);
      expect(hit!['file'], 'a.mp3');
      expect(hit['source'], 'src1');
      expect(hit['dbIndex'], 0);

      final Map<String, dynamic>? miss =
          await TtsChannel.instance.queryLocalAudio('なし', '');
      expect(miss, isNull);
    });

    test('queryLocalAudio honors dbIndex bounds', () async {
      await TtsChannel.instance.setLocalAudioDbs(
          <LocalAudioDbConfig>[LocalAudioDbConfig(path: dbPath)]);
      expect(
          await TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう', dbIndex: 1),
          isNull,
          reason: '越界 dbIndex 不得命中');
      expect(
          await TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう', dbIndex: 0),
          isNotNull);
    });

    test('binding builds the indexes in the background (Android parity)',
        () async {
      expect(hasIndex(dbPath, 'idx_entries_expr_read'), isFalse,
          reason: '导入的库本无索引');
      await TtsChannel.instance.setLocalAudioDbs(
          <LocalAudioDbConfig>[LocalAudioDbConfig(path: dbPath)]);
      // 确定性等后台 ensureIndexes 收尾（对齐生产删除路径用的同一原语）。
      await LocalAudioDb.waitForPendingIndexing(dbPath);
      expect(hasIndex(dbPath, 'idx_entries_expr_read'), isTrue);
      expect(hasIndex(dbPath, 'idx_android_file_source'), isTrue);
    });
  });

  /// BUG-1365 的行为守卫：绑定期 `ensureIndexes` 是**我们自己**对同一库文件开的
  /// readWrite 连接。旧实现里查询与它完全无序，只靠只读连接 3s 的 busy_timeout
  /// 赌能拿到 shared 锁；赌输就 SQLITE_BUSY → `queryMeta` 的 catch 吞成 null，
  /// 与「库里真没这个词」同形（用户＝「暂无发音」，CI＝本文件
  /// `queryLocalAudio honors dbIndex bounds` 偶发 `Expected not null`）。
  ///
  /// 这里不测时序快慢（那会造出第二个 flaky），只测**顺序契约**：一个大到建索引
  /// 明显耗时的库，绑定后立刻查询，查询返回时索引必须已经建好——即读端确实排在
  /// 自家写端之后。旧实现下查询会在建索引还在途时就返回（实测 6/6 轮）。
  group('BUG-1365: queries are ordered after our own index build', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_tts_order');
      dbPath = '${tmp.path}/audio.db';
      final Database db = sqlite3.open(dbPath);
      db.execute('CREATE TABLE entries '
          '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
      db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
      // 索引要建得「够慢」才能暴露无序窗口：真实 Yomitan 本地音频库是十万行级。
      db.execute('BEGIN');
      final PreparedStatement ins =
          db.prepare('INSERT INTO entries (expression, reading, file, source) '
              'VALUES (?,?,?,?)');
      for (int i = 0; i < 200000; i++) {
        ins.execute(<Object?>['w$i', 'r$i', 'f$i.mp3', 'src1']);
      }
      ins.execute(<Object?>['勉強', 'べんきょう', 'a.mp3', 'src1']);
      ins.dispose();
      db.execute('COMMIT');
      final PreparedStatement stmt =
          db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
      stmt.execute(<Object?>[
        'a.mp3',
        'src1',
        Uint8List.fromList(<int>[1, 2])
      ]);
      stmt.dispose();
      db.dispose();
    });

    tearDown(() async {
      await TtsChannel.instance.setLocalAudioDbs(const <LocalAudioDbConfig>[]);
      await LocalAudioDb.waitForPendingIndexing();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    bool indexBuilt(String path) {
      final Database probe = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        probe.execute('PRAGMA busy_timeout = 10000');
        return probe.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
          <Object?>['idx_entries_expr_read'],
        ).isNotEmpty;
      } finally {
        probe.dispose();
      }
    }

    test('queryLocalAudio does not return while indexing is still in flight',
        () async {
      expect(indexBuilt(dbPath), isFalse, reason: '导入的库本无索引');
      await TtsChannel.instance.setLocalAudioDbs(
          <LocalAudioDbConfig>[LocalAudioDbConfig(path: dbPath)]);
      final Map<String, dynamic>? hit =
          await TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう', dbIndex: 0);
      expect(indexBuilt(dbPath), isTrue,
          reason: '查询返回时自家建索引还在途 → 读写无序，撞锁只是时间问题（BUG-1365）');
      expect(hit, isNotNull);
      expect(hit!['file'], 'a.mp3');
    });
  });
}
