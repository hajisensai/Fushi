// PR#457 审查 §10-4 守卫：从备份恢复时，卡模板写入失败被静默吞掉，UI 仍报
// 「恢复成功」；且 Hibiki 侧客制化状态（settings）与已落地的 styling 之间存在
// 顺序造成的过期窗口。这里锁死修复后的契约：
//   styling 写成功 → 立刻对齐 settings → 再写卡模板 → 卡模板失败必须上抛。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 只把备份目录换成临时目录，其余走真实实现（避开 AppPaths 的平台通道）。
class _TempDirLapisService extends LapisTemplateService {
  _TempDirLapisService(super.repository, this._dir);

  final Directory _dir;

  @override
  Future<Directory> backupDirectory() async => _dir;
}

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({required this.definition, this.templatesOk = true});

  final AnkiNoteTypeDefinition definition;
  final bool templatesOk;

  AnkiSettings settings = const AnkiSettings(
    lapisFontScalePercent: 130,
    lapisCustomCss: '.stale { color: red; }',
    lapisAppliedCssSha: 'stale-sha',
  );
  String? pushedCss;
  int templateWriteCalls = 0;

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
      String modelName, List<AnkiCardTemplate> templates) async {
    templateWriteCalls++;
    return templatesOk;
  }

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
    dir = await Directory.systemTemp.createTemp('lapis_restore_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('恢复成功：styling 写穿 + settings 与备份对齐', () async {
    final String backupCss = composeLapisCss(
        fontScalePercent: 100, customCss: '.mine { color: #0f0; }');
    final AnkiNoteTypeDefinition def = _definition(backupCss);
    final _FakeRepo repo = _FakeRepo(definition: def);
    final File file = await _writeBackup(dir, def);

    await _TempDirLapisService(repo, dir).restoreBackup(file);

    expect(repo.pushedCss, backupCss);
    expect(repo.templateWriteCalls, 1);
    expect(repo.settings.lapisFontScalePercent, 100);
    expect(repo.settings.lapisCustomCss, contains('.mine { color: #0f0; }'));
    expect(repo.settings.lapisAppliedCssSha, lapisCssSha256(backupCss));
    // 对齐后期望态 == Anki 态：下次启动的漂移判定必须是 upToDate，
    // 不能把刚恢复的内容再覆写回去。
    expect(
      decideLapisStylingAction(
        ankiCss: repo.pushedCss!,
        expectedCss: composeLapisCss(
          fontScalePercent: repo.settings.lapisFontScalePercent,
          customCss: repo.settings.lapisCustomCss,
        ),
        lastAppliedSha: repo.settings.lapisAppliedCssSha,
      ),
      LapisStylingDecision.upToDate,
    );
  });

  test('卡模板写入被后端拒绝：上抛而不是谎报成功', () async {
    final String backupCss =
        composeLapisCss(fontScalePercent: 100, customCss: '.mine { }');
    final AnkiNoteTypeDefinition def = _definition(backupCss);
    final _FakeRepo repo = _FakeRepo(definition: def, templatesOk: false);
    final File file = await _writeBackup(dir, def);

    await expectLater(
      _TempDirLapisService(repo, dir).restoreBackup(file),
      throwsA(isA<StateError>()),
    );
    expect(repo.templateWriteCalls, 1);
    // styling 已落地 → settings 必须已经对齐（不留过期期望态半态）。
    expect(repo.settings.lapisAppliedCssSha, lapisCssSha256(backupCss));
    expect(repo.settings.lapisFontScalePercent, 100);
  });

  test('备份无用户区段：清空客制化并清掉指纹', () async {
    final AnkiNoteTypeDefinition def = _definition(LapisNoteType.template.css);
    final _FakeRepo repo = _FakeRepo(definition: def);
    final File file = await _writeBackup(dir, def);

    await _TempDirLapisService(repo, dir).restoreBackup(file);

    expect(repo.settings.lapisCustomCss, isEmpty);
    expect(repo.settings.lapisFontScalePercent, 100);
    expect(repo.settings.lapisAppliedCssSha, isNull);
  });
}
