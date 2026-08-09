import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v80：media_open_history（取代 jidoujisho 血统的 media_items）的 CRUD 契约。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

MediaOpenHistoryCompanion _entry(
  String source,
  String id, {
  String type = 'reader',
  int openedAt = 0,
  int position = 0,
  int duration = 0,
  String snapshot = '{}',
}) =>
    MediaOpenHistoryCompanion(
      mediaType: Value(type),
      mediaSource: Value(source),
      mediaId: Value(id),
      openedAt: Value(openedAt),
      position: Value(position),
      duration: Value(duration),
      snapshotJson: Value(snapshot),
    );

void main() {
  test('upsert 按 (mediaSource, mediaId) 幂等覆盖，重开刷新行', () async {
    final FushiDatabase db = await _openDb();
    await db
        .upsertMediaOpenHistory(_entry('src', 'a', openedAt: 1, position: 10));
    await db
        .upsertMediaOpenHistory(_entry('src', 'a', openedAt: 2, position: 20));

    final rows = await db.getAllMediaOpenHistory();
    expect(rows, hasLength(1));
    expect(rows.single.openedAt, 2);
    expect(rows.single.position, 20);
  });

  test('getAllMediaOpenHistory 按 openedAt 倒序（最近打开在前）', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertMediaOpenHistory(_entry('src', 'old', openedAt: 1));
    await db.upsertMediaOpenHistory(_entry('src', 'new', openedAt: 9));
    await db.upsertMediaOpenHistory(_entry('src', 'mid', openedAt: 5));

    final rows = await db.getAllMediaOpenHistory();
    expect(rows.map((r) => r.mediaId).toList(), <String>['new', 'mid', 'old']);
  });

  test('同 mediaId 不同 mediaSource 各自一行（PK 双列）', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertMediaOpenHistory(_entry('src1', 'x'));
    await db.upsertMediaOpenHistory(_entry('src2', 'x'));
    expect(await db.getAllMediaOpenHistory(), hasLength(2));

    await db.deleteMediaOpenHistory('src1', 'x');
    final rows = await db.getAllMediaOpenHistory();
    expect(rows.single.mediaSource, 'src2');

    await db.upsertMediaOpenHistory(_entry('src1', 'x'));
    await db.deleteMediaOpenHistoryByMediaId('x');
    expect(await db.getAllMediaOpenHistory(), isEmpty,
        reason: 'ByMediaId 跨 source 全删（removeFromReadingList 语义）');
  });

  test('trimMediaHistory 按类型保最近 N 条（openedAt 序，跨类型隔离）', () async {
    final FushiDatabase db = await _openDb();
    for (int i = 0; i < 5; i++) {
      await db.upsertMediaOpenHistory(
          _entry('src', 'r$i', type: 'reader', openedAt: i));
    }
    await db.upsertMediaOpenHistory(
        _entry('src', 'p1', type: 'player', openedAt: 0));

    await db.trimMediaHistory('reader', 3);

    final rows = await db.getAllMediaOpenHistory();
    expect(rows.where((r) => r.mediaType == 'reader').map((r) => r.mediaId),
        containsAll(<String>['r4', 'r3', 'r2']));
    expect(rows.where((r) => r.mediaType == 'reader'), hasLength(3),
        reason: '最旧的 r0/r1 被 trim');
    expect(rows.where((r) => r.mediaType == 'player'), hasLength(1),
        reason: '别的类型不受影响');
  });
}
