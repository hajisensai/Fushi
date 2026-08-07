// PR#457 审查 §10-3（用户拍板方案甲）服务层守卫：**不点「应用样式到 Anki」
// 就不会写 Anki**。
//
// 修复前 `maybeAutoMigrateOnStartup` 只看「期望 styling ≠ Anki 端 且 Anki 端
// 是自有产物」，于是拖一下字号、下次启动就静默推送。现在多一道基线闸门：只有
// Hibiki 出厂基线真的变了才自动推。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _TempDirLapisService extends LapisTemplateService {
  _TempDirLapisService(super.repository, this._dir);

  final Directory _dir;

  @override
  Future<Directory> backupDirectory() async => _dir;
}

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({required this.definition, required this.settings});

  final AnkiNoteTypeDefinition definition;
  AnkiSettings settings;
  String? pushedCss;

  @override
  bool get supportsNoteTypeEditing => true;

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => settings = s;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
          String modelName) async =>
      definition;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async {
    pushedCss = css;
    return true;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
          String modelName, List<AnkiCardTemplate> templates) async =>
      true;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

AnkiNoteTypeDefinition _definition(String css) => AnkiNoteTypeDefinition(
      name: LapisNoteType.modelName,
      fields: LapisNoteType.fields,
      templates: const <AnkiCardTemplate>[
        AnkiCardTemplate(
            name: 'Card 1', front: '{{Expression}}', back: '{{Meaning}}'),
      ],
      css: css,
    );

Future<File> _writeBackup(Directory dir, AnkiNoteTypeDefinition def) async {
  final File file =
      File('${dir.path}${Platform.pathSeparator}lapis-backup.json');
  await file.writeAsString(jsonEncode(<String, dynamic>{
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'noteType': def.toJson(),
  }));
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lapis_auto_migrate_test');
    LapisTemplateService.resetAutoMigrateSessionGate();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('改了字号却没点 Apply：基线没变 → 一个字节都不写 Anki', () async {
    // Anki 上是出厂态；用户在设置里把字号调到 150 但没点「应用」。
    final _FakeRepo repo = _FakeRepo(
      definition: _definition(LapisNoteType.template.css),
      settings: AnkiSettings(
        lapisFontScalePercent: 150,
        lapisMigratedBaselineSha: currentLapisBaselineSha,
      ),
    );

    await _TempDirLapisService(repo, dir).maybeAutoMigrateOnStartup();

    expect(repo.pushedCss, isNull, reason: 'Apply 才是唯一写入闸门');
    expect(repo.settings.lapisFontScalePercent, 150);
  });

  // 契约变更（不是回归）：自动迁移**不再写 Anki**。
  //
  // 它原本的意义是「Hibiki 出厂基线升级了，把新基线同步过去」——而基线现在取自
  // 用户自己的 Lapis（见 stripLapisUserSection / composeLapisCssOnBase），我们
  // 根本不再拥有基线，这个动作失去了前提。它同时是唯一一条「用户没点任何按钮
  // 就改他 Anki」的路径，正是用户反馈「Hibiki 把我的字体改了」的最大嫌疑。
  // 写入统一收敛到用户显式点「应用样式到 Anki」那一个闸门。
  test('基线真变了也不自动写 Anki，只把基线指纹记下', () async {
    final _FakeRepo repo = _FakeRepo(
      definition: _definition(LapisNoteType.template.css),
      settings: const AnkiSettings(
        lapisFontScalePercent: 150,
        lapisMigratedBaselineSha: 'sha-of-a-much-older-baseline',
      ),
    );

    await _TempDirLapisService(repo, dir).maybeAutoMigrateOnStartup();

    expect(
      repo.pushedCss,
      isNull,
      reason: '自动路径写 Anki = 用户没点任何东西，他的卡就变了',
    );
    expect(repo.settings.lapisMigratedBaselineSha, currentLapisBaselineSha);
  });

  test('老装置首次升级（无记录）+ Anki 已带当前基线 → 不推，只补记基线', () async {
    final String ankiCss =
        composeLapisCss(fontScalePercent: 100, customCss: '.a { }');
    final _FakeRepo repo = _FakeRepo(
      definition: _definition(ankiCss),
      settings: const AnkiSettings(
        lapisFontScalePercent: 125,
        lapisCustomCss: '.a { }',
      ),
    );

    await _TempDirLapisService(repo, dir).maybeAutoMigrateOnStartup();

    expect(repo.pushedCss, isNull);
    expect(repo.settings.lapisMigratedBaselineSha, currentLapisBaselineSha);
    // 补记基线不得顺手改动用户的客制化设置。
    expect(repo.settings.lapisFontScalePercent, 125);
    expect(repo.settings.lapisCustomCss, '.a { }');
  });

  test('自动迁移全程一个字节都不写 Anki，跑几次都一样', () async {
    final _FakeRepo repo = _FakeRepo(
      definition: _definition(LapisNoteType.template.css),
      settings: const AnkiSettings(
        lapisFontScalePercent: 110,
        lapisMigratedBaselineSha: 'stale',
      ),
    );
    final LapisTemplateService service = _TempDirLapisService(repo, dir);

    await service.maybeAutoMigrateOnStartup();
    expect(repo.pushedCss, isNull);
    expect(repo.settings.lapisMigratedBaselineSha, currentLapisBaselineSha);

    LapisTemplateService.resetAutoMigrateSessionGate();
    await service.maybeAutoMigrateOnStartup();
    expect(repo.pushedCss, isNull);
  });

  test('从备份恢复后自动迁移不得把恢复撤销', () async {
    final String backupCss =
        composeLapisCss(fontScalePercent: 125, customCss: '.mine { }');
    final AnkiNoteTypeDefinition def = _definition(backupCss);
    final _FakeRepo repo = _FakeRepo(
      definition: def,
      settings: const AnkiSettings(lapisFontScalePercent: 100),
    );
    final File file = await _writeBackup(dir, def);
    final LapisTemplateService service = _TempDirLapisService(repo, dir);

    await service.restoreBackup(file);
    // 恢复必须反解出备份当时的字号（§10-2 方案甲），选择器才不会失灵。
    expect(repo.settings.lapisFontScalePercent, 125);
    expect(repo.settings.lapisCustomCss, '.mine { }');
    expect(repo.settings.lapisMigratedBaselineSha, currentLapisBaselineSha);

    repo.pushedCss = null;
    LapisTemplateService.resetAutoMigrateSessionGate();
    await service.maybeAutoMigrateOnStartup();
    expect(repo.pushedCss, isNull);
  });
}
