/// BUG-5610：host 收 client 上报的有声书调轴（[LocalLibraryHostService.putAudiobookDelay]）
/// 时，「严格较新者胜」的比较与值 + 戳的写入必须同一事务。旧实现先读后写、值与戳
/// 分两次提交。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show audiobookDelayAtPrefKey, audiobookDelayPrefKey;
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FushiDatabase db;
  late LocalLibraryHostService svc;

  const String id = 'Book';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('host_audiobook_delay');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    svc = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: root,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    await db.ensureAudiobookRow(id);
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<int> prefsVersion() =>
      db.getPrefTyped<int>(FushiDatabase.prefsVersionKey, 0);

  test('戳写失败时值一起回滚', () async {
    await svc.putAudiobookDelay(id, 300, 1000);
    await db.customStatement(
      'CREATE TRIGGER fail_stamp BEFORE INSERT ON preferences '
      "WHEN NEW.key = '${audiobookDelayAtPrefKey(id)}' "
      "BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );

    await expectLater(svc.putAudiobookDelay(id, -900, 2000), throwsA(anything));

    await db.customStatement('DROP TRIGGER fail_stamp');
    expect(await svc.getAudiobookDelay(id), (delayMs: 300, updatedAtMs: 1000));
  });

  test('较新上报一次提交落地；旧戳 / 平局上报不覆盖', () async {
    final int v0 = await prefsVersion();
    await svc.putAudiobookDelay(id, 300, 1000);
    expect(await prefsVersion() - v0, 1, reason: '值与戳应是一次提交');

    await svc.putAudiobookDelay(id, 9000, 999);
    await svc.putAudiobookDelay(id, 9000, 1000);
    expect(await svc.getAudiobookDelay(id), (delayMs: 300, updatedAtMs: 1000));
    expect(await db.getPrefTyped<int>(audiobookDelayPrefKey(id), 0), 300);
  });

  test('越界值 clamp 后落地', () async {
    await svc.putAudiobookDelay(id, 1 << 40, 1000);
    final ({int delayMs, int updatedAtMs}) got = await svc.getAudiobookDelay(
      id,
    );
    expect(got.updatedAtMs, 1000);
    expect(got.delayMs, lessThan(1 << 40));
  });
}
