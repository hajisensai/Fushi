import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  test('sync preferences use typed pref codec and read legacy raw values',
      () async {
    final FushiDatabase db = _testDb();
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
    final FushiDatabase db = _testDb();
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
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    expect(await repo.isSyncAudioBookFilesEnabled(), isFalse);
    await repo.setSyncAudioBookFilesEnabled(true);
    expect(await repo.isSyncAudioBookFilesEnabled(), isTrue);
    await repo.setSyncAudioBookFilesEnabled(false);
    expect(await repo.isSyncAudioBookFilesEnabled(), isFalse);
  });

  test('auto sync preference defaults to false', () async {
    final FushiDatabase db = _testDb();
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
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://192.168.1.5:8765'),
        FushiClientUrl(url: 'http://home.ddns.net:8765', enabled: false),
      ]);

      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls.map((FushiClientUrl u) => u.url).toList(),
          <String>['http://192.168.1.5:8765', 'http://home.ddns.net:8765']);
      expect(urls.map((FushiClientUrl u) => u.enabled).toList(),
          <bool>[true, false]);
    });

    test('migrates legacy single url into a one-element enabled list',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // Simulate data left by an older app version: only the legacy
      // single-url key is set (no new list key).
      await db.setPref('sync_hibiki_client_url', 'http://192.168.1.5:8765');

      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls, hasLength(1));
      expect(urls.first.url, 'http://192.168.1.5:8765');
      expect(urls.first.enabled, isTrue);
    });

    test('returns empty list when nothing is configured', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.getFushiClientUrls(), isEmpty);
    });

    test('new list takes precedence over the legacy single url', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_hibiki_client_url', 'http://legacy.example:8765');
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://new.example:8765'),
      ]);

      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls, hasLength(1));
      expect(urls.first.url, 'http://new.example:8765');
    });

    test('addFushiClientUrl appends a new url, keeping order and token',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setFushiClientUrls(
          const <FushiClientUrl>[FushiClientUrl(url: 'http://lan:8765')]);
      await repo.setFushiClientToken('tok');

      final List<FushiClientUrl> result =
          await repo.addFushiClientUrl('http://wan:8765');

      expect(result.map((FushiClientUrl u) => u.url).toList(),
          <String>['http://lan:8765', 'http://wan:8765']);
      expect(await repo.getFushiClientToken(), 'tok'); // token untouched
    });

    test('addFushiClientUrl does not add a duplicate', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setFushiClientUrls(
          const <FushiClientUrl>[FushiClientUrl(url: 'http://lan:8765')]);

      final List<FushiClientUrl> result =
          await repo.addFushiClientUrl('http://lan:8765');

      expect(result, hasLength(1));
      expect(await repo.getFushiClientUrls(), hasLength(1));
    });

    // ── TODO-961 M1: TOFU 指纹记录器 ────────────────────────────────────
    test('addFushiClientUrl 新增 https 条目即带指纹与展示名（创建即钉扎）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      final List<FushiClientUrl> result = await repo.addFushiClientUrl(
        'https://host:38765',
        fingerprint: 'aa:bb:cc',
        deviceName: 'Hibiki · mac',
      );

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc');
      expect(result.first.deviceName, 'Hibiki · mac');
      // 落盘后回读一致。
      final List<FushiClientUrl> reread = await repo.getFushiClientUrls();
      expect(reread.first.fingerprintSha256, 'aa:bb:cc');
    });

    test('addFushiClientUrl 指纹相同时幂等（不变更，含大小写/冒号归一化）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.addFushiClientUrl('https://host:38765',
          fingerprint: 'aa:bb:cc');
      // 同一指纹换大小写 + 去冒号：归一化后相等，不应抛、不应改。
      final List<FushiClientUrl> result = await repo
          .addFushiClientUrl('https://host:38765', fingerprint: 'AABBCC');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc'); // 保留原存值。
    });

    test('addFushiClientUrl 把明文老条目首次升级为 https 指纹（storedFp 空允许写入）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setFushiClientUrls(
          const <FushiClientUrl>[FushiClientUrl(url: 'https://host:38765')]);

      final List<FushiClientUrl> result = await repo
          .addFushiClientUrl('https://host:38765', fingerprint: 'aa:bb:cc');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, 'aa:bb:cc');
    });

    test(
        'addFushiClientUrl 指纹变更必抛 FushiFingerprintMismatchException 且不覆盖（MITM 守卫）',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.addFushiClientUrl('https://host:38765',
          fingerprint: 'aa:bb:cc');

      // 同一 URL 再来一个 **不同** 指纹 → 拒绝并抛异常。
      expect(
        () => repo.addFushiClientUrl('https://host:38765',
            fingerprint: 'de:ad:be'),
        throwsA(isA<FushiFingerprintMismatchException>()),
      );

      // 已存指纹绝不被覆盖：仍是首记录值。
      final List<FushiClientUrl> reread = await repo.getFushiClientUrls();
      expect(reread, hasLength(1));
      expect(reread.first.fingerprintSha256, 'aa:bb:cc');
    });

    test('addFushiClientUrl 明文 http（无指纹）路径保持向后兼容', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      final List<FushiClientUrl> result =
          await repo.addFushiClientUrl('http://lan:8765');

      expect(result, hasLength(1));
      expect(result.first.fingerprintSha256, isNull);
    });

    test('getServerTlsEnabled 默认 false，可持久化', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.getServerTlsEnabled(), isFalse);
      await repo.setServerTlsEnabled(true);
      expect(await repo.getServerTlsEnabled(), isTrue);
    });

    // TODO-961 B 段：首次启用 hosting 默认开 TLS——判据是两个偏好 key 都从未写入。
    test('applyFirstHostingTlsDefault 全新设备首次 hosting 默认开 TLS', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.applyFirstHostingTlsDefault(), isTrue);
      expect(await repo.getServerTlsEnabled(), isTrue);
      // 幂等：已写入 TLS key 后再调是 no-op。
      expect(await repo.applyFirstHostingTlsDefault(), isFalse);
    });

    test('applyFirstHostingTlsDefault 对存量 hosting 用户零破坏（不翻开 TLS）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 存量用户：serverEnabled 写过（无论 true/false）→ 不动 TLS。
      await repo.setServerEnabled(true);
      expect(await repo.applyFirstHostingTlsDefault(), isFalse);
      expect(await repo.getServerTlsEnabled(), isFalse);
    });

    test('applyFirstHostingTlsDefault 不覆盖显式关掉的 TLS', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setServerTlsEnabled(false); // 用户显式选择明文。
      expect(await repo.applyFirstHostingTlsDefault(), isFalse);
      expect(await repo.getServerTlsEnabled(), isFalse);
    });
  });

  group('audiobook position', () {
    test('round-trips through the typed accessor', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(
          await repo.getAudiobookPosition('book-7'), 0); // default when unset
      await repo.setAudiobookPosition('book-7', 1234);
      expect(await repo.getAudiobookPosition('book-7'), 1234);
    });

    test('uses the exact legacy key so old values read back identically',
        () async {
      final FushiDatabase db = _testDb();
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
      final FushiDatabase db = _testDb();
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
      final List<String> keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys, contains('sync_backend_type'));
      expect(keys, contains('sync_webdav_password'));
      expect(keys, contains('sync_sftp_private_key'));
      expect(keys, contains('sync_server_password'));
      expect(keys, contains('sync_hibiki_client_token'));
      expect(keys, contains('sync_hibiki_client_urls'));
    });

    test('excludes behavior flags, folder cache and per-book content', () {
      final List<String> keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys, isNot(contains('sync_auto_enabled')));
      expect(keys, isNot(contains('sync_stats_enabled')));
      expect(keys, isNot(contains('sync_audiobook_enabled')));
      expect(keys, isNot(contains('sync_dictionary_enabled')));
      expect(keys, isNot(contains('sync_content_enabled')));
      expect(keys, isNot(contains('sync_root_folder_id')));
      expect(keys, isNot(contains('sync_folder_cache')));
      // 分槽后同理：folder 缓存的任何一格都不该跟着备份跨设备（BUG-1576）。
      expect(keys.where((String k) => k.startsWith('sync_root_folder_id')),
          isEmpty);
      expect(
          keys.where((String k) => k.startsWith('sync_folder_cache')), isEmpty);
      expect(keys.where((String k) => k.startsWith('audiobook_pos_')), isEmpty);
    });

    test('carries no removed SMB keys', () {
      final List<String> keys = SyncRepository.deviceLocalPrefKeys;
      expect(keys.where((String k) => k.startsWith('sync_smb_')), isEmpty);
    });
  });
}
