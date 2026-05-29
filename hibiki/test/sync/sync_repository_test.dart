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

  group('hibiki client url list', () {
    test('round-trips order and enabled flags', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setHibikiClientUrls(const <HibikiClientUrl>[
        HibikiClientUrl(url: 'http://192.168.1.5:8765'),
        HibikiClientUrl(url: 'http://home.ddns.net:8765', enabled: false),
      ]);

      final List<HibikiClientUrl> urls = await repo.getHibikiClientUrls();
      expect(urls.map((HibikiClientUrl u) => u.url).toList(),
          <String>['http://192.168.1.5:8765', 'http://home.ddns.net:8765']);
      expect(urls.map((HibikiClientUrl u) => u.enabled).toList(),
          <bool>[true, false]);
    });

    test('migrates legacy single url into a one-element enabled list',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // Simulate data left by an older app version: only the legacy
      // single-url key is set (no new list key).
      await db.setPref('sync_hibiki_client_url', 'http://192.168.1.5:8765');

      final List<HibikiClientUrl> urls = await repo.getHibikiClientUrls();
      expect(urls, hasLength(1));
      expect(urls.first.url, 'http://192.168.1.5:8765');
      expect(urls.first.enabled, isTrue);
    });

    test('returns empty list when nothing is configured', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.getHibikiClientUrls(), isEmpty);
    });

    test('new list takes precedence over the legacy single url', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_hibiki_client_url', 'http://legacy.example:8765');
      await repo.setHibikiClientUrls(const <HibikiClientUrl>[
        HibikiClientUrl(url: 'http://new.example:8765'),
      ]);

      final List<HibikiClientUrl> urls = await repo.getHibikiClientUrls();
      expect(urls, hasLength(1));
      expect(urls.first.url, 'http://new.example:8765');
    });

    test('addHibikiClientUrl appends a new url, keeping order and token',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setHibikiClientUrls(
          const <HibikiClientUrl>[HibikiClientUrl(url: 'http://lan:8765')]);
      await repo.setHibikiClientToken('tok');

      final List<HibikiClientUrl> result =
          await repo.addHibikiClientUrl('http://wan:8765');

      expect(result.map((HibikiClientUrl u) => u.url).toList(),
          <String>['http://lan:8765', 'http://wan:8765']);
      expect(await repo.getHibikiClientToken(), 'tok'); // token untouched
    });

    test('addHibikiClientUrl does not add a duplicate', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setHibikiClientUrls(
          const <HibikiClientUrl>[HibikiClientUrl(url: 'http://lan:8765')]);

      final List<HibikiClientUrl> result =
          await repo.addHibikiClientUrl('http://lan:8765');

      expect(result, hasLength(1));
      expect(await repo.getHibikiClientUrls(), hasLength(1));
    });
  });
}
