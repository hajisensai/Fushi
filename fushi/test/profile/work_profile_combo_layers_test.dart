import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_anki_settings_store.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 内存里的 live Anki 设置存储。
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

/// 组合模型阶段 2（拍板台 design-combo-node-split）：作品会话不再整包取一份绑定配置，而是
/// 作品 → 媒体类型 → 语言 → 默认逐叶子解析；会话内写入落到叶子的来源组合，继承中的叶子落到
/// 最高层，绝不写全局。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late int defaultId;
  late int mediaId;
  late int langId;
  final WorkProfileScope scope = WorkProfileScope.instance;
  final Object reader = Object();

  const String theme = 'design_system';
  const String font = 'src:reader_fushi:font_catalog';
  const String fontSize = 'src:reader_fushi:font_size';
  const String subtitle = 'video_subtitle_style';

  Future<String?> rowValue(int profileId, String category, String key) async {
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId)) {
      if (r.category == category && r.key == key) return r.value;
    }
    return null;
  }

  Future<void> put(int profileId, String category, String key, String v) =>
      db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: category,
          key: key,
          value: v,
        ),
      );

  /// 存量 Profile：整份快照此刻的 live 设置（新建配置的同一条路）。
  Future<int> legacyProfile(String name) async {
    final int id = await repo.createProfile(name);
    await repo.snapshotCurrentSettings(id);
    return id;
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
    await db.setPref(theme, PrefCodec.encode('material'));
    await db.setPref(font, PrefCodec.encode('["Noto"]'));
    await db.setPref(fontSize, PrefCodec.encode(18));
    await db.setPref(subtitle, PrefCodec.encode('{"g":1}'));

    mediaId = await legacyProfile('漫画');
    langId = await legacyProfile('日语');
    await put(
      mediaId,
      ProfileKeys.categoryPref,
      theme,
      PrefCodec.encode('glass'),
    );
    await put(
      langId,
      ProfileKeys.categoryPref,
      theme,
      PrefCodec.encode('cupertino'),
    );
    await put(
      langId,
      ProfileKeys.categoryPref,
      font,
      PrefCodec.encode('["Mincho"]'),
    );
    await put(langId, ProfileKeys.categoryAnki, 'selectedDeckName', 'JP');
    await repo.setMediaTypeBinding(ProfileMediaKind.manga, mediaId);
    await repo.setLanguageBinding('ja', langId);
  });

  tearDown(() async {
    scope.debugReset();
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  Future<void> openManga({String? language = 'ja'}) => vm.enterWorkSession(
    owner: reader,
    bookUid: 'manga-1',
    languageTag: language,
    mediaType: ProfileMediaKind.manga,
  );

  test('媒体类型与语言逐叶子叠加：主题取媒体类型、字体取语言、其余默认', () async {
    await openManga();
    final WorkProfileSession session = scope.active!;
    expect(session.layers, <ComboScope, int>{
      ComboScope.mediaType: mediaId,
      ComboScope.language: langId,
    });
    expect(scope.scopedRaw(theme), PrefCodec.encode('glass'));
    expect(scope.scopedRaw(font), PrefCodec.encode('["Mincho"]'));
    expect(scope.scopedRaw(fontSize), PrefCodec.encode(18));
    expect(session.sourceProfileIdOf(FushiComboNode.appearanceTheme), mediaId);
    expect(session.sourceProfileIdOf(FushiComboNode.appearanceFonts), langId);
    expect(session.sourceProfileIdOf(FushiComboNode.appearanceSubtitles), null);
    expect(session.miningProfileId, langId, reason: '牌组来自语言层');
    expect(scope.ankiOverrides?['selectedDeckName'], 'JP');
  });

  test('只有语言命中时语言层整组生效（与旧版单份绑定一致）', () async {
    await vm.enterWorkSession(
      owner: reader,
      bookUid: 'book-1',
      languageTag: 'ja',
      mediaType: ProfileMediaKind.epub,
    );
    expect(scope.scopedRaw(theme), PrefCodec.encode('cupertino'));
    expect(scope.scopedRaw(font), PrefCodec.encode('["Mincho"]'));
  });

  test('写入路由：来源层改来源层；继承中的叶子拆进最高层；全局不动', () async {
    await openManga();
    await scope.write(font, PrefCodec.encode('["Gothic"]'));
    expect(
      await rowValue(langId, ProfileKeys.categoryPref, font),
      PrefCodec.encode('["Gothic"]'),
      reason: '字体来自语言层，改语言层',
    );
    expect(
      await rowValue(mediaId, ProfileKeys.categoryPref, font),
      PrefCodec.encode('["Noto"]'),
      reason: '媒体类型层那份（= 默认）不动',
    );

    await scope.write(subtitle, PrefCodec.encode('{"m":1}'));
    expect(
      await rowValue(mediaId, ProfileKeys.categoryPref, subtitle),
      PrefCodec.encode('{"m":1}'),
      reason: '字幕样式在继承默认，落到最高层（媒体类型）',
    );
    expect(
      await rowValue(langId, ProfileKeys.categoryPref, subtitle),
      PrefCodec.encode('{"g":1}'),
    );
    expect(
      scope.active!.sourceProfileIdOf(FushiComboNode.appearanceSubtitles),
      mediaId,
    );
    expect(await db.getPref(font), PrefCodec.encode('["Noto"]'));
    expect(await db.getPref(subtitle), PrefCodec.encode('{"g":1}'));

    // 重新进入：解析结果反映刚才的写入。
    vm.leaveWorkSession(reader);
    await openManga();
    expect(scope.scopedRaw(font), PrefCodec.encode('["Gothic"]'));
    expect(scope.scopedRaw(subtitle), PrefCodec.encode('{"m":1}'));
  });

  test('Anki：只写改了的字段，按叶子来源落库', () async {
    final _MemoryAnkiStore live = _MemoryAnkiStore(
      const AnkiSettings(selectedDeckName: 'Global', tags: 'g'),
    );
    final WorkScopedAnkiSettingsStore store = WorkScopedAnkiSettingsStore(
      live: () => live,
    );
    AnkiSettings decode(String? raw) =>
        AnkiSettings.fromJson(jsonDecode(raw!) as Map<String, dynamic>);
    await openManga();
    expect(decode(await store.read()).selectedDeckName, 'JP');

    await store.write(
      jsonEncode(
        decode(await store.read()).copyWith(selectedDeckName: 'JP2').toJson(),
      ),
    );
    expect(
      await rowValue(langId, ProfileKeys.categoryAnki, 'selectedDeckName'),
      'JP2',
      reason: '牌组来自语言层',
    );
    expect(
      await rowValue(mediaId, ProfileKeys.categoryAnki, 'selectedDeckName'),
      isNot('JP2'),
    );
    expect(live.settings.selectedDeckName, 'Global', reason: '全局牌组不动');
    expect(decode(await store.read()).selectedDeckName, 'JP2');
  });

  test('弹窗进程按发布的多层值镜像出同一份生效值', () async {
    await openManga();
    final String published = scope.publishedSessionValue;
    expect(published, ',$mediaId,$langId:0');
    vm.leaveWorkSession(reader);

    final Object popup = Object();
    await scope.mirrorPublishedSession(
      owner: popup,
      published: published,
      repository: repo,
    );
    expect(scope.scopedRaw(theme), PrefCodec.encode('glass'));
    expect(scope.scopedRaw(font), PrefCodec.encode('["Mincho"]'));
    scope.leave(popup);
  });

  test('绑定层就是激活配置时那层丢掉；全丢光则没有会话', () async {
    await repo.setMediaTypeBinding(ProfileMediaKind.manga, defaultId);
    await openManga();
    expect(scope.active!.layers, <ComboScope, int>{
      ComboScope.language: langId,
    });
    vm.leaveWorkSession(reader);

    await openManga(language: null);
    expect(scope.active, isNull);
  });
}
