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
    await db.setPref(SyncRepository.syncModePreferenceKey, 'replace');

    expect(await repo.isSyncStatsEnabled(), isFalse);
    expect(await repo.isSyncAudioBookEnabled(), isTrue);
    expect(await repo.getSyncMode(), 'replace');

    await repo.setSyncStatsEnabled(true);
    await repo.setSyncAudioBookEnabled(false);
    await repo.setSyncMode('merge');

    expect(await db.getPref(SyncRepository.syncStatsPreferenceKey), 'b:true');
    expect(
      await db.getPref(SyncRepository.syncAudioBookPreferenceKey),
      'b:false',
    );
    expect(await db.getPref(SyncRepository.syncModePreferenceKey), 's:merge');
  });
}
