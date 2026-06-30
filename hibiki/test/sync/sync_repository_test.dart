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
    await db.setPref(SyncRepository.syncAudioBookPreferenceKey, 'false');
    await db.setPref(SyncRepository.syncDictionaryPreferenceKey, 'true');

    expect(await repo.isSyncStatsEnabled(), isFalse);
    expect(await repo.isSyncAudioBookEnabled(), isTrue);
    expect(await repo.isSyncDictionaryEnabled(), isTrue);

    await repo.setSyncStatsEnabled(true);
    await repo.setSyncAudioBookEnabled(false);
    await repo.setSyncDictionaryEnabled(false);

    expect(await db.getPref(SyncRepository.syncStatsPreferenceKey), 'b:true');
    expect(
      await db.getPref(SyncRepository.syncAudioBookPreferenceKey),
      'b:true',
    );
    expect(
      await db.getPref(SyncRepository.syncDictionaryPreferenceKey),
      'b:false',
    );
  });

  test('dictionary sync preference defaults to false', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    expect(await repo.isSyncDictionaryEnabled(), isFalse);

    await repo.setSyncDictionaryEnabled(true);
    expect(await repo.isSyncDictionaryEnabled(), isTrue);

    await repo.setSyncDictionaryEnabled(false);
    expect(await repo.isSyncDictionaryEnabled(), isFalse);
  });

  test('audiobook-files sync preference defaults false and round-trips',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    expect(await repo.isSyncAudioBookFilesEnabled(), isFalse);
    await repo.setSyncAudioBookFilesEnabled(true);
    expect(await repo.isSyncAudioBookFilesEnabled(), isTrue);
    await repo.setSyncAudioBookFilesEnabled(false);
    expect(await repo.isSyncAudioBookFilesEnabled(), isFalse);
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

    // ── TODO-961 M1: TOFU 指纹记录器 ────────────────────────────────────
    test('addHibikiClientUrl 新增 https 条目即带指纹与展示名（创建即钉扎）', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      final List<HibikiClientUrl> result = await repo.addHibikiClientUrl(
        'https://host:38765',
        fingerprint: 'aa:bb:cc',
        deviceName: 'Hibiki · mac',
      );

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc');
      expect(result.first.deviceName, 'Hibiki · mac');
      // 落盘后回读一致。
      final List<HibikiClientUrl> reread = await repo.getHibikiClientUrls();
      expect(reread.first.fingerprintSha256, 'aa:bb:cc');
    });

    test('addHibikiClientUrl 指纹相同时幂等（不变更，含大小写/冒号归一化）', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.addHibikiClientUrl('https://host:38765',
          fingerprint: 'aa:bb:cc');
      // 同一指纹换大小写 + 去冒号：归一化后相等，不应抛、不应改。
      final List<HibikiClientUrl> result = await repo
          .addHibikiClientUrl('https://host:38765', fingerprint: 'AABBCC');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc'); // 保留原存值。
    });

    test('addHibikiClientUrl 把明文老条目首次升级为 https 指纹（storedFp 空允许写入）', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setHibikiClientUrls(
          const <HibikiClientUrl>[HibikiClientUrl(url: 'https://host:38765')]);

      final List<HibikiClientUrl> result = await repo
          .addHibikiClientUrl('https://host:38765', fingerprint: 'aa:bb:cc');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc');
    });

    test(
        'addHibikiClientUrl 指纹变更必抛 HibikiFingerprintMismatchException 且不覆盖（MITM 守卫）',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.addHibikiClientUrl('https://host:38765',
          fingerprint: 'aa:bb:cc');

      // 同一 URL 再来一个 **不同** 指纹 → 拒绝并抛异常。
      expect(
        () => repo.addHibikiClientUrl('https://host:38765',
            fingerprint: 'de:ad:be'),
        throwsA(isA<HibikiFingerprintMismatchException>()),
      );

      // 已存指纹绝不被覆盖：仍是首记录值。
      final List<HibikiClientUrl> reread = await repo.getHibikiClientUrls();
      expect(reread, hasLength(1));
      expect(reread.first.fingerprintSha256, 'aa:bb:cc');
    });

    test('addHibikiClientUrl 明文 http（无指纹）路径保持向后兼容', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      final List<HibikiClientUrl> result =
          await repo.addHibikiClientUrl('http://lan:8765');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, isNull);
    });

    test('getServerTlsEnabled 默认 false，可持久化', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.getServerTlsEnabled(), isFalse);
      await repo.setServerTlsEnabled(true);
      expect(await repo.getServerTlsEnabled(), isTrue);
    });
  });

  group('audiobook position', () {
    test('round-trips through the typed accessor', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(
          await repo.getAudiobookPosition('book-7'), 0); // default when unset
      await repo.setAudiobookPosition('book-7', 1234);
      expect(await repo.getAudiobookPosition('book-7'), 1234);
    });

    test('uses the exact legacy key so old values read back identically',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // Value written by older code paths (raw key + typed int codec).
      await db.setPrefTyped<int>('audiobook_pos_book-7', 9);
      expect(await repo.getAudiobookPosition('book-7'), 9);

      // And the new setter writes to the same key the legacy readers use.
      await repo.setAudiobookPosition('book-7', 55);
      expect(await db.getPrefTyped<int>('audiobook_pos_book-7', 0), 55);
    });
  });

  group('device id', () {
    test('getOrCreateDeviceId is stable across calls', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      final first = await repo.getOrCreateDeviceId();
      expect(first, isNotEmpty);
      final second = await repo.getOrCreateDeviceId();
      expect(second, equals(first));
    });

    test('sync_device_id is in the device-local key catalog', () {
      expect(SyncRepository.deviceLocalPrefKeys, contains('sync_device_id'));
    });
  });

  group('device-local pref key catalog', () {
    test('includes backend selection, credentials and server config', () {
      const keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys, contains('sync_backend_type'));
      expect(keys, contains('sync_webdav_password'));
      expect(keys, contains('sync_sftp_private_key'));
      expect(keys, contains('sync_server_password'));
      expect(keys, contains('sync_hibiki_client_token'));
      expect(keys, contains('sync_hibiki_client_urls'));
    });

    test('excludes behavior flags, folder cache and per-book content', () {
      const keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys, isNot(contains('sync_auto_enabled')));
      expect(keys, isNot(contains('sync_stats_enabled')));
      expect(keys, isNot(contains('sync_audiobook_enabled')));
      expect(keys, isNot(contains('sync_dictionary_enabled')));
      expect(keys, isNot(contains('sync_content_enabled')));
      expect(keys, isNot(contains('sync_root_folder_id')));
      expect(keys, isNot(contains('sync_folder_cache')));
      expect(keys.where((String k) => k.startsWith('audiobook_pos_')), isEmpty);
    });

    test('carries no removed SMB keys', () {
      const keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys.where((String k) => k.startsWith('sync_smb_')), isEmpty);
    });
  });
}
