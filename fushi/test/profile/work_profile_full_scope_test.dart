import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_anki_settings_store.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';

/// 内存里的 live Anki 设置存储（代替本 isolate 装配的 Drift 存储）。
class _MemoryAnkiStore implements AnkiSettingsStore {
  _MemoryAnkiStore(AnkiSettings initial) : json = jsonEncode(initial.toJson());

  String? json;

  AnkiSettings get settings =>
      AnkiSettings.fromJson(jsonDecode(json!) as Map<String, dynamic>);

  @override
  Future<String?> read() async => json;

  @override
  Future<void> write(String value) async {
    json = value;
  }
}

/// 反馈 kEFPY4cuKZ 补齐：作品级配置会话除了阅读样式 / 悬浮字幕样式 / 查词，还要覆盖
/// Anki 牌组、复习制卡目标、主题、视频字幕样式与字体；退出会话恢复全局；Android 弹窗进程
/// 经主进程发布的会话镜像同一份作品配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late int defaultId;
  late int boundId;
  final WorkProfileScope scope = WorkProfileScope.instance;
  final Object reader = Object();

  Future<void> putSnapshot(
    int profileId,
    String category,
    String key,
    String value,
  ) => db.upsertProfileSetting(
    ProfileSettingsCompanion.insert(
      profileId: profileId,
      category: category,
      key: key,
      value: value,
    ),
  );

  Future<String?> snapshotValue(
    int profileId,
    String category,
    String key,
  ) async {
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId)) {
      if (r.category == category && r.key == key) return r.value;
    }
    return null;
  }

  setUp(() async {
    scope.debugReset();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    vm = ProfileViewModel(repo, () async {}, ProfileDraftCoordinator());
    final ProfileUiState loaded = await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    defaultId = loaded.activeProfileId;
    boundId = await repo.createProfile('bound');
    await repo.setBookProfile('book-bound', boundId);
  });

  tearDown(() async {
    scope.debugReset();
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  Future<void> openBook() => vm.enterWorkSession(
    owner: reader,
    bookUid: 'book-bound',
    mediaType: ProfileMediaKind.epub,
  );

  test('作品级键覆盖主题 / 视频字幕样式 / 复习制卡目标 / 字体，设备本地键不进', () {
    for (final String key in <String>[
      'app_theme_key',
      'brightness_mode',
      'design_system',
      'custom_themes',
      'custom_theme_seed',
      'page_backdrop_preset',
      'video_subtitle_style',
      'video_respect_ass_style',
      'srs_mining_target',
      'srs_mining_deck_id',
      'srs_mining_note_type_id',
      'srs_mining_field_mappings',
      'src:reader_fushi:font_catalog',
      'src:reader_fushi:font_targets',
      'src:reader_fushi:app_ui_fonts',
      'src:reader_fushi:video_sub_fonts',
    ]) {
      expect(WorkProfileScope.isWorkScopedPrefKey(key), isTrue, reason: key);
    }
    for (final String key in <String>[
      kFloatingLyricWindowRectPrefKey,
      'page_backdrop_image',
      'theme_app_icon_seed_cache',
      'eink_mode',
      'app_ui_scale',
      kAnkiSettingsPrefKey,
      kWorkProfileSessionPrefKey,
      'active_profile_id',
    ]) {
      expect(WorkProfileScope.isWorkScopedPrefKey(key), isFalse, reason: key);
    }
  });

  test('主题：会话内按作品配置读、写进作品配置快照，离开后读回全局', () async {
    await db.setPref('design_system', PrefCodec.encode('material'));
    await putSnapshot(
      boundId,
      ProfileKeys.categoryPref,
      'design_system',
      PrefCodec.encode('glass'),
    );
    final ThemeNotifier theme = ThemeNotifier(db, () => const TextTheme());
    await theme.refreshFromDb();
    expect(theme.designSystem, 'material');

    await openBook();
    theme.onWorkProfileScopeChanged();
    expect(theme.designSystem, 'glass', reason: '进书主题跟作品配置');

    await theme.setDesignSystem('auto');
    expect(theme.designSystem, 'auto');
    expect(
      await snapshotValue(boundId, ProfileKeys.categoryPref, 'design_system'),
      PrefCodec.encode('auto'),
    );
    expect(
      await db.getPref('design_system'),
      PrefCodec.encode('material'),
      reason: '全局主题不动',
    );

    vm.leaveWorkSession(reader);
    expect(theme.designSystem, 'material', reason: '退出会话恢复全局');
    theme.dispose();
  });

  test('视频字幕样式与复习制卡目标：会话内读作品配置，离开读回全局', () async {
    await db.setPref('video_subtitle_style', PrefCodec.encode('{"g":1}'));
    await db.setPref('srs_mining_deck_id', PrefCodec.encode('global-deck'));
    await putSnapshot(
      boundId,
      ProfileKeys.categoryPref,
      'video_subtitle_style',
      PrefCodec.encode('{"b":1}'),
    );
    await putSnapshot(
      boundId,
      ProfileKeys.categoryPref,
      'srs_mining_deck_id',
      PrefCodec.encode('bound-deck'),
    );
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    await openBook();
    expect(prefs.videoSubtitleStyle, '{"b":1}');
    expect(prefs.srsMiningDeckId, 'bound-deck');
    await prefs.setSrsMiningDeckId('bound-deck-2');
    expect(
      await snapshotValue(
        boundId,
        ProfileKeys.categoryPref,
        'srs_mining_deck_id',
      ),
      PrefCodec.encode('bound-deck-2'),
    );
    expect(
      await db.getPref('srs_mining_deck_id'),
      PrefCodec.encode('global-deck'),
    );

    vm.leaveWorkSession(reader);
    expect(prefs.videoSubtitleStyle, '{"g":1}');
    expect(prefs.srsMiningDeckId, 'global-deck');
  });

  test('字体：会话内改字体表写进作品配置快照，全局字体不动', () async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setFontsForTarget(FontTarget.appUi, <Map<String, dynamic>>[
      <String, dynamic>{'name': 'GlobalFont', 'enabled': true},
    ]);
    final String? globalTargets = await db.getPref(
      'src:reader_fushi:font_targets',
    );
    expect(globalTargets, isNotNull);

    await openBook();
    await settings.refreshFromDb();
    await settings.setFontsForTarget(FontTarget.appUi, <Map<String, dynamic>>[
      <String, dynamic>{'name': 'BookFont', 'enabled': true},
    ]);
    expect(settings.appUiFonts.single['name'], 'BookFont');
    expect(
      await db.getPref('src:reader_fushi:font_targets'),
      globalTargets,
      reason: '会话内改字体不写全局',
    );
    expect(
      await snapshotValue(
        boundId,
        ProfileKeys.categoryPref,
        'src:reader_fushi:font_targets',
      ),
      isNotNull,
    );

    vm.leaveWorkSession(reader);
    await settings.refreshFromDb();
    expect(settings.appUiFonts.single['name'], 'GlobalFont', reason: '退出恢复全局');
  });

  test('Anki：会话内制卡用作品配置的牌组，改牌组写进作品配置，设备本地字段写 live', () async {
    final _MemoryAnkiStore live = _MemoryAnkiStore(
      const AnkiSettings(
        selectedDeckId: 1,
        selectedDeckName: 'Global',
        ankiConnectApiKey: 'k1',
      ),
    );
    final WorkScopedAnkiSettingsStore store = WorkScopedAnkiSettingsStore(
      live: () => live,
    );
    await putSnapshot(boundId, ProfileKeys.categoryAnki, 'selectedDeckId', '2');
    await putSnapshot(
      boundId,
      ProfileKeys.categoryAnki,
      'selectedDeckName',
      'Bound',
    );

    AnkiSettings decode(String? raw) =>
        AnkiSettings.fromJson(jsonDecode(raw!) as Map<String, dynamic>);

    expect(decode(await store.read()).selectedDeckName, 'Global');
    await openBook();
    final AnkiSettings inBook = decode(await store.read());
    expect(inBook.selectedDeckName, 'Bound', reason: '进书制卡落作品配置的牌组');
    expect(inBook.ankiConnectApiKey, 'k1', reason: '设备本地字段照旧 live');

    await store.write(
      jsonEncode(
        inBook
            .copyWith(
              selectedDeckId: 3,
              selectedDeckName: 'Bound2',
              ankiConnectApiKey: 'k2',
            )
            .toJson(),
      ),
    );
    expect(decode(await store.read()).selectedDeckName, 'Bound2');
    expect(
      await snapshotValue(
        boundId,
        ProfileKeys.categoryAnki,
        'selectedDeckName',
      ),
      'Bound2',
    );
    expect(live.settings.selectedDeckName, 'Global', reason: '全局牌组不动');
    expect(live.settings.ankiConnectApiKey, 'k2', reason: '设备本地字段写 live');

    vm.leaveWorkSession(reader);
    expect(
      decode(await store.read()).selectedDeckName,
      'Global',
      reason: '退出恢复全局',
    );
  });

  test('作品配置快照没有 Anki 字段时不接管 Anki 设置', () async {
    final _MemoryAnkiStore live = _MemoryAnkiStore(
      const AnkiSettings(selectedDeckName: 'Global'),
    );
    final WorkScopedAnkiSettingsStore store = WorkScopedAnkiSettingsStore(
      live: () => live,
    );
    await openBook();
    expect(scope.active, isNotNull);
    expect(await store.read(), live.json, reason: '与 live 逐字节一致');
  });

  test('writeWorkScopedAnkiSettings：非激活配置写快照，激活配置写 live', () async {
    final FakeAnkiRepository anki = FakeAnkiRepository();
    final ProfileRepository r = ProfileRepository(db, anki);
    await r.writeWorkScopedAnkiSettings(boundId, <String, String>{
      'selectedDeckName': 'Bound',
    });
    expect(
      await snapshotValue(
        boundId,
        ProfileKeys.categoryAnki,
        'selectedDeckName',
      ),
      'Bound',
    );
    expect((await anki.loadSettings()).selectedDeckName, isNull);

    await r.writeWorkScopedAnkiSettings(defaultId, <String, String>{
      'selectedDeckName': 'Active',
    });
    expect((await anki.loadSettings()).selectedDeckName, 'Active');
  });

  test('弹窗进程镜像：按发布的配置 id 装上同一套覆盖层', () async {
    expect(parseWorkProfileSessionProfileId(''), isNull);
    expect(parseWorkProfileSessionProfileId('0:3'), isNull);
    expect(parseWorkProfileSessionProfileId('junk'), isNull);
    expect(parseWorkProfileSessionProfileId('$boundId:7'), boundId);

    final Object popup = Object();
    expect(
      await scope.enterProfile(
        owner: popup,
        repository: repo,
        resolveProfileId: () async =>
            parseWorkProfileSessionProfileId('$boundId:0'),
      ),
      isTrue,
    );
    expect(scope.active?.profileId, boundId);
    expect(
      await scope.enterProfile(
        owner: popup,
        repository: repo,
        resolveProfileId: () async => parseWorkProfileSessionProfileId(''),
      ),
      isTrue,
    );
    expect(scope.active, isNull);
  });

  test('发布作品会话：值不变不写库（不白抬 prefs_version）', () async {
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setWorkProfileSession('$boundId:0');
    expect(await db.getPref(kWorkProfileSessionPrefKey), isNotNull);
    final int version = await prefs.readPrefsVersionFromDb();
    await prefs.setWorkProfileSession('$boundId:0');
    expect(await prefs.readPrefsVersionFromDb(), version);
  });

  test('发布键是设备本地键：不进 Profile 快照、不随同步 / 合并导入', () {
    expect(ProfileKeys.isExcludedPref(kWorkProfileSessionPrefKey), isTrue);
    expect(
      SyncRepository.deviceLocalPrefKeys.contains(kWorkProfileSessionPrefKey),
      isTrue,
    );
  });

  // 源码守卫。Tests run with CWD = `fushi/`.
  test('接线：制卡链读作品会话、主进程发布、弹窗进程镜像、视频页会话就绪重取字幕样式', () {
    final String anki = File(
      'lib/src/anki/anki_view_model.dart',
    ).readAsStringSync();
    expect(
      anki.contains(
        'createAnkiRepository(settingsStore: WorkScopedAnkiSettingsStore())',
      ),
      isTrue,
      reason: '本机制卡链的 Anki 设置要叠作品会话',
    );
    expect(
      anki.contains('WorkProfileScope.instance.active'),
      isTrue,
      reason: '复习制卡在作品会话里落进作品配置的复习副本',
    );
    final String vmSrc = File(
      'lib/src/profile/profile_view_model.dart',
    ).readAsStringSync();
    expect(
      vmSrc.contains(
        "ref.watch(platformServicesProvider).createAnkiRepository()",
      ),
      isTrue,
      reason: '快照 / 应用配置的仓库必须读 live Anki 设置，不能叠作品会话',
    );
    final String app = File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      app.contains(
        'WorkProfileScope.instance.addListener(_publishWorkProfileSession)',
      ),
      isTrue,
    );
    expect(
      'await mirrorMainProcessWorkSession();'.allMatches(app).length,
      2,
      reason: '弹窗冷启动与热复用两条路径都要镜像主进程的作品会话',
    );
    expect(app.contains('themeNotifier.onWorkProfileScopeChanged()'), isTrue);
    final String video = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final int resolve = video.indexOf(
      'Future<void> _resolveAndApplyVideoProfile()',
    );
    expect(resolve, greaterThan(0));
    expect(
      video
          .substring(resolve, resolve + 2500)
          .contains('VideoSubtitleStyle.decode(appModel.videoSubtitleStyle)'),
      isTrue,
    );
  });
}
