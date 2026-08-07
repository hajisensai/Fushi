// 「恢复出厂 Lapis」的契约守卫。
//
// 这是卡片长歪了、又没有可用备份时的唯一兜底出口，所以三件事必须成立：
//   1. 覆盖前先落备份（备份门是门，不是装饰）
//   2. 真的把出厂 CSS 与出厂正反面模板都推出去（只推一半等于没恢复）
//   3. Hibiki 侧客制化清干净、两个指纹对齐到出厂值
//      （置 null 会让下次启动的自动迁移把刚恢复好的卡型又当成来历不明）
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
  _FakeRepo({
    required this.definition,
    this.supportsEditing = true,
    this.stylingOk = true,
    this.templatesOk = true,
  });

  final AnkiNoteTypeDefinition? definition;
  final bool supportsEditing;
  final bool stylingOk;
  final bool templatesOk;

  /// 恢复前的「脏」状态：字号、自定义 CSS、自定义区域、两个指纹全都非出厂。
  AnkiSettings settings = const AnkiSettings(
    lapisFontScalePercent: 130,
    lapisCustomCss: '.mine { color: red; }',
    lapisAppliedCssSha: 'stale-css',
    lapisAppliedTemplateSha: 'stale-template',
    lapisCustomBlocks: <LapisCustomBlock>[
      LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['MiscInfo'],
      ),
    ],
  );

  String? pushedCss;
  List<AnkiCardTemplate>? pushedTemplates;

  @override
  bool get supportsNoteTypeEditing => supportsEditing;

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
    return stylingOk;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
      String modelName, List<AnkiCardTemplate> templates) async {
    pushedTemplates = templates;
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
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

/// 一份「被改歪了」的 Anki 端定义：模板与 CSS 都不是出厂内容。
AnkiNoteTypeDefinition _mangledDefinition() => AnkiNoteTypeDefinition(
      name: LapisNoteType.modelName,
      fields: LapisNoteType.fields,
      css: '.card { font-family: Comic Sans MS; }',
      templates: const <AnkiCardTemplate>[
        AnkiCardTemplate(
          name: LapisNoteType.cardName,
          front: '<div>坏掉的正面</div>',
          back: '<div>坏掉的背面</div><div>多出来的一行</div>',
        ),
      ],
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lapis-factory-test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('推送出厂 CSS 与出厂正反面模板', () async {
    final _FakeRepo repo = _FakeRepo(definition: _mangledDefinition());
    final LapisRestoreFactoryResult result =
        await _TempDirLapisService(repo, tempDir).restoreFactoryDefaults();

    expect(result, LapisRestoreFactoryResult.restored);
    expect(repo.pushedCss, LapisNoteType.template.css);
    expect(repo.pushedTemplates, isNotNull);
    expect(repo.pushedTemplates!.length, 1);
    final AnkiCardTemplate card = repo.pushedTemplates!.single;
    expect(card.name, LapisNoteType.cardName);
    expect(card.front, LapisNoteType.front);
    // 只推 CSS 不推模板 = 没恢复：用户看到的「多出来一行」正是模板产出的。
    expect(card.back, LapisNoteType.back);
    expect(card.back, isNot(contains('多出来的一行')));
  });

  test('覆盖前先落备份，备份里是被改歪的那份（可回溯）', () async {
    final _FakeRepo repo = _FakeRepo(definition: _mangledDefinition());
    await _TempDirLapisService(repo, tempDir).restoreFactoryDefaults();

    final List<File> backups = tempDir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))
        .toList();
    expect(backups.length, 1, reason: '备份门没走，覆盖就不可逆了');
    final String body = backups.single.readAsStringSync();
    expect(body, contains('多出来的一行'));
    expect(body, contains('Comic Sans MS'));
  });

  test('客制化清干净，两个指纹对齐到出厂值而不是置 null', () async {
    final _FakeRepo repo = _FakeRepo(definition: _mangledDefinition());
    await _TempDirLapisService(repo, tempDir).restoreFactoryDefaults();

    expect(repo.settings.lapisFontScalePercent, 100);
    expect(repo.settings.lapisCustomCss, isEmpty);
    expect(repo.settings.lapisCustomBlocks, isEmpty);
    // 指纹置 null 会让下次启动的自动迁移把刚恢复好的卡型判成来历不明。
    expect(
      repo.settings.lapisAppliedCssSha,
      lapisCssSha256(LapisNoteType.template.css),
    );
    expect(
      repo.settings.lapisAppliedTemplateSha,
      lapisCssSha256(normalizeCssForCompare(LapisNoteType.back)),
    );
    expect(repo.settings.lapisMigratedBaselineSha, currentLapisBaselineSha);
  });

  test('恢复后再判漂移 = upToDate（不会立刻又要求覆盖一次）', () async {
    final _FakeRepo repo = _FakeRepo(definition: _mangledDefinition());
    await _TempDirLapisService(repo, tempDir).restoreFactoryDefaults();

    // 用恢复后的 settings + 出厂态 Anki 端重新判一次。
    final AnkiNoteTypeDefinition restored = AnkiNoteTypeDefinition(
      name: LapisNoteType.modelName,
      fields: LapisNoteType.fields,
      css: LapisNoteType.template.css,
      templates: const <AnkiCardTemplate>[
        AnkiCardTemplate(
          name: LapisNoteType.cardName,
          front: LapisNoteType.front,
          back: LapisNoteType.back,
        ),
      ],
    );
    expect(
      decideLapisStylingAction(
        ankiCss: restored.css,
        expectedCss: composeLapisCss(
          fontScalePercent: repo.settings.lapisFontScalePercent,
          customCss: repo.settings.lapisCustomCss,
        ),
        lastAppliedSha: repo.settings.lapisAppliedCssSha,
      ),
      LapisStylingDecision.upToDate,
    );
    expect(
      decideLapisTemplateAction(
        def: restored,
        expectedBack: composeLapisBackTemplate(repo.settings.lapisCustomBlocks),
        lastAppliedSha: repo.settings.lapisAppliedTemplateSha,
      ),
      LapisStylingDecision.upToDate,
    );
  });

  test('模板写入失败必须上抛，不谎报恢复成功', () async {
    final _FakeRepo repo = _FakeRepo(
      definition: _mangledDefinition(),
      templatesOk: false,
    );
    await expectLater(
      _TempDirLapisService(repo, tempDir).restoreFactoryDefaults(),
      throwsStateError,
    );
    // 抛出时不得已经把客制化清掉——否则用户既没恢复成、又丢了自己的配置。
    expect(repo.settings.lapisCustomBlocks, isNotEmpty);
    expect(repo.settings.lapisCustomCss, isNotEmpty);
  });

  test('样式写入失败同样上抛，且不碰模板', () async {
    final _FakeRepo repo = _FakeRepo(
      definition: _mangledDefinition(),
      stylingOk: false,
    );
    await expectLater(
      _TempDirLapisService(repo, tempDir).restoreFactoryDefaults(),
      throwsStateError,
    );
    expect(repo.pushedTemplates, isNull);
  });

  test('卡型不存在 / 后端不支持时不写任何东西', () async {
    final _FakeRepo missing = _FakeRepo(definition: null);
    expect(
      await _TempDirLapisService(missing, tempDir).restoreFactoryDefaults(),
      LapisRestoreFactoryResult.notFound,
    );
    expect(missing.pushedCss, isNull);
    expect(tempDir.listSync(), isEmpty, reason: '什么都没做却落了备份');

    final _FakeRepo unsupported = _FakeRepo(
      definition: _mangledDefinition(),
      supportsEditing: false,
    );
    expect(
      await _TempDirLapisService(unsupported, tempDir).restoreFactoryDefaults(),
      LapisRestoreFactoryResult.unsupported,
    );
    expect(unsupported.pushedCss, isNull);
  });
}
