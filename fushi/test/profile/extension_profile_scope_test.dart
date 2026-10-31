import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/extension_profile_adapter.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import '../helpers/fake_anki_repository.dart';

/// 反馈 biLEesNqWb：浏览器扩展所选配置「只影响扩展」。
///
/// App 激活配置是 A、扩展选 B 时：扩展请求的词典集合 / 顺序 / 隐藏与 Anki 牌组 / 模板 /
/// 字段映射全部按 B 的只读视图；App 的激活配置、live 偏好、词典表与 Anki 设置保持 A
/// 不变。解析优先级：扩展所选 > 「浏览器」绑定 > 跟随 App；所选配置被删时回退并报 missing。
const String _scopedPref = 'test_extension_scope_pref';
const String _deviceLocalPref = 'app_locale';

class _NoopLookup implements FushiRemoteLookupService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 数解析依据的读库次数（激活配置 / 浏览器绑定 / 配置列表）。
class _CountingProfileRepository extends ProfileRepository {
  _CountingProfileRepository(super.db, super.anki);

  int activeReads = 0;
  int bindingReads = 0;
  int profileListReads = 0;

  @override
  Future<int> getActiveProfileId() {
    activeReads++;
    return super.getActiveProfileId();
  }

  @override
  Future<int?> resolveBoundProfileId({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) {
    bindingReads++;
    return super.resolveBoundProfileId(
      bookUid: bookUid,
      languageTag: languageTag,
      mediaType: mediaType,
    );
  }

  @override
  Future<List<ProfileRow>> getAllProfiles() {
    profileListReads++;
    return super.getAllProfiles();
  }
}

void main() {
  late FushiDatabase db;
  late FakeAnkiRepository anki;
  late ProfileRepository repo;
  late int profileA;
  late int profileB;
  late List<ProfileSettingsView> builtViews;
  late AppExtensionProfileApi api;

  Future<void> seedDict(String name, int order, List<String> hidden) =>
      db.upsertDictionaryMeta(
        DictionaryMetadataCompanion(
          name: Value(name),
          formatKey: const Value('yomitan'),
          order: Value(order),
          type: const Value('term'),
          metadataJson: const Value('{}'),
          hiddenLanguagesJson: Value(jsonEncode(hidden)),
          collapsedLanguagesJson: const Value('[]'),
        ),
      );

  Future<void> setLive({
    required int dictAOrder,
    required int dictBOrder,
    required List<String> dictAHidden,
    required String deck,
    required Map<String, String> fields,
    required String pref,
  }) async {
    await seedDict('DictA', dictAOrder, dictAHidden);
    await seedDict('DictB', dictBOrder, const <String>[]);
    await anki.saveSettings(
      AnkiSettings(
        selectedDeckName: deck,
        selectedNoteTypeName: 'Note-$deck',
        fieldMappings: fields,
      ),
    );
    await db.setPref(_scopedPref, pref);
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    anki = FakeAnkiRepository();
    repo = ProfileRepository(db, anki);
    await repo.ensureDefaultProfile();
    profileA = await repo.getActiveProfileId();
    profileB = await repo.createProfile('B');

    // B：DictB 在前、DictA 对日语隐藏，牌组 DeckB。快照完再把 live 设回 A。
    await setLive(
      dictAOrder: 1,
      dictBOrder: 0,
      dictAHidden: const <String>['ja'],
      deck: 'DeckB',
      fields: const <String, String>{'Front': 'reading'},
      pref: 'B-value',
    );
    await repo.snapshotCurrentSettings(profileB);
    await setLive(
      dictAOrder: 0,
      dictBOrder: 1,
      dictAHidden: const <String>[],
      deck: 'DeckA',
      fields: const <String, String>{'Front': 'expression'},
      pref: 'A-value',
    );
    await db.setPref(_deviceLocalPref, 'zh-CN');

    builtViews = <ProfileSettingsView>[];
    api = AppExtensionProfileApi(
      repository: () => repo,
      database: () => db,
      servicesForView: (ProfileSettingsView view) {
        builtViews.add(view);
        return ExtensionRequestServices(lookup: _NoopLookup());
      },
    );
  });

  tearDown(() async {
    await api.dispose();
    await db.close();
  });

