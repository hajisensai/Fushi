import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase database;

  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('v65 stores Mihon identity and preferences without integer coercion',
      () async {
    // 本用例的契约是「Mihon 五张表按声明类型存取、不做整数强转」，前提只有
    // 一条：这五张表已经进入 schema，即当前版本 >= 引入它们的 v65。
    //
    // 这里刻意**不写等值断言**。等值断言把一个与本用例无关的全局常量钉死在
    // 这里，每次 schema bump 都要跟着改：本行历史上已被动改过 63 -> 64 -> 65，
    // 第四次（65 -> 66，PR#663 的 collection_relations / episode_number）漏改
    // 直接把 develop 的 CI `Run package tests` 打红——因为本仓约定的本地全量
    // 门只跑 `hibiki/` 那套，`packages/` 下的字面量拿不到同一次批量替换。
    // 「当前 schema 恰好是第几版」的等值守卫属于迁移阶梯测试
    // （`fushi/test/database/migration_*.dart`），不属于这里。
    expect(database.schemaVersion, greaterThanOrEqualTo(65),
        reason: 'v65 = Mihon 漫画扩展生态五张表；低于此版本本用例的表还不存在');
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
