import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/profile/profile_document.dart'
    show kProfileSettingCategoryRemoteDictionaryMeta;

import '../helpers/fake_anki_repository.dart';

/// v149：服务器托管词典的顺序 / 开关属于配置（`remote_dictionary_meta` 类别）。
///
/// 与 `dictionary_meta` 同一次快照、同一个应用事务；应用只改已有目录行、从不插行
/// （目录只由刷新建立）；只读配置视图把快照里的列合成进词典过滤与缓存指纹；分享
/// JSON 原样携带、导入原样保留。
void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late int profileA;
  late int profileB;

  Future<void> catalog(String host, String name, int order) =>
      db.upsertRemoteDictionaryCatalog(
        RemoteDictionaryMetadataCompanion(
          hostId: Value<String>(host),
          name: Value<String>(name),
          type: const Value<String>('term'),
          lastSeenAt: const Value<int>(1),
          order: Value<int>(order),
        ),
      );

  Future<Map<String, RemoteDictionaryMetaRow>> rows() async =>
      <String, RemoteDictionaryMetaRow>{
        for (final RemoteDictionaryMetaRow r
            in await db.getAllRemoteDictionaryMetadata())
          '${r.hostId}/${r.name}': r,
      };

  Future<void> setLive(String host, String name, int order, bool hidden) =>
      db.setRemoteDictionaryProfileColumns(
        hostId: host,
        name: name,
        order: order,
        hidden: hidden,
      );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    await repo.ensureDefaultProfile();
    profileA = await repo.getActiveProfileId();
    profileB = await repo.createProfile('B');
    // 老 host（没有 hostId）用地址充当身份：带 `/`，快照 key 按最后一个 `/` 切。
    await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://h1:1', hostId: 'h1'),
      FushiClientUrl(url: 'http://old-host:8765'),
    ]);
    await catalog('h1', 'Daijirin', 0);
    await catalog('h1', 'Meikyo', 1);
    await catalog('http://old-host:8765', 'Kojien', 2);
  });

  tearDown(() => db.close());

  test('快照带上服务器词典的配置列，应用时写回已有目录行', () async {
    // B：大辞林关、明镜排第一；老 host 的广辞苑关。
    await setLive('h1', 'Daijirin', 5, true);
    await setLive('h1', 'Meikyo', 0, false);
    await setLive('http://old-host:8765', 'Kojien', 2, true);
    await repo.snapshotCurrentSettings(profileB);
    final List<ProfileSettingRow> snapshot = await db.getProfileSettings(
      profileB,
    );
    final Map<String, String> remote = <String, String>{
      for (final ProfileSettingRow r in snapshot)
        if (r.category == ProfileKeys.categoryRemoteDictionaryMeta)
          r.key: r.value,
    };
    expect(remote.keys, <String>{
      'h1/Daijirin',
      'h1/Meikyo',
      'http://old-host:8765/Kojien',
    });
    expect(jsonDecode(remote['h1/Daijirin']!), <String, Object>{
      'order': 5,
      'hidden': true,
    });

    // 回到 A 的设置（全开、原顺序），再切到 B。
    await setLive('h1', 'Daijirin', 0, false);
    await setLive('h1', 'Meikyo', 1, false);
    await setLive('http://old-host:8765', 'Kojien', 2, false);
    await repo.snapshotCurrentSettings(profileA);
    await repo.applyProfile(profileB);
    Map<String, RemoteDictionaryMetaRow> live = await rows();
    expect(live['h1/Daijirin']!.hidden, isTrue);
    expect(live['h1/Daijirin']!.order, 5);
    expect(live['h1/Meikyo']!.order, 0);
    expect(live['http://old-host:8765/Kojien']!.hidden, isTrue);

    await repo.applyProfile(profileA);
    live = await rows();
    expect(live['h1/Daijirin']!.hidden, isFalse);
    expect(live['h1/Daijirin']!.order, 0);
    expect(live['http://old-host:8765/Kojien']!.hidden, isFalse);
  });

  test('应用不插目录行：快照里有、本机目录里没有的服务器词典跳过', () async {
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: profileB,
        category: ProfileKeys.categoryRemoteDictionaryMeta,
        key: 'h9/Ghost',
        value: jsonEncode(<String, Object>{'order': 0, 'hidden': true}),
      ),
    );
    await repo.applyProfile(profileB);
    expect((await rows()).keys, isNot(contains('h9/Ghost')));
    expect(await rows(), hasLength(3));
  });

  test('坏行跳过，不中断整次应用', () async {
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: profileB,
        category: ProfileKeys.categoryRemoteDictionaryMeta,
        key: 'no-slash',
        value: '{"order":1,"hidden":true}',
      ),
    );
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: profileB,
        category: ProfileKeys.categoryRemoteDictionaryMeta,
        key: 'h1/Meikyo',
        value: 'not json',
      ),
    );
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: profileB,
        category: ProfileKeys.categoryRemoteDictionaryMeta,
        key: 'h1/Daijirin',
        value: '{"order":9,"hidden":true}',
      ),
    );
    await repo.applyProfile(profileB);
    final Map<String, RemoteDictionaryMetaRow> live = await rows();
    expect(live['h1/Daijirin']!.order, 9);
    expect(live['h1/Meikyo']!.order, 1, reason: '坏 value 那行保持 live 值');
  });

  test('只读视图合成快照列：过滤、按 host 的选择、缓存指纹都跟着配置走', () async {
    await setLive('h1', 'Daijirin', 5, true);
    await repo.snapshotCurrentSettings(profileB);
    await setLive('h1', 'Daijirin', 0, false);

    final ProfileSettingsView viewB = (await repo.loadSettingsView(profileB))!;
    expect(
      viewB.remoteDictionaries.map((r) => '${r.hostId}/${r.name}'),
      <String>['h1/Meikyo', 'http://old-host:8765/Kojien', 'h1/Daijirin'],
    );
    expect(viewB.lookupFilters.hiddenDictionaryNames, contains('Daijirin'));
    expect(viewB.filtersForHost('h1')!.excluded, <String>{'Daijirin'});
    expect(viewB.filtersForHost('h1')!.order, <String>['Meikyo', 'Daijirin']);

    // live 没被视图改动。
    expect((await rows())['h1/Daijirin']!.hidden, isFalse);

    // 同一配置的服务器词典设置变了 → 缓存命名空间跟着变。
    await setLive('h1', 'Daijirin', 0, false);
    await repo.snapshotCurrentSettings(profileB);
    final ProfileSettingsView viewB2 = (await repo.loadSettingsView(profileB))!;
    expect(viewB2.lookupCacheNamespace, isNot(viewB.lookupCacheNamespace));
  });

  test('视图只合成参与查词的 host（关掉「用它查词典」的 host 不进来）', () async {
    await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://h1:1', hostId: 'h1', lookupEnabled: false),
      FushiClientUrl(url: 'http://old-host:8765'),
    ]);
    final ProfileSettingsView view = (await repo.loadSettingsView(profileA))!;
    expect(
      view.remoteDictionaries.map((r) => '${r.hostId}/${r.name}'),
      <String>['http://old-host:8765/Kojien'],
    );
  });

  test('分享 JSON 带上该类别，导入原样保留', () async {
    await setLive('h1', 'Daijirin', 4, true);
    await repo.snapshotCurrentSettings(profileB);
    final String json = await repo.exportProfileToJson(profileB);
    final List<Object?> settings =
        (jsonDecode(json) as Map<String, Object?>)['settings']!
            as List<Object?>;
    expect(
      settings.whereType<Map<String, Object?>>().where(
        (Map<String, Object?> e) =>
            e['category'] == kProfileSettingCategoryRemoteDictionaryMeta &&
            e['key'] == 'h1/Daijirin',
      ),
      hasLength(1),
    );

    final int imported = await repo.importProfileFromJson(json);
    final List<ProfileSettingRow> importedRows = await db.getProfileSettings(
      imported,
    );
    expect(
      importedRows
          .where(
            (ProfileSettingRow r) =>
                r.category == ProfileKeys.categoryRemoteDictionaryMeta,
          )
          .map((ProfileSettingRow r) => r.key)
          .toSet(),
      <String>{'h1/Daijirin', 'h1/Meikyo', 'http://old-host:8765/Kojien'},
    );
  });
}