  Future<
    ({
      Map<String, String> prefs,
      List<DictionaryMetaRow> dicts,
      String anki,
      int active,
    })
  >
  appState() async => (
    prefs: await db.getAllPrefs(),
    dicts: await db.getAllDictionaryMetadata(),
    anki: jsonEncode((await anki.loadSettings()).toJson()),
    active: await repo.getActiveProfileId(),
  );

  void expectAppUnchanged(
    ({
      Map<String, String> prefs,
      List<DictionaryMetaRow> dicts,
      String anki,
      int active,
    })
    before,
    ({
      Map<String, String> prefs,
      List<DictionaryMetaRow> dicts,
      String anki,
      int active,
    })
    after,
  ) {
    expect(after.active, profileA, reason: 'App 的激活配置必须保持 A');
    expect(after.prefs, before.prefs, reason: 'live 偏好不得被扩展请求改写');
    expect(after.dicts, before.dicts, reason: '词典表不得被扩展请求改写');
    expect(after.anki, before.anki, reason: 'Anki 设置不得被扩展请求改写');
  }

  test('A 激活、扩展选 B：视图按 B，App 状态逐字段不变', () async {
    final before = await appState();

    final ExtensionProfileScope scope = await api.resolveScope(profileB);
    expect(scope.effectiveProfileId, profileB);
    expect(scope.missingRequestedProfileId, isNull);
    expect(scope.services, isNotNull);
    expect(builtViews, hasLength(1));
    final ProfileSettingsView view = builtViews.single;

    // 词典集合 / 顺序 / 隐藏按 B。
    expect(view.dictionaries.map((d) => d.name).toList(), <String>[
      'DictB',
      'DictA',
    ]);
    expect(view.lookupFilters.termDictionaryOrder, <String>['DictB', 'DictA']);
    expect(view.lookupFilters.hiddenDictionaryNames, <String>{'DictA'});
    // 制卡目标牌组 / 模板 / 字段按 B（视图给 Anki 仓库的设置存储也读出 B）。
    expect(view.ankiSettings.selectedDeckName, 'DeckB');
    expect(view.ankiSettings.selectedNoteTypeName, 'Note-DeckB');
    expect(view.ankiSettings.fieldMappings, <String, String>{
      'Front': 'reading',
    });
    final AnkiSettings fromStore = AnkiSettings.fromJson(
      jsonDecode((await view.ankiSettingsStore.read())!)
          as Map<String, dynamic>,
    );
    expect(fromStore.selectedDeckName, 'DeckB');
    // 偏好：配置项取 B 的快照，设备本地项取 live。
    expect(view.prefsMap[_scopedPref], 'B-value');
    expect(view.prefsMap[_deviceLocalPref], 'zh-CN');
    // 查词缓存按配置分区。
    expect(view.lookupCacheNamespace, startsWith('xprofile:$profileB:'));

    expectAppUnchanged(before, await appState());
  });

  test('视图只读：偏好 / Anki 设置写不回 App', () async {
    await api.resolveScope(profileB);
    final ProfileSettingsView view = builtViews.single;
    expect(
      () => view.prefs.setPref(_scopedPref, 'mutated'),
      throwsUnsupportedError,
    );
    await view.ankiSettingsStore.write('{"selectedDeckName":"Other"}');
    expect((await anki.loadSettings()).selectedDeckName, 'DeckA');
    expect(await db.getPref(_scopedPref), 'A-value');
  });

  test('不带选择、无浏览器绑定：跟随 App，用默认服务组', () async {
    final ExtensionProfileScope scope = await api.resolveScope(null);
    expect(scope.effectiveProfileId, profileA);
    expect(scope.services, isNull);
    expect(builtViews, isEmpty);
  });

  test('选的就是激活配置：用 App 的 live 设置（快照比 live 旧）', () async {
    final ExtensionProfileScope scope = await api.resolveScope(profileA);
    expect(scope.effectiveProfileId, profileA);
    expect(scope.services, isNull);
    expect(builtViews, isEmpty);
  });

  test('优先级：扩展所选 > 浏览器绑定 > 跟随 App，且都不切 App', () async {
    await repo.setMediaTypeBinding(ProfileMediaKind.browser, profileB);
    final before = await appState();

    final ExtensionProfileScope bound = await api.resolveScope(null);
    expect(bound.effectiveProfileId, profileB);
    expect(bound.services, isNotNull);

    final ExtensionProfileScope manual = await api.resolveScope(profileA);
    expect(manual.effectiveProfileId, profileA);
    expect(manual.services, isNull);

    expectAppUnchanged(before, await appState());
  });

