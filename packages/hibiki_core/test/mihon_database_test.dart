import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase database;

  setUp(() {
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('v63 stores Mihon identity and preferences without integer coercion',
      () async {
    expect(database.schemaVersion, 63);
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: 'https://repo.example/index.json',
        name: 'Fixture repository',
        format: 'currentJson',
        signingKey: const Value('aabb'),
      ),
    );
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.fixture',
        storeUrl: const Value('https://repo.example/index.json'),
        name: 'Fixture extension',
        versionCode: 4,
        versionName: '1.6.4',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.fixture.ext',
        apkSha256: 'deadbeef',
        signerSha256: 'aabb',
        installedAt: 123,
      ),
    );
    const String sourceId = '9223372036854775807';
    await database.replaceMangaOnlineSources(
      'org.example.fixture',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.fixture',
          sourceId: sourceId,
          name: 'Fixture source',
          language: 'en',
        ),
      ],
    );
    final MangaOnlineSourceRow initial =
        (await database.getMangaOnlineSources()).single;
    await database.updateMangaOnlineSourceSettings(
      extensionPackage: initial.extensionPackage,
      sourceId: initial.sourceId,
      pinned: true,
      sortOrder: 9,
    );
    await database.replaceMangaOnlineSources(
      'org.example.fixture',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.fixture',
          sourceId: sourceId,
          name: 'Renamed source',
          language: 'en',
        ),
      ],
    );
    await database.upsertMangaSourcePreference(
      MangaSourcePreferencesCompanion.insert(
        extensionPackage: 'org.example.fixture',
        sourceId: sourceId,
        preferenceKey: 'quality',
        preferenceType: 'singleChoice',
        valueJson: '"high"',
        updatedAt: 456,
      ),
    );
    await database.trustMangaSigner(
      MangaTrustedSignersCompanion.insert(
        fingerprint: 'aabb',
        label: 'Fixture signer',
        origin: 'local',
        trustedAt: 789,
      ),
    );

    final MangaOnlineSourceRow source =
        (await database.getMangaOnlineSources()).single;
    expect(source.sourceId, sourceId);
    expect(source.name, 'Renamed source');
    expect(source.pinned, isTrue);
    expect(source.sortOrder, 9);
    expect(
      (await database.getMangaSourcePreferences(
        'org.example.fixture',
        sourceId,
      ))
          .single
          .valueJson,
      '"high"',
    );
    expect(await database.isMangaSignerTrusted('aabb'), isTrue);
  });
}
