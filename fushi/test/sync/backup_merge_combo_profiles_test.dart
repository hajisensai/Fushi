import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 组合阶段 6 的备份合并规则（设计 `docs/specs/2026-11-23-combo-settings-tree-design.md`
/// §4.4）：本机默认组合保持默认；对端默认组合降级成普通组合并按本机默认 diff（自己承载着共享库
/// 时拆成独立复习库）；两边同名组合单独设置的叶子取并集、都拆了的叶子以本机为准；对端的共享库
/// 指针不带进来。
void main() {
  const String themeKey = 'design_system';
  const String fontKey = 'src:reader_fushi:font_catalog';
  const SettingKey theme = SettingKey('pref', themeKey);
  const SettingKey font = SettingKey('pref', fontKey);
  const SettingKey role = SettingKey(kComboSyntheticCategory, kComboRoleKey);
  const SettingKey sharedUid = SettingKey(
    kComboSyntheticCategory,
    kComboSrsSharedUidKey,
  );

  Future<void> putRows(
    FushiDatabase db,
    int profileId,
    Map<SettingKey, String> rows,
  ) => db.replaceProfileSettings(profileId, <ProfileSettingsCompanion>[
    for (final MapEntry<SettingKey, String> e in rows.entries)
      ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: e.key.category,
        key: e.key.key,
        value: e.value,
      ),
  ]);

  Future<int> profile(FushiDatabase db, String name) => db.insertProfile(
    ProfilesCompanion.insert(name: name, createdAt: 1, updatedAt: 1),
  );

  Map<SettingKey, String> named(Map<String, Map<SettingKey, String>> splits) =>
      encodeComboRows(
        fushiSettingsTree,
        ComboDocument(splits),
        role: ComboRole.named,
      );

  Future<DecodedComboRows> decodedByName(FushiDatabase db, String name) async {
    final int id =
        (await db
                .customSelect(
                  'SELECT id FROM profiles WHERE name = ?',
                  variables: <Variable<Object>>[Variable<String>(name)],
                )
                .getSingle())
            .read<int>('id');
    return decodeComboRows(fushiSettingsTree, <SettingKey, String>{
      for (final ProfileSettingRow r in await db.getProfileSettings(id))
        SettingKey(r.category, r.key): r.value,
    });
  }

  test('两边各有默认组合 + 同名组合：本机默认不动、对端默认降级、同名组合拆分取并集', () async {
    final Directory curDir = await Directory.systemTemp.createTemp('cmb_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final FushiDatabase cur = FushiDatabase(curDir.path);
    final int curDefault = await profile(cur, 'Default');
    final String curDefaultUid = await cur.profileUidOf(curDefault);
    await putRows(cur, curDefault, <SettingKey, String>{
      theme: 's:material',
      font: 's:["Noto"]',
      role: ComboRole.defaults.wire,
      sharedUid: curDefaultUid,
    });
    final int curVideo = await profile(cur, 'Video');
    await putRows(
      cur,
      curVideo,
      named(<String, Map<SettingKey, String>>{
        FushiComboNode.appearanceTheme: <SettingKey, String>{theme: 's:glass'},
      }),
    );
    await cur.close();

    final Directory srcDir = await Directory.systemTemp.createTemp('cmb_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    final int srcPhone = await profile(src, 'Phone');
    const String phoneUid = '01900000-0000-7000-8000-0000000000aa';
    await src.adoptProfileUid(srcPhone, phoneUid);
    await putRows(src, srcPhone, <SettingKey, String>{
      theme: 's:dark',
      font: 's:["Noto"]',
      role: ComboRole.defaults.wire,
      sharedUid: phoneUid,
    });
    final int srcVideo = await profile(src, 'Video');
    await putRows(
      src,
      srcVideo,
      named(<String, Map<SettingKey, String>>{
        FushiComboNode.appearanceTheme: <SettingKey, String>{theme: 's:dark'},
        FushiComboNode.appearanceFonts: <SettingKey, String>{
          font: 's:["Mincho"]',
        },
      }),
    );
    final Directory zipDir = await Directory.systemTemp.createTemp('cmb_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).createBackup(zip);
    await src.close();

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    final FushiDatabase after = FushiDatabase(curDir.path);
    addTearDown(after.close);

    final DecodedComboRows def = await decodedByName(after, 'Default');
    expect(def.role, ComboRole.defaults);
    expect(def.values[theme], 's:material');
    expect(def.srsSharedUid, curDefaultUid);

    final DecodedComboRows phone = await decodedByName(after, 'Phone');
    expect(phone.role, ComboRole.named, reason: '对端默认降级');
    expect(phone.document.splitLeafIds, <String>{
      FushiComboNode.appearanceTheme,
      FushiComboNode.srsLibrary,
    });
    expect(
      phone.document.splits[FushiComboNode.appearanceTheme],
      <SettingKey, String>{theme: 's:dark'},
    );
    expect(phone.srsSharedUid, isNull);

    final DecodedComboRows video = await decodedByName(after, 'Video');
    expect(video.document.splitLeafIds, <String>{
      FushiComboNode.appearanceTheme,
      FushiComboNode.appearanceFonts,
    });
    expect(
      video.document.splits[FushiComboNode.appearanceTheme],
      <SettingKey, String>{theme: 's:glass'},
      reason: '两边都拆了的叶子以本机为准',
    );

    final List<QueryRow> defaults = await after
        .customSelect(
          'SELECT profile_id FROM profile_settings WHERE category = ? '
          'AND "key" = ? AND value = ?',
          variables: <Variable<Object>>[
            Variable<String>(kComboSyntheticCategory),
            Variable<String>(kComboRoleKey),
            Variable<String>(ComboRole.defaults.wire),
          ],
        )
        .get();
    expect(defaults, hasLength(1), reason: '合并后仍只有一份默认组合');
  });
}
