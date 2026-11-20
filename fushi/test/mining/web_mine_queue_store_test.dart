import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// 记下每条 SELECT 的 SQL：窄查询的测试断言它们不碰 `fields_json`。
class _SelectRecorder extends QueryInterceptor {
  final List<String> selects = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add(statement);
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late FushiDatabase db;
  late WebMineQueueStore store;
  late _SelectRecorder recorder;

  setUp(() {
    recorder = _SelectRecorder();
    db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory().interceptWith(recorder)),
    );
    store = WebMineQueueStore(db);
  });

  tearDown(() => db.close());

  Future<int> enqueue(
    String book,
    int start, {
    String href = 'https://www.netflix.com/watch/81001',
  }) => store.enqueue(
    bookUid: book,
    videoKey: 'www.netflix.com/watch/81001',
    href: href,
    cueStartMs: start,
    cueEndMs: start + 2000,
    sentence: '六万年前',
    cueSentence: '六万年前',
    fields: <String, String>{'term': '六万', 'sentence': '六万年前'},
  );

  test('v90 表存在且 fresh 库 user_version 与 schemaVersion 一致', () async {
    final QueryRow ver = await db
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, greaterThanOrEqualTo(89));
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='web_mine_queue'",
        )
        .get();
    expect(rows, hasLength(1));
  });

  test('入队 → 按书取待办（id 升序）→ done 出表、failed 留表；字段 JSON 原样往返', () async {
    final int a = await enqueue('video/stream/a', 10000);
    final int b = await enqueue('video/stream/a', 5000);
    await enqueue('video/stream/b', 1000);

    List<WebMineQueueRow> rows = await store.pending('video/stream/a');
    expect(rows.map((WebMineQueueRow r) => r.id), <int>[
      a,
      b,
    ], reason: '按入队顺序而非时间轴顺序');
    expect(decodeWebMineFields(rows.first.fieldsJson), <String, String>{
      'term': '六万',
      'sentence': '六万年前',
    });
    expect(rows.first.status, WebMineQueueStatus.pending);
    expect(await store.pendingCount('video/stream/a'), 2);

    await store.markDone(a, noteId: 123, warning: 'loopback_empty');
    await store.markFailed(b, 'play_timeout');
    rows = await store.pending('video/stream/a');
    expect(rows, isEmpty);
    final List<WebMineQueueRow> all = await db.select(db.webMineQueue).get();
    // BUG-4813：写完的行直接出表（没有任何读取方），失败行留着等重试。
    expect(all.where((WebMineQueueRow r) => r.id == a), isEmpty);
    final WebMineQueueRow failedRow = all.firstWhere(
      (WebMineQueueRow r) => r.id == b,
    );
    expect(failedRow.status, WebMineQueueStatus.failed);
    expect(failedRow.error, 'play_timeout');
    expect(failedRow.minedAt, isNotNull);
    expect(await store.pendingCount('video/stream/b'), 1, reason: '别的书不受影响');
  });

  test('requeueFailed 只把失败行放回待办', () async {
    final int a = await enqueue('video/stream/a', 1000);
    final int b = await enqueue('video/stream/a', 2000);
    final int c = await enqueue('video/stream/a', 3000);
    await store.markFailed(a, 'x');
    await store.markDone(b);
    expect(await store.requeueFailed('video/stream/a'), 1);
    expect(
      (await store.pending('video/stream/a')).map((WebMineQueueRow r) => r.id),
      <int>[a, c],
    );
    expect(await store.remove(c), 1);
    expect(await store.pendingCount('video/stream/a'), 1);
  });

  /// 旧版本的完成只改状态、不删行：把 [ids] 改成那时留下的样子。
  Future<void> markLegacyDone(List<int> ids) {
    return (db.update(
      db.webMineQueue,
    )..where(($WebMineQueueTable t) => t.id.isIn(ids))).write(
      const WebMineQueueCompanion(
        status: Value<String>(WebMineQueueStatus.done),
      ),
    );
  }

  Future<List<int>> allIds() async => <int>[
    for (final WebMineQueueRow r in await db.select(db.webMineQueue).get())
      r.id,
  ];

  test('BUG-4813：deleteDone 只删旧版本留下的 done 行，不碰 pending / failed', () async {
    final int legacyA = await enqueue('video/stream/a', 1000);
    final int legacyB = await enqueue('video/stream/b', 2000);
    final int failed = await enqueue('video/stream/a', 3000);
    final int pending = await enqueue('video/stream/b', 4000);
    await markLegacyDone(<int>[legacyA, legacyB]);
    await store.markFailed(failed, 'duplicate');

    expect(await store.deleteDone(), 2);

    expect(await allIds(), unorderedEquals(<int>[failed, pending]));
    expect(await store.deleteDone(), 0);
  });

  test('#3722 c15 遗留：读方法不带删除副作用，旧 done 行只由 sweepLegacyDone 清', () async {
    final int legacy = await enqueue('video/stream/a', 1000);
    final int pending = await enqueue('video/stream/b', 2000);
    await markLegacyDone(<int>[legacy]);

    expect(await store.pendingBookUids(), <String>['video/stream/b']);
    expect(await store.openCount('video/stream/a'), 0);
    expect(
      await allIds(),
      unorderedEquals(<int>[legacy, pending]),
      reason: '读调度清单 / 角标不能顺手删行',
    );

    await store.sweepLegacyDone();
    expect(await allIds(), <int>[pending]);
  });

  test('BUG-4813：markDone 只删自己那一行，不顺带扫全表', () async {
    final int legacy = await enqueue('video/stream/a', 1000);
    final int current = await enqueue('video/stream/a', 2000);
    await markLegacyDone(<int>[legacy]);

    await store.markDone(current, noteId: 7);

    expect(await allIds(), <int>[legacy]);
  });

  test('BUG-4813：存量 done 行在调度入口收掉，每个库只扫一遍，不必等下一张卡写成功', () async {
    final int legacy = await enqueue('book-a', 1000);
    final int pending = await enqueue('book-b', 2000);
    await markLegacyDone(<int>[legacy]);

    // 没有任何一张卡写成功，只是调度来问了一次。
    expect(await store.pendingBookUids(), <String>['book-b']);
    expect(await allIds(), <int>[pending]);

    // 同一个库不再扫第二遍（另一个 store 实例也一样：调用方到处都是现建的）。
    final int late = await enqueue('book-c', 3000);
    await markLegacyDone(<int>[late]);
    await WebMineQueueStore(db).pendingBookUids();
    expect(await allIds(), unorderedEquals(<int>[pending, late]));
  });

  test('markDone 带 warning：行已出表，warning 记进诊断日志（带行 id 与 noteId）', () async {
    List<String> logged() => <String>[
      for (final ErrorLogEntry e in ErrorLogService.instance.diagnosticEntries)
        if (e.source == 'web_mine_queue.markDone') e.error,
    ];
    final int before = logged().length;
    final int quiet = await enqueue('video/stream/a', 1000);
    final int noisy = await enqueue('video/stream/a', 2000);

    await store.markDone(quiet, noteId: 1);
    expect(logged(), hasLength(before), reason: '没有 warning 不记');

    await store.markDone(noisy, noteId: 123, warning: 'loopback_empty');
    final String entry = logged().last;
    expect(logged(), hasLength(before + 1));
    expect(entry, contains('row $noisy'));
    expect(entry, contains('loopback_empty'));
    expect(entry, contains('123'));
    expect(await allIds(), isEmpty);
  });

  test('计数只数不读行：pendingCount / openCount 的 SELECT 不带 fields_json', () async {
    final int a = await enqueue('video/stream/a', 1000);
    await enqueue('video/stream/a', 2000);
    await enqueue('video/stream/a', 3000);
    await enqueue('video/stream/b', 4000);
    await store.markFailed(a, 'x');
    recorder.selects.clear();

    expect(await store.pendingCount('video/stream/a'), 2);
    expect(await store.openCount('video/stream/a'), 3, reason: '待办 + 失败');
    expect(await store.openCount('video/stream/none'), 0);

    expect(recorder.selects, hasLength(3));
    for (final String sql in recorder.selects) {
      expect(sql, contains('COUNT(*)'));
      expect(sql, isNot(contains('fields_json')));
    }
  });

  test('decodeWebMineFields 坏 JSON 回空表而不抛', () {
    expect(decodeWebMineFields('not json'), isEmpty);
    expect(decodeWebMineFields('[1,2]'), isEmpty);
    expect(decodeWebMineFields('{"a":null,"b":1}'), <String, String>{
      'a': '',
      'b': '1',
    });
  });

  test('pendingBookUids：只列有待办的书，按各自最早待办的入队顺序去重', () async {
    final int a1 = await enqueue('book-a', 1000);
    await enqueue('book-b', 2000);
    await enqueue('book-a', 3000);
    final int c1 = await enqueue('book-c', 4000);
    await store.markDone(c1, noteId: 1);
    expect(await store.pendingBookUids(), <String>['book-a', 'book-b']);
    await store.markFailed(a1, 'x');
    expect(await store.pendingBookUids(), <String>['book-b', 'book-a']);
  });

  test('pendingBookUids：只取 bookUid 一列；本地视频的暂存行（href 为空）不算', () async {
    await enqueue('remote/emby/1', 1000, href: '');
    await enqueue('book-a', 2000);
    await enqueue('remote/emby/1', 3000, href: '');
    recorder.selects.clear();

    expect(await store.pendingBookUids(), <String>['book-a']);

    expect(recorder.selects, hasLength(1));
    expect(recorder.selects.single, isNot(contains('fields_json')));
    expect(recorder.selects.single, contains('GROUP BY'));
    // 两边共用的按书待办不受这条过滤影响：暂存队列照样读得到自己的行。
    expect(await store.pending('remote/emby/1'), hasLength(2));
  });
}
