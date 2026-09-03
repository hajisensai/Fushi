import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late WebMineQueueStore store;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    store = WebMineQueueStore(db);
  });

  tearDown(() => db.close());

  Future<int> enqueue(String book, int start, {String status = 'p'}) =>
      store.enqueue(
        bookUid: book,
        videoKey: 'www.netflix.com/watch/81001',
        href: 'https://www.netflix.com/watch/81001',
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

  test('入队 → 按书取待办（id 升序）→ done/failed 不再出现在待办；字段 JSON 原样往返', () async {
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
    final WebMineQueueRow doneRow = all.firstWhere(
      (WebMineQueueRow r) => r.id == a,
    );
    expect(doneRow.status, WebMineQueueStatus.done);
    expect(doneRow.noteId, 123);
    expect(doneRow.error, 'loopback_empty');
    expect(doneRow.minedAt, isNotNull);
    expect(
      all.firstWhere((WebMineQueueRow r) => r.id == b).status,
      WebMineQueueStatus.failed,
    );
    expect(await store.pendingCount('video/stream/b'), 1, reason: '别的书不受影响');
  });

  test('requeueFailed 只把失败行放回待办；deleteFinished 只删非待办行', () async {
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
    expect(await store.deleteFinished('video/stream/a'), 1);
    expect((await db.select(db.webMineQueue).get()).length, 2);
    expect(await store.remove(c), 1);
    expect(await store.pendingCount('video/stream/a'), 1);
  });

  test('decodeWebMineFields 坏 JSON 回空表而不抛', () {
    expect(decodeWebMineFields('not json'), isEmpty);
    expect(decodeWebMineFields('[1,2]'), isEmpty);
    expect(decodeWebMineFields('{"a":null,"b":1}'), <String, String>{
      'a': '',
      'b': '1',
    });
  });
}
