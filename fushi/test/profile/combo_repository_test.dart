import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 组合模型阶段 2（拍板台 design-combo-node-split）：`ComboRepository` 的行格式识别、按绑定层
/// 逐叶子解析、写入路由；存量整份快照读时 diff 与旧版「整包取快照」生效值逐键一致。
void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late int defaultId;
  late FakeAnkiRepository anki;

  const String theme = 'design_system';
  const String font = 'src:reader_fushi:font_catalog';
  const String fontSize = 'src:reader_fushi:font_size';
  const String subtitle = 'video_subtitle_style';

  SettingKey pref(String key) => SettingKey(ProfileKeys.categoryPref, key);

  Future<void> putRow(int profileId, String category, String key, String v) =>
      db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: category,
          key: key,
          value: v,
        ),
      );

  Future<Map<SettingKey, String>> rowsOf(
    int profileId,
  ) async => <SettingKey, String>{
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId))
      SettingKey(r.category, r.key): r.value,
  };

  /// 一份存量 Profile：先把此刻的 live 设置整份快照进去（与「新建配置」同一条路），再改几个键。
  Future<int> legacyProfile(String name, Map<String, String> overrides) async {
    final int id = await repo.createProfile(name);
    await repo.snapshotCurrentSettings(id);
    for (final MapEntry<String, String> e in overrides.entries) {
      await putRow(id, ProfileKeys.categoryPref, e.key, e.value);
    }
    return id;
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    anki = FakeAnkiRepository();
    repo = ProfileRepository(db, anki);
    defaultId = await repo.createProfile('Default');
    await repo.setActiveProfileId(defaultId);
    await db.setPref(theme, PrefCodec.encode('material'));
    await db.setPref(font, PrefCodec.encode('["Noto"]'));
    await db.setPref(fontSize, PrefCodec.encode(18));
    await db.setPref(subtitle, PrefCodec.encode('{"g":1}'));
    await db.setPref('home_layout', PrefCodec.encode('grid'));
  });

  tearDown(() => db.close());

  group('存量整份快照：读时 diff', () {
    test('单层生效值与整包取快照逐键一致（作品级键全覆盖）', () async {
      final int bound = await legacyProfile('B', <String, String>{
        theme: PrefCodec.encode('glass'),
        fontSize: PrefCodec.encode(22),
      });
      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.language: bound},
      );
      final ProfileSettingsView? legacyView = await repo.loadSettingsView(
        bound,
      );
      for (final MapEntry<String, String> e in legacyView!.prefsMap.entries) {
        if (ProfileKeys.isExcludedPref(e.key)) continue;
        expect(
          stack.settings.valueOf(pref(e.key)),
          e.value,
          reason: '${e.key} 与整包取快照一致',
        );
      }
      expect(stack.sourceProfileIdOf(FushiComboNode.appearanceTheme), bound);
      expect(
        stack.sourceProfileIdOf(FushiComboNode.appearanceReaderStyle),
        bound,
      );
      expect(
        stack.sourceProfileIdOf(FushiComboNode.appearanceFonts),
        isNull,
        reason: '字体与默认相同 = 继承',
      );
    });

    test('多层逐叶子解析：媒体类型高于语言，各自没拆的叶子往下找', () async {
      final int media = await legacyProfile('M', <String, String>{
        theme: PrefCodec.encode('glass'),
      });
      final int lang = await legacyProfile('L', <String, String>{
        theme: PrefCodec.encode('cupertino'),
        font: PrefCodec.encode('["Mincho"]'),
      });
      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{
          ComboScope.mediaType: media,
          ComboScope.language: lang,
        },
      );
      expect(stack.settings.valueOf(pref(theme)), PrefCodec.encode('glass'));
      expect(
        stack.settings.valueOf(pref(font)),
        PrefCodec.encode('["Mincho"]'),
        reason: '媒体类型没拆字体，取语言层的（旧版整包取媒体类型会丢掉它）',
      );
      expect(stack.settings.valueOf(pref(fontSize)), PrefCodec.encode(18));
      expect(stack.sourceProfileIdOf(FushiComboNode.appearanceTheme), media);
      expect(stack.sourceProfileIdOf(FushiComboNode.appearanceFonts), lang);
      expect(stack.sourceProfileIdOf(FushiComboNode.appearanceSubtitles), null);
      expect(stack.topProfileId, media);
    });

    test('指向激活配置 / 已不存在的层丢掉', () async {
      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.work: defaultId, ComboScope.language: 999},
      );
      expect(stack.layers, isEmpty);
      expect(stack.topProfileId, isNull);
      expect(await repo.loadWorkComboView(stack.layers), isNull);
    });

    test('旧 category（reader）行按今天的 pref 键参与 diff，不被当成未设置', () async {
      final int bound = await repo.createProfile('Old');
      await repo.snapshotCurrentSettings(bound);
      await db.deleteProfileSetting(bound, ProfileKeys.categoryPref, fontSize);
      await putRow(
        bound,
        ProfileKeys.categoryReader,
        'font_size',
        PrefCodec.encode(18),
      );
      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.language: bound},
      );
      expect(
        stack.sourceProfileIdOf(FushiComboNode.appearanceReaderStyle),
        isNull,
        reason: '换算后与默认相同 = 继承',
      );
      expect(stack.settings.valueOf(pref(fontSize)), PrefCodec.encode(18));
    });

    test('写入按旧语义改那一行，不改格式', () async {
      final int bound = await legacyProfile('B', const <String, String>{});
      await repo.writeWorkScopedPref(bound, theme, PrefCodec.encode('glass'));
      expect((await rowsOf(bound))[pref(theme)], PrefCodec.encode('glass'));
      expect(await repo.combos.isComboFormat(bound), isFalse);
      expect(
        await db.getPref(theme),
        PrefCodec.encode('material'),
        reason: '全局不动',
      );
    });
  });

  group('组合格式', () {
    test('saveDocument 只存被拆叶子 + 标记；解析时没拆的叶子继承默认', () async {
      final int combo = await repo.createProfile('C');
      await repo.combos.saveDocument(
        combo,
        ComboDocument(<String, Map<SettingKey, String>>{
          FushiComboNode.appearanceTheme: <SettingKey, String>{
            pref(theme): PrefCodec.encode('glass'),
          },
        }),
      );
      final Map<SettingKey, String> rows = await rowsOf(combo);
      expect(
        rows.keys.where((SettingKey k) => k.category == 'pref'),
        <SettingKey>[pref(theme)],
      );
      expect(await repo.combos.isComboFormat(combo), isTrue);

      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.work: combo},
      );
      expect(stack.settings.valueOf(pref(theme)), PrefCodec.encode('glass'));
      expect(
        stack.settings.valueOf(pref('home_layout')),
        PrefCodec.encode('grid'),
        reason: '没拆的叶子继承默认，不是「未设置」',
      );
      expect(
        stack.settings.valueOf(pref(subtitle)),
        PrefCodec.encode('{"g":1}'),
      );
    });

    test('loadSettingsView 对组合格式 = 默认之上的生效值（不会把没拆的设置当成被删）', () async {
      final int combo = await repo.createProfile('C');
      await repo.combos.saveDocument(
        combo,
        ComboDocument(<String, Map<SettingKey, String>>{
          FushiComboNode.appearanceTheme: <SettingKey, String>{
            pref(theme): PrefCodec.encode('glass'),
          },
        }),
      );
      final ProfileSettingsView? view = await repo.loadSettingsView(combo);
      expect(view!.prefsMap[theme], PrefCodec.encode('glass'));
      expect(view.prefsMap['home_layout'], PrefCodec.encode('grid'));
      expect(view.prefsMap[fontSize], PrefCodec.encode(18));
    });

    test('写入继承中的叶子：先复制默认组合的整组值拆出来，再改那个键', () async {
      final int combo = await repo.createProfile('C');
      await repo.combos.saveDocument(combo, ComboDocument.empty);
      await repo.writeWorkScopedPref(combo, fontSize, PrefCodec.encode(30));

      final DecodedComboRows decoded = decodeComboRows(
        fushiSettingsTree,
        await rowsOf(combo),
      );
      expect(decoded.document.splitLeafIds, <String>{
        FushiComboNode.appearanceReaderStyle,
      });
      final ResolvedComboStack stack = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.work: combo},
      );
      expect(stack.settings.valueOf(pref(fontSize)), PrefCodec.encode(30));
      expect(await db.getPref(fontSize), PrefCodec.encode(18), reason: '全局不动');

      // 设为「未设置」：叶子仍是拆开的，键在这一层没有值。
      await repo.writeWorkScopedPref(combo, fontSize, null);
      final ResolvedComboStack after = await repo.combos.resolve(
        <ComboScope, int>{ComboScope.work: combo},
      );
      expect(after.settings.valueOf(pref(fontSize)), isNull);
      expect(
        after.sourceProfileIdOf(FushiComboNode.appearanceReaderStyle),
        combo,
      );
    });

    test('Anki 字段写入同样经组合（制卡叶子自动拆）', () async {
      final int combo = await repo.createProfile('C');
      await repo.combos.saveDocument(combo, ComboDocument.empty);
      await repo.writeWorkScopedAnkiSettings(combo, <String, String>{
        'selectedDeckName': 'Bound',
      });
      final Map<String, String>? scoped = await repo.readWorkScopedAnki(
        <ComboScope, int>{ComboScope.work: combo},
      );
      expect(scoped?['selectedDeckName'], 'Bound');
      expect(
        (await anki.loadSettings()).selectedDeckName,
        isNull,
        reason: '全局 Anki 设置不动',
      );
    });
  });
}
