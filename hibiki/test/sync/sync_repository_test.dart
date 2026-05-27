import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  test('sync preferences use typed pref codec and read legacy raw values',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await db.setPref(SyncRepository.syncStatsPreferenceKey, 'false');
    await db.setPref(SyncRepository.syncAudioBookPreferenceKey, 'true');

    expect(await repo.isSyncStatsEnabled(), isFalse);
    expect(await repo.isSyncAudioBookEnabled(), isTrue);

    await repo.setSyncStatsEnabled(true);
    await repo.setSyncAudioBookEnabled(false);

    expect(await db.getPref(SyncRepository.syncStatsPreferenceKey), 'b:true');
    expect(
      await db.getPref(SyncRepository.syncAudioBookPreferenceKey),
      'b:false',
    );
  });

  test('auto sync preference defaults to false', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    expect(await repo.isAutoSyncEnabled(), isFalse);

    await repo.setAutoSyncEnabled(true);
    expect(await repo.isAutoSyncEnabled(), isTrue);

    await repo.setAutoSyncEnabled(false);
    expect(await repo.isAutoSyncEnabled(), isFalse);
  });
}
