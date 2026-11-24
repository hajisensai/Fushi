import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart'
    show insertSrsRestoredProfile;
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 组合阶段 6（拍板台 design-combo-node-split，设计 §2.2、§4.4、§5）：组合编辑（单独设置 / 恢复
/// 继承 / 子组整体 / 拆独立复习库）、作品上的匿名组合（直接拆、生效值表、存成组合、孤儿清理）、
/// 分享 JSON v2 往返、备份复习数据新建的配置落成组合格式。
void main() {
  late FushiDatabase db;
  late FakeAnkiRepository anki;
  late ProfileRepository repo;
  late int defaultId;
  late int combo;
  late Directory backupDir;

  const String theme = 'design_system';
  const String font = 'src:reader_fushi:font_catalog';
  const String fontSize = 'src:reader_fushi:font_size';
  const String subtitle = 'video_subtitle_style';
  const String other = 'home_layout';
  const String book = 'book-1';

  SettingKey pref(String key) => SettingKey(ProfileKeys.categoryPref, key);

  Future<Map<SettingKey, String>> rawRows(
    int profileId,
  ) async => <SettingKey, String>{
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId))
      SettingKey(r.category, r.key): r.value,
  };

  Future<DecodedComboRows> decoded(int profileId) async =>
      decodeComboRows(fushiSettingsTree, await rawRows(profileId));

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    anki = FakeAnkiRepository();
    backupDir = await Directory.systemTemp.createTemp('combo_editor_test');
    repo = ProfileRepository(
      db,
      anki,
      srsUserData: (List<String> uids) async => <String>{},
      comboMigrationBackupDirectory: () async => backupDir,
    );
    defaultId = await repo.createProfile('Default');
    await repo.setActiveProfileId(defaultId);
    await db.setPref(theme, PrefCodec.encode('material'));
    await db.setPref(font, PrefCodec.encode('["Noto"]'));
    await db.setPref(fontSize, PrefCodec.encode(18));
    await db.setPref(subtitle, PrefCodec.encode('{"g":1}'));
    await db.setPref(other, PrefCodec.encode('grid'));
    await repo.snapshotCurrentSettings(defaultId);
    await repo.ensureDefaultProfile();
    expect(await repo.combos.defaultComboId(), defaultId);
    combo = await repo.createProfile('Video');
  });

  tearDown(() async {
    await db.close();
    if (backupDir.existsSync()) await backupDir.delete(recursive: true);
  });

  group('组合编辑页', () {
    test('单独设置复制此刻的生效值；恢复继承撤销；非激活配置不用重新应用', () async {
      final ComboEditorData? before = await repo.loadComboEditor(combo);
      expect(before!.isDefault, isFalse);
      expect(before.document.splits, isEmpty);
      expect(before.defaultName, 'Default');

      await repo.splitComboNode(combo, FushiComboNode.appearanceTheme);
      final DecodedComboRows split = await decoded(combo);
      expect(split.document.splitLeafIds, <String>{
        FushiComboNode.appearanceTheme,
      });
      expect(
        split.document.splits[FushiComboNode.appearanceTheme]![pref(theme)],
        PrefCodec.encode('material'),
        reason: '拆出时复制默认组合此刻的值',
      );

      expect(
        await repo.restoreComboNode(combo, FushiComboNode.appearanceTheme),
        isFalse,
        reason: '不是激活配置，不用重新应用',
      );
      expect((await decoded(combo)).document.splits, isEmpty);
    });

    test('子组整体拆 = 其下能拆的叶子全拆（复习库归属不在内）；整体恢复同理', () async {
      await repo.splitComboNode(combo, FushiComboNode.appearance);
      expect((await decoded(combo)).document.splitLeafIds, <String>{
        FushiComboNode.appearanceTheme,
        FushiComboNode.appearanceFonts,
        FushiComboNode.appearanceReaderStyle,
        FushiComboNode.appearanceSubtitles,
      });
      await repo.splitComboNode(combo, FushiComboNode.srs);
      expect(
        (await decoded(combo)).document.isSplit(FushiComboNode.srsLibrary),
        isFalse,
      );
      await repo.restoreComboNode(combo, FushiComboNode.appearance);
      expect((await decoded(combo)).document.splits, isEmpty);
    });

    test('拆成独立复习库：只能经合并回共享，普通恢复继承不撤它', () async {
      await repo.splitComboSrsLibrary(combo);
      final ComboEditorData? data = await repo.loadComboEditor(combo);
      expect(data!.ownSrsLibrary, isTrue);
      await repo.restoreComboNode(combo, FushiComboNode.srs);
      expect(
        (await decoded(combo)).document.isSplit(FushiComboNode.srsLibrary),
        isTrue,
      );
    });

    test('默认组合不能编辑；编辑数据只读', () async {
      final ComboEditorData? data = await repo.loadComboEditor(defaultId);
      expect(data!.isDefault, isTrue);
      expect(
        () => repo.splitComboNode(defaultId, FushiComboNode.appearanceTheme),
        throwsStateError,
      );
    });

    test('激活的组合：活偏好里的改动算拆分；恢复继承要求重新应用，应用后活偏好回到默认值', () async {
      await repo.snapshotCurrentSettings(defaultId);
      await repo.setActiveProfileId(combo);
      await repo.applyProfile(combo);
      await db.setPref(theme, PrefCodec.encode('glass'));

      final ComboEditorData? data = await repo.loadComboEditor(combo);
      expect(data!.active, isTrue);
      expect(
        data.document.isSplit(FushiComboNode.appearanceTheme),
        isTrue,
        reason: '活偏好改过的项在编辑页已是单独设置',
      );

      expect(
        await repo.restoreComboNode(combo, FushiComboNode.appearanceTheme),
        isTrue,
      );
      await repo.applyProfile(combo);
      expect(await db.getPref(theme), PrefCodec.encode('material'));
    });
  });

  group('作品上的组合', () {
    test('直接拆：建匿名组合并绑上，配置列表不列；生效值表写明来源；全部恢复后撤掉', () async {
      expect(
        (await repo.loadWorkComboTable(
          bookUid: book,
          mediaType: ProfileMediaKind.epub,
        )).canEditOnWork,
        isTrue,
      );
      await repo.splitWorkNode(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
        nodeId: FushiComboNode.appearanceFonts,
        anonymousName: 'Work: Book',
      );
      final int? workId = await repo.getBookProfileId(book);
      expect(workId, isNotNull);
      expect((await decoded(workId!)).role, ComboRole.workLocal);
      expect(
        (await repo.getListedProfiles()).map((ProfileRow p) => p.id),
        isNot(contains(workId)),
      );

      final WorkComboTable table = await repo.loadWorkComboTable(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
      );
      expect(
        table.stack.settings.sourceOf(FushiComboNode.appearanceFonts).scope,
        ComboScope.work,
      );
      expect(
        table.stack.sourceProfileIdOf(FushiComboNode.appearanceFonts),
        workId,
      );
      expect(
        table.stack.settings.sourceOf(FushiComboNode.appearanceTheme).scope,
        ComboScope.defaults,
      );

      // 作品层不能拆的叶子（其他设置）：跳过，不建拆分。
      await repo.splitWorkNode(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
        nodeId: FushiComboNode.other,
        anonymousName: 'Work: Book',
      );
      expect((await decoded(workId)).document.splitLeafIds, <String>{
        FushiComboNode.appearanceFonts,
      });

      await repo.restoreWorkNode(
        bookUid: book,
        nodeId: FushiComboNode.appearanceFonts,
      );
      expect(await repo.getBookProfileId(book), isNull);
      expect(await db.getProfileById(workId), isNull, reason: '匿名组合没用了就删掉');
    });

    test('拆分复制作品此刻的生效值（含媒体类型层）', () async {
      await repo.splitComboNode(combo, FushiComboNode.appearanceFonts);
      await repo.combos.writeSettings(combo, <SettingKey, String?>{
        pref(font): PrefCodec.encode('["Mincho"]'),
      }, scope: ComboScope.mediaType);
      await repo.setMediaTypeBinding(ProfileMediaKind.epub, combo);

      await repo.splitWorkNode(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
        nodeId: FushiComboNode.appearanceFonts,
        anonymousName: 'Work: Book',
      );
      final int workId = (await repo.getBookProfileId(book))!;
      expect(
        (await decoded(
          workId,
        )).document.splits[FushiComboNode.appearanceFonts]![pref(font)],
        PrefCodec.encode('["Mincho"]'),
      );
    });

    test('存成组合：列进配置列表、作品照旧挂着它；绑到普通组合后不能在作品上直接拆', () async {
      await repo.splitWorkNode(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
        nodeId: FushiComboNode.appearanceTheme,
        anonymousName: 'Work: Book',
      );
      final int? saved = await repo.saveWorkComboAs(
        bookUid: book,
        name: 'Video',
      );
      expect(saved, isNotNull);
      final ProfileRow row = (await db.getProfileById(saved!))!;
      expect(row.name, 'Video (2)', reason: '重名加后缀');
      expect((await decoded(saved)).role, ComboRole.named);
      expect(
        (await repo.getListedProfiles()).map((ProfileRow p) => p.id),
        contains(saved),
      );
      expect(await repo.getBookProfileId(book), saved);

      final WorkComboTable table = await repo.loadWorkComboTable(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
      );
      expect(table.canEditOnWork, isFalse);
      expect(
        () => repo.splitWorkNode(
          bookUid: book,
          mediaType: ProfileMediaKind.epub,
          nodeId: FushiComboNode.appearanceFonts,
          anonymousName: 'x',
        ),
        throwsStateError,
      );
    });

    test('作品改绑别的组合 / 跟随默认：原来的匿名组合被删掉', () async {
      await repo.splitWorkNode(
        bookUid: book,
        mediaType: ProfileMediaKind.epub,
        nodeId: FushiComboNode.appearanceTheme,
        anonymousName: 'Work: Book',
      );
      final int workId = (await repo.getBookProfileId(book))!;
      await repo.setBookProfile(book, combo);
      expect(await db.getProfileById(workId), isNull);
      expect(await db.getProfileById(combo), isNotNull);
    });
  });

  group('分享 JSON v2', () {
    test('导出带单独设置的叶子；导入时与本机默认同值的声明拆分也保留', () async {
      await repo.splitComboNode(combo, FushiComboNode.appearanceTheme);
      final String json = await repo.exportProfileToJson(combo);
      final ProfileExport export = repo.parseProfileExport(json);
      expect(export.formatVersion, ProfileExport.currentFormatVersion);
      expect(export.splitNodes, <String>[FushiComboNode.appearanceTheme]);

      final int imported = await repo.importProfileFromJson(json);
      final DecodedComboRows d = await decoded(imported);
      expect(d.role, ComboRole.named);
      expect(d.document.splitLeafIds, <String>{
        FushiComboNode.appearanceTheme,
      }, reason: '值与本机默认相同，但对方是有意单独设置的');
    });

    test('导出默认组合：没有单独设置的叶子', () async {
      final ProfileExport export = repo.parseProfileExport(
        await repo.exportProfileToJson(defaultId),
      );
      expect(export.splitNodes, isEmpty);
    });
  });

  test('备份复习数据新建的配置：组合格式、设置全继承、复习库是它自己的独立库', () async {
    final int id = await insertSrsRestoredProfile(
      db,
      name: 'Phone（备份）',
      uid: '01900000-0000-7000-8000-000000000001',
    );
    final DecodedComboRows d = await decoded(id);
    expect(d.role, ComboRole.named);
    expect(d.document.splitLeafIds, <String>{FushiComboNode.srsLibrary});
    expect(d.document.splits[FushiComboNode.srsLibrary], <SettingKey, String>{
      const SettingKey(kComboSyntheticCategory, kComboSrsLibraryKey):
          kComboSrsLibraryOwn,
    });
  });
}