  test('所选配置被删：回退跟随 App 并报 missing', () async {
    await repo.deleteProfile(profileB);
    final ExtensionProfileScope scope = await api.resolveScope(profileB);
    expect(scope.effectiveProfileId, profileA);
    expect(scope.missingRequestedProfileId, profileB);
    expect(scope.services, isNull);
  });

  test('视图按配置缓存，相关表一有写入即重建', () async {
    await api.resolveScope(profileB);
    await api.resolveScope(profileB);
    expect(builtViews, hasLength(1), reason: '稳态 hover 查词复用同一份视图');

    // B 的快照被改（例如用户在 App 里切到 B 改了设置再切走）→ 下一次请求看到新值。
    await db.setPref(_scopedPref, 'B-updated');
    await repo.snapshotCurrentSettings(profileB);
    await db.setPref(_scopedPref, 'A-value');
    await pumpEventQueue();

    await api.resolveScope(profileB);
    expect(builtViews, hasLength(2));
    expect(builtViews.last.prefsMap[_scopedPref], 'B-updated');
  });

  test('App 激活配置的设置写入不重建别的配置的视图；设备本地键变了才重建', () async {
    await api.resolveScope(profileB);
    expect(builtViews, hasLength(1));

    // A（激活）改设置：只写 live preferences，B 的视图只从快照读这个键 → 不重建。
    await db.setPref(_scopedPref, 'A-edited');
    await db.setPref(_scopedPref, 'A-edited-again');
    await pumpEventQueue();
    await api.resolveScope(profileB);
    await api.resolveScope(profileB);
    expect(builtViews, hasLength(1), reason: '与 B 无关的偏好写入不该让 hover 查词重建快照');
    expect(builtViews.single.prefsMap[_scopedPref], 'B-value');

    // 设备本地键（视图从 live 表读）真变了 → 重建，新视图看到新值。
    await db.setPref(_deviceLocalPref, 'ja');
    await pumpEventQueue();
    await api.resolveScope(profileB);
    expect(builtViews, hasLength(2));
    expect(builtViews.last.prefsMap[_deviceLocalPref], 'ja');

    // 写回同一个值（只跳了 prefs_version）→ 不重建。
    await db.setPref(_deviceLocalPref, 'ja');
    await pumpEventQueue();
    await api.resolveScope(profileB);
    expect(builtViews, hasLength(2));
  });

  test('解析依据缓存：稳态 hover 不再查库；切激活配置 / 改绑定 / 删配置后下一次请求看到新值', () async {
    final _CountingProfileRepository counting = _CountingProfileRepository(
      db,
      anki,
    );
    final AppExtensionProfileApi scoped = AppExtensionProfileApi(
      repository: () => counting,
      database: () => db,
      servicesForView: (ProfileSettingsView view) =>
          ExtensionRequestServices(lookup: _NoopLookup()),
    );
    addTearDown(scoped.dispose);

    for (int i = 0; i < 5; i++) {
      expect((await scoped.resolveScope(null)).effectiveProfileId, profileA);
      expect((await scoped.resolveScope(profileA)).services, isNull);
    }
    expect(counting.activeReads, 1, reason: '默认路径每次请求都查库太重');
    expect(counting.bindingReads, 1);
    expect(counting.profileListReads, 1);

    // App 切到 B（active_profile_id 在 preferences 里）。
    await counting.setActiveProfileId(profileB);
    await pumpEventQueue();
    expect((await scoped.resolveScope(null)).effectiveProfileId, profileB);
    expect(counting.activeReads, 2);
    await counting.setActiveProfileId(profileA);
    await pumpEventQueue();

    // 改「浏览器」绑定。
    await counting.setMediaTypeBinding(ProfileMediaKind.browser, profileB);
    await pumpEventQueue();
    final ExtensionProfileScope bound = await scoped.resolveScope(null);
    expect(bound.effectiveProfileId, profileB);
    expect(bound.services, isNotNull);

    // 删掉所选配置。
    await counting.deleteProfile(profileB);
    await pumpEventQueue();
    final ExtensionProfileScope gone = await scoped.resolveScope(profileB);
    expect(gone.effectiveProfileId, profileA);
    expect(gone.missingRequestedProfileId, profileB);
  });
}
