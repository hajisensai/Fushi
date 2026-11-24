import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 组合模型阶段 3（拍板台 design-combo-node-split / design-srs-shared-library §4.2）：存量整份
/// 快照一次性迁移成「默认组合 + 只记被拆叶子的组合」，以及迁移后 apply / snapshot / copy /
/// 导出 / 导入 / 删除对组合格式的处理。
///
/// 往返断言（设计 §3.3「验证」）：迁移前每个单层绑定场景下整包 `applyProfile` 的生效值 ==
/// 迁移后按层解析的生效值；语言 + 媒体类型同时命中时的顺序变化单列断言（进报告）。
void main() {
  late FushiDatabase db;
  late FakeAnkiRepository anki;
  late ProfileRepository repo;
  late int defaultId;
  Set<String>? srsData;
  late Directory backupDir;

  const String theme = 'design_system';
  const String font = 'src:reader_fushi:font_catalog';
  const String fontSize = 'src:reader_fushi:font_size';
  const String subtitle = 'video_subtitle_style';

  SettingKey pref(String key) => SettingKey(ProfileKeys.categoryPref, key);

  ProfileRepository build() => ProfileRepository(
    db,
    anki,
    srsUserData: (List<String> uids) async => srsData,
    comboMigrationBackupDirectory: () async => backupDir,
  );

  Future<void> putRow(int profileId, String category, String key, String v) =>
      db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: category,
          key: key,
          value: v,
        ),
      );

  Future<Map<SettingKey, String>> rawRows(
    int profileId,
  ) async => <SettingKey, String>{
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId))
      SettingKey(r.category, r.key): r.value,
  };

  /// 存量 Profile：此刻活偏好的整份快照 + 改几个键（升级前「新建配置」那条路）。
  Future<int> legacyProfile(String name, Map<String, String> overrides) async {
    final int id = await repo.createProfile(name);
    await repo.snapshotCurrentSettings(id);
    for (final MapEntry<String, String> e in overrides.entries) {
      await putRow(id, ProfileKeys.categoryPref, e.key, e.value);
    }
    return id;
  }

  /// 迁移前 `applyProfile(id)` 会生效的值（组合管理的键）：整份快照本身。
  Future<Map<SettingKey, String>> legacyEffective(int id) async =>
      <SettingKey, String>{
        for (final MapEntry<SettingKey, String> e in (await repo.combos.rowsOf(
          id,
        )).entries)
          if (fushiSettingsTree.leafOf(e.key) != null) e.key: e.value,
      };

  void expectSameEffective(
    Map<SettingKey, String> resolved,
    Map<SettingKey, String> legacy, {
    required String reason,
  }) {
    for (final MapEntry<SettingKey, String> e in legacy.entries) {
      expect(resolved[e.key], e.value, reason: '$reason: ${e.key}');
    }
    for (final SettingKey k in resolved.keys) {
      if (k.category == kComboSyntheticCategory) continue;
      if (k.category == ProfileKeys.categoryDictionaryMeta) continue;
      expect(legacy.containsKey(k), isTrue, reason: '$reason: 多出 $k');
    }
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    anki = FakeAnkiRepository();
    srsData = <String>{};
    backupDir = await Directory.systemTemp.createTemp('combo_migration_test');
    repo = build();
    defaultId = await repo.createProfile('Default');
    await repo.setActiveProfileId(defaultId);
    await db.setPref(theme, PrefCodec.encode('material'));
    await db.setPref(font, PrefCodec.encode('["Noto"]'));
    await db.setPref(fontSize, PrefCodec.encode(18));
    await db.setPref(subtitle, PrefCodec.encode('{"g":1}'));
    await db.setPref('home_layout', PrefCodec.encode('grid'));
    await repo.snapshotCurrentSettings(defaultId);
  });

  tearDown(() async {
    await db.close();
    if (backupDir.existsSync()) await backupDir.delete(recursive: true);
  });

  test('单 Profile：成为默认组合、共享库是它自己，不出报告、不写备份；再跑一次是空操作', () async {
    await repo.ensureDefaultProfile();
    final Map<SettingKey, String> rows = await rawRows(defaultId);
    expect(
      rows[const SettingKey(kComboSyntheticCategory, kComboRoleKey)],
      'default',
    );
    expect(
      rows[const SettingKey(kComboSyntheticCategory, kComboSrsSharedUidKey)],
      await db.profileUidOf(defaultId),
    );
    expect(rows[pref(theme)], PrefCodec.encode('material'));
    expect(await repo.takePendingComboMigrationReport(), isNull);
    expect(backupDir.listSync(), isEmpty);

    // 默认组合的快照保留格式元数据行。
    await repo.snapshotCurrentSettings(defaultId);
    expect(await repo.combos.defaultComboId(), defaultId);
    final Map<SettingKey, String> before = await rawRows(defaultId);
    await repo.normalizeCombos();
    expect(await rawRows(defaultId), before);
  });

  test('多 Profile：其余只留不同的叶子；单层解析与迁移前整包生效值逐键一致；备份原样落盘', () async {
    final int b = await legacyProfile('B', <String, String>{
      theme: PrefCodec.encode('glass'),
      fontSize: PrefCodec.encode(22),
    });
    final int same = await legacyProfile('Same', const <String, String>{});
    final Map<SettingKey, String> legacyB = await legacyEffective(b);
    final Map<SettingKey, String> legacySame = await legacyEffective(same);

    await repo.ensureDefaultProfile();

    final DecodedComboRows decoded = decodeComboRows(
      fushiSettingsTree,
      await rawRows(b),
    );
    expect(decoded.role, ComboRole.named);
    expect(decoded.document.splitLeafIds, <String>{
      FushiComboNode.appearanceTheme,
      FushiComboNode.appearanceReaderStyle,
    });
    expect(
      decodeComboRows(fushiSettingsTree, await rawRows(same)).document.splits,
      isEmpty,
    );
    for (final ComboScope scope in <ComboScope>[
      ComboScope.mediaType,
      ComboScope.language,
    ]) {
      expectSameEffective(
        (await repo.combos.resolve(<ComboScope, int>{
          scope: b,
        })).settings.values,
        legacyB,
        reason: 'B @ ${scope.name}',
      );
      expectSameEffective(
        (await repo.combos.resolve(<ComboScope, int>{
          scope: same,
        })).settings.values,
        legacySame,
        reason: 'Same @ ${scope.name}',
      );
    }

    final List<FileSystemEntity> backups = backupDir.listSync();
    expect(backups, hasLength(1));
    final Map<String, Object?> backup =
        jsonDecode(File(backups.single.path).readAsStringSync())
            as Map<String, Object?>;
    final List<Object?> profiles = backup['profiles']! as List<Object?>;
    expect(profiles, hasLength(3));

    final ComboMigrationReport report = (await repo
        .takePendingComboMigrationReport())!;
    expect(report.defaultName, 'Default');
    expect(report.combos.map((ComboMigrationEntry e) => e.name), <String>[
      'B',
      'Same',
    ]);
    expect(
      await repo.takePendingComboMigrationReport(),
      isNull,
      reason: '只提示一次',
    );
    expect(await repo.loadComboMigrationReport(), isNotNull, reason: '可重看');
  });

  test('切换到组合格式的配置：活偏好 = 默认 + 它的拆分；切走时只写回差异；切回默认还原', () async {
    final int b = await legacyProfile('B', <String, String>{
      theme: PrefCodec.encode('glass'),
    });
    final Map<SettingKey, String> legacyB = await legacyEffective(b);
    await repo.ensureDefaultProfile();

    await repo.snapshotCurrentSettings(defaultId);
    await repo.setActiveProfileId(b);
    await repo.applyProfile(b);
    expectSameEffective(
      <SettingKey, String>{
        for (final MapEntry<SettingKey, String> e
            in (await repo.currentSettings()).entries)
          if (fushiSettingsTree.leafOf(e.key) != null) e.key: e.value,
      },
      legacyB,
      reason: '切到 B 的活偏好',
    );

    // 在 B 里改一个继承中的叶子（字幕样式）：切走时自动拆进 B。
    await db.setPref(subtitle, PrefCodec.encode('{"g":2}'));
    await repo.snapshotCurrentSettings(b);
    final DecodedComboRows bRows = decodeComboRows(
      fushiSettingsTree,
      await rawRows(b),
    );
    expect(bRows.role, ComboRole.named, reason: '仍是差异文档，没被写成全量');
    expect(bRows.document.splitLeafIds, <String>{
      FushiComboNode.appearanceTheme,
      FushiComboNode.appearanceSubtitles,
    });

    await repo.setActiveProfileId(defaultId);
    await repo.applyProfile(defaultId);
    expect(await db.getPref(theme), PrefCodec.encode('material'));
    expect(await db.getPref(subtitle), PrefCodec.encode('{"g":1}'));
    expect(await db.getPref('home_layout'), PrefCodec.encode('grid'));
  });

  test('三层绑定全有：每层单独解析与迁移前一致；语言 + 媒体类型的顺序变化进报告；作品层不接管的拆分列为忽略', () async {
    final int lang = await legacyProfile('Lang', <String, String>{
      theme: PrefCodec.encode('glass'),
    });
    final int media = await legacyProfile('Media', <String, String>{
      font: PrefCodec.encode('["Mincho"]'),
    });
    final int work = await legacyProfile('Work', <String, String>{
      fontSize: PrefCodec.encode(30),
      'home_layout': PrefCodec.encode('list'),
    });
    await repo.setLanguageBinding('ja', lang);
    await repo.setMediaTypeBinding(ProfileMediaKind.video, media);
    await repo.setBookProfile('book-1', work);
    final Map<int, Map<SettingKey, String>> legacy =
        <int, Map<SettingKey, String>>{
          for (final int id in <int>[lang, media, work])
            id: await legacyEffective(id),
        };

    await repo.ensureDefaultProfile();

    expectSameEffective(
      (await repo.combos.resolve(<ComboScope, int>{
        ComboScope.language: lang,
      })).settings.values,
      legacy[lang]!,
      reason: '语言层',
    );
    expectSameEffective(
      (await repo.combos.resolve(<ComboScope, int>{
        ComboScope.mediaType: media,
      })).settings.values,
      legacy[media]!,
      reason: '媒体类型层',
    );
    final ResolvedComboStack all = await repo.combos.resolve(<ComboScope, int>{
      ComboScope.work: work,
      ComboScope.mediaType: media,
      ComboScope.language: lang,
    });
    expect(all.settings.valueOf(pref(fontSize)), PrefCodec.encode(30));
    expect(all.settings.valueOf(pref(font)), PrefCodec.encode('["Mincho"]'));
    expect(all.settings.valueOf(pref(theme)), PrefCodec.encode('glass'));
    expect(
      all.settings.valueOf(pref('home_layout')),
      PrefCodec.encode('grid'),
      reason: '「其他设置」不能在作品层拆：取默认',
    );

    final ComboMigrationReport report = (await repo
        .takePendingComboMigrationReport())!;
    final ComboBindingConflict conflict = report.conflicts.single;
    expect(conflict.languageTag, 'ja');
    expect(conflict.mediaType, ProfileMediaKind.video.dbValue);
    expect(conflict.leaves, <String>[FushiComboNode.appearanceFonts]);
    final ComboIgnoredSplitEntry ignored = report.ignored.single;
    expect(ignored.profile, 'Work');
    expect(ignored.scope, ComboScope.work);
    expect(ignored.leaves, <String>[FushiComboNode.other]);
  });

  test('旧 category 快照与设备本地键：旧行按今天的键参与比较，设备本地键不进组合', () async {
    final int old = await legacyProfile('Old', const <String, String>{});
    await db.deleteProfileSetting(old, ProfileKeys.categoryPref, fontSize);
    await putRow(
      old,
      ProfileKeys.categoryReader,
      'font_size',
      PrefCodec.encode(26),
    );
    await putRow(old, ProfileKeys.categoryPref, 'active_profile_id', '999');

    await repo.ensureDefaultProfile();

    final DecodedComboRows decoded = decodeComboRows(
      fushiSettingsTree,
      await rawRows(old),
    );
    expect(decoded.document.splitLeafIds, <String>{
      FushiComboNode.appearanceReaderStyle,
    });
    expect(
      decoded.document.splits[FushiComboNode.appearanceReaderStyle]![pref(
        fontSize,
      )],
      PrefCodec.encode(26),
    );
    expect(
      (await rawRows(
        old,
      )).keys.any((SettingKey k) => k.key == 'active_profile_id'),
      isFalse,
    );
    expect(await repo.getActiveProfileId(), defaultId, reason: '活偏好不动');
  });

  test('回退点（绑定临时切换前自己选的）优先当默认组合', () async {
    final int b = await legacyProfile('B', <String, String>{
      theme: PrefCodec.encode('glass'),
    });
    await repo.setActiveProfileId(b);
    await repo.setFallbackProfileId(defaultId);
    await repo.ensureDefaultProfile();
    expect(await repo.combos.defaultComboId(), defaultId);
    expect(
      decodeComboRows(fushiSettingsTree, await rawRows(b)).role,
      ComboRole.named,
    );
  });

  group('复习库（§4.2）', () {
    test('只有一份有复习数据：共享库指向它，谁也不拆', () async {
      final int b = await legacyProfile('B', const <String, String>{});
      await legacyProfile('C', const <String, String>{});
      srsData = <String>{await db.profileUidOf(b)};
      await repo.ensureDefaultProfile();
      expect(
        (await rawRows(defaultId))[const SettingKey(
          kComboSyntheticCategory,
          kComboSrsSharedUidKey,
        )],
        await db.profileUidOf(b),
      );
      expect(
        decodeComboRows(
          fushiSettingsTree,
          await rawRows(b),
        ).document.isSplit(FushiComboNode.srsLibrary),
        isFalse,
      );
    });

    test('多份各有数据：非默认的拆成独立复习库；复习库读不了时先迁设置、下次补定并补进报告', () async {
      final int b = await legacyProfile('B', const <String, String>{});
      final int c = await legacyProfile('C', const <String, String>{});
      srsData = null;
      await repo.ensureDefaultProfile();
      expect(
        (await rawRows(defaultId)).containsKey(
          const SettingKey(kComboSyntheticCategory, kComboSrsSharedUidKey),
        ),
        isFalse,
        reason: '没定',
      );
      expect((await repo.loadComboMigrationReport())!.srs, isNull);

      srsData = <String>{
        await db.profileUidOf(defaultId),
        await db.profileUidOf(b),
        await db.profileUidOf(c),
      };
      await repo.normalizeCombos();
      for (final int id in <int>[b, c]) {
        expect(
          decodeComboRows(
            fushiSettingsTree,
            await rawRows(id),
          ).document.splits[FushiComboNode.srsLibrary],
          <SettingKey, String>{
            const SettingKey(kComboSyntheticCategory, kComboSrsLibraryKey):
                kComboSrsLibraryOwn,
          },
        );
      }
      final ComboMigrationReport report = (await repo
          .takePendingComboMigrationReport())!;
      expect(report.srs!.sharedProfile, 'Default');
      expect(report.srs!.ownProfiles, <String>['B', 'C']);
    });
  });

  group('迁移后的 copy / create / 导出 / 导入 / 删除', () {
    late int b;

    setUp(() async {
      b = await legacyProfile('B', <String, String>{
        theme: PrefCodec.encode('glass'),
      });
      await repo.ensureDefaultProfile();
    });

    test('复制默认组合 = 什么都不拆的普通组合；复制组合 = 同样的拆分；默认始终只有一份', () async {
      final int copyOfDefault = await repo.copyProfile(defaultId, 'D2');
      final int copyOfB = await repo.copyProfile(b, 'B2');
      final DecodedComboRows d2 = decodeComboRows(
        fushiSettingsTree,
        await rawRows(copyOfDefault),
      );
      expect(d2.role, ComboRole.named);
      expect(d2.document.splits, isEmpty);
      expect(
        decodeComboRows(
          fushiSettingsTree,
          await rawRows(copyOfB),
        ).document.splitLeafIds,
        <String>{FushiComboNode.appearanceTheme},
      );
      expect(await repo.combos.defaultComboId(), defaultId);
    });

    test('新建配置 = 普通组合，快照只拆与默认不同的叶子', () async {
      final int fresh = await repo.createProfile('New');
      await repo.snapshotCurrentSettings(fresh);
      final DecodedComboRows decoded = decodeComboRows(
        fushiSettingsTree,
        await rawRows(fresh),
      );
      expect(decoded.role, ComboRole.named);
      expect(decoded.document.splits, isEmpty);
    });

    test('导出组合 = 生效值全量（v1 格式，无组合行）；导入为新组合时落成差异', () async {
      final String json = await repo.exportProfileToJson(b);
      final ProfileExport export = repo.parseProfileExport(json);
      final Map<String, String> prefs = <String, String>{
        for (final ProfileSettingEntry e in export.settings)
          if (e.category == ProfileKeys.categoryPref) e.key: e.value,
      };
      expect(prefs[theme], PrefCodec.encode('glass'));
      expect(prefs['home_layout'], PrefCodec.encode('grid'), reason: '没拆的也导出');
      expect(
        export.settings.any(
          (ProfileSettingEntry e) => e.category == kComboSyntheticCategory,
        ),
        isFalse,
      );

      final int imported = await repo.importProfileFromJson(json);
      final DecodedComboRows decoded = decodeComboRows(
        fushiSettingsTree,
        await rawRows(imported),
      );
      expect(decoded.role, ComboRole.named);
      expect(decoded.document.splitLeafIds, <String>{
        FushiComboNode.appearanceTheme,
      });
    });

    test('覆盖导入默认组合：身份行（role / 共享库）保留', () async {
      final String json = await repo.exportProfileToJson(b);
      await repo.importProfileFromJson(
        json,
        mode: ProfileImportMode.overwrite,
        targetProfileId: defaultId,
      );
      expect(await repo.combos.defaultComboId(), defaultId);
      expect(
        (await rawRows(defaultId))[pref(theme)],
        PrefCodec.encode('glass'),
      );
    });

    test('删除默认组合：激活的组合接班成默认，其余组合生效值不变', () async {
      final int c = await repo.createProfile('C');
      await repo.combos.saveDocument(
        c,
        ComboDocument(<String, Map<SettingKey, String>>{
          FushiComboNode.appearanceFonts: <SettingKey, String>{
            pref(font): PrefCodec.encode('["Gothic"]'),
          },
        }),
      );
      final Map<SettingKey, String> cBefore = (await repo.combos.resolve(
        <ComboScope, int>{ComboScope.language: c},
      )).settings.values;

      await repo.snapshotCurrentSettings(defaultId);
      await repo.setActiveProfileId(b);
      await repo.applyProfile(b);
      await repo.deleteProfile(defaultId);

      expect(await repo.combos.defaultComboId(), b);
      expect(await repo.getActiveProfileId(), b);
      expect(await db.getPref(theme), PrefCodec.encode('glass'));
      final Map<SettingKey, String> cAfter = (await repo.combos.resolve(
        <ComboScope, int>{ComboScope.language: c},
      )).settings.values;
      for (final MapEntry<SettingKey, String> e in cBefore.entries) {
        if (e.key.category == kComboSyntheticCategory) continue;
        expect(cAfter[e.key], e.value, reason: '${e.key}');
      }
    });
  });

  test('偏好键登记：报告与提示标记不进配置快照', () {
    expect(ProfileKeys.isExcludedPref(kComboMigrationReportPrefKey), isTrue);
    expect(
      ProfileKeys.isExcludedPref(kComboMigrationNoticePendingPrefKey),
      isTrue,
    );
  });
}
