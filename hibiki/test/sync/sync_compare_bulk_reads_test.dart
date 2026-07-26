import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('getPrefsWithPrefix 把前缀里的 LIKE 通配符当字面量', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    await db.setPrefTyped<int>('audiobook_pos_bookA', 111);
    await db.setPrefTyped<int>('audiobook_pos_bookB', 222);
    // `_` 在 LIKE 里是单字符通配：不转义的话下面这条会被 `audiobook_pos_` 误匹配。
    await db.setPrefTyped<int>('audiobook_posXbogus', 999);
    await db.setPrefTyped<int>('unrelated_key', 7);

    final Map<String, String> got =
        await db.getPrefsWithPrefix('audiobook_pos_');
    expect(got.keys.toSet(), <String>{'bookA', 'bookB'});
  });

  test('getAllAudiobookPositions 一次取回全部位置并跳过 0/无记录', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await repo.setAudiobookPosition('bookA', 5000);
    await repo.setAudiobookPosition('bookB', 0);
    await db.setPrefTyped<int>('audiobook_pos_at_bookA', 999999);

    final Map<String, int> got = await repo.getAllAudiobookPositions();
    expect(got['bookA'], 5000);
    expect(got.containsKey('bookB'), isFalse,
        reason: '0 = 无记录，与逐条 getAudiobookPosition 的 default 0 语义一致');
    expect(got.containsKey('bookC'), isFalse);
    expect(got.containsKey('at_bookA'), isFalse, reason: '更新时间键不能被误当成 bookKey');
  });

  test('getAllAudiobookPositions 与逐条读结果一致', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    for (int i = 0; i < 20; i++) {
      await repo.setAudiobookPosition('book$i', (i + 1) * 1000);
    }
    final Map<String, int> bulk = await repo.getAllAudiobookPositions();
    for (int i = 0; i < 20; i++) {
      expect(bulk['book$i'], await repo.getAudiobookPosition('book$i'));
    }
  });

  test('getSyncBaselinesByDimension 只取该维度且与逐条读一致', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    await db.setSyncBaseline('bookA', 'progress', 100);
    await db.setSyncBaseline('bookB', 'progress', 200);
    await db.setSyncBaseline('bookA', 'statistics', 300);

    final Map<String, int> got =
        await db.getSyncBaselinesByDimension('progress');
    expect(got, <String, int>{'bookA': 100, 'bookB': 200});
    expect(got['bookA'], await db.getSyncBaseline('bookA', 'progress'));
  });
}
