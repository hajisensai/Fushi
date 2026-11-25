// BUG-5470：浏览页检查器（编辑页签）的字段编辑器和笔记编辑页一样带字段 AI 键（共用 srs_field_ai_action.dart）。
// - AI 模块开着：文字 / 富文本字段有 `srs-field-ai-<字段名>`，图片 / 音频 / 开关字段没有；
// - AI 模块关着：一个都没有；
// - 没指派提供商时点它不开抽屉、不改字段（一个请求都不发）；
// - AI 结果换进字段模型后照常走检查器的自动保存（浏览页写入 → 撤销栈），不另开写库路径。
//
// 内存库；数据库读写一律放 tester.runAsync。
import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_inspector.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart'
    show SrsPreviewCommand;
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_action.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

/// AI 模块开关可控的测试应用模型。
class _AppModel extends SrsTestAppModel {
  _AppModel({required this.ai});

  final bool ai;

  @override
  ModuleVisibility get moduleVisibility => ModuleVisibility(<ModuleId>{
    for (final ModuleId m in ModuleId.values)
      if (ai || m != ModuleId.ai) m,
  });
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

/// 推进到内核往返都落地（连续 3 步没有在途的内核读 / 写命令）。
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  int quiet = 0;
  for (int i = 0; i < rounds || quiet < 3; i++) {
    if (i >= 400) fail('400 步内内核往返没有全部落地 ${SrsOpLedger.takeSummary()}');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    quiet = SrsOpLedger.inflightCount == 0 ? quiet + 1 : 0;
  }
}

SrsBrowseRow _row({required String cardId, required String noteId}) =>
    SrsBrowseRow(
      cardId: cardId,
      noteId: noteId,
      sortText: '食べる',
      deckName: 'Default',
      deckId: 'deck',
      noteTypeName: 'Lapis',
      templateName: 'Card 1',
      templateCount: 1,
      queue: null,
      dueInDays: null,
      flag: 0,
      isSuspended: false,
      isBuried: false,
      hasPendingDecision: false,
      cardCount: 1,
      tags: const <String>[],
      reps: 0,
      lapses: 0,
      intervalDays: null,
      difficulty: null,
      retention: null,
      addedAt: 0,
      modifiedAt: 0,
      lastReviewAt: null,
      fieldPreview: const <String>[],
      fieldPreviewNames: const <String>[],
      imageRef: null,
      audioRef: null,
      sourceKey: null,
      sourceKind: null,
      sourceData: null,
    );

/// 建一条 Lapis 笔记并单独挂上检查器的编辑页签；[saves] 收保存回调的（字段名, 值）。
Future<void> _pumpInspector(
  WidgetTester tester, {
  required bool ai,
  List<(String, String)>? saves,
}) async {
  final SrsTestClock clock = SrsTestClock();
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(clock: clock),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  final String noteId = (await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '食べる',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'to eat',
      },
    ),
  ))!;
  final String cardId = (await tester.runAsync(
    () => store.cardsOfNote(noteId),
  ))!.first.id;

  // 足够高：字段列表是懒构建的，所有字段一次都建出来。
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => _AppModel(ai: ai)),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(
            body: SrsBrowseInspector(
              row: _row(cardId: cardId, noteId: noteId),
              revision: 0,
              tab: SrsBrowseInspectorTab.edit,
              onTabChanged: (SrsBrowseInspectorTab _) {},
              showAnswer: false,
              onCommand: (SrsPreviewCommand _) {},
              onSaveField: (String id, String field, String value) async =>
                  saves?.add((field, value)),
              onSaveTags: (String id, List<String> b, List<String> a) async {},
              onOpenEditor: (String _) {},
              actions: SrsBrowseInspectorActions(
                onSuspend: () {},
                onFlag: () {},
                onMore: () {},
                suspended: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  expect(_key('srs-browse-field-MainDefinition'), findsOneWidget);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SrsOpLedger.reset();
  });

  testWidgets('AI 模块开着：检查器的文字字段带 AI 键，图片 / 音频 / 开关字段没有', (
    WidgetTester tester,
  ) async {
    await _pumpInspector(tester, ai: true);
    for (final String name in <String>['MainDefinition', 'Sentence', 'Hint']) {
      final Finder button = find.descendant(
        of: _key('srs-browse-field-$name'),
        matching: _key('srs-field-ai-$name'),
      );
      expect(button, findsOneWidget, reason: '$name 是文字字段，应有 AI 键');
    }
    for (final String name in <String>[
      'Picture',
      'ExpressionAudio',
      'IsClickCard',
    ]) {
      expect(_key('srs-browse-field-$name'), findsOneWidget);
      expect(_key('srs-field-ai-$name'), findsNothing, reason: '$name 不装文字');
    }
    await _unmount(tester);
  });

  testWidgets('AI 模块关着：检查器里一个 AI 键都没有', (WidgetTester tester) async {
    await _pumpInspector(tester, ai: false);
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('srs-field-ai-'),
      ),
      findsNothing,
    );
    await _unmount(tester);
  });

  testWidgets('没指派提供商：点 AI 键不开抽屉、不改字段、不写库', (WidgetTester tester) async {
    final List<(String, String)> saves = <(String, String)>[];
    await _pumpInspector(tester, ai: true, saves: saves);
    await tester.tap(_key('srs-field-ai-MainDefinition'));
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    expect(_key('srs-field-ai-run'), findsNothing, reason: '没有提供商就不该开抽屉');
    final SrsFieldEditor editor = tester.widget<SrsFieldEditor>(
      _key('srs-browse-field-MainDefinition'),
    );
    expect(editor.model.value, 'to eat');
    expect(saves, isEmpty);
    await _unmount(tester);
  });

  testWidgets('AI 结果换进字段模型后走检查器的自动保存（浏览页写入，可撤销）', (WidgetTester tester) async {
    final List<(String, String)> saves = <(String, String)>[];
    await _pumpInspector(tester, ai: true, saves: saves);
    final SrsFieldEditor editor = tester.widget<SrsFieldEditor>(
      _key('srs-browse-field-MainDefinition'),
    );
    // 与 runSrsFieldAiOnModel 采用结果时同一个写法。
    editor.model.reset('to consume <b>food</b>');
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    expect(saves, <(String, String)>[
      ('MainDefinition', 'to consume <b>food</b>'),
    ]);
    await _unmount(tester);
  });

  test('字段 AI 判据：只认装文字的字段', () {
    SrsFieldDef f(String name) => SrsFieldDef(id: name, name: name, ord: 0);
    expect(srsFieldAiEligible(f('MainDefinition')), isTrue);
    expect(srsFieldAiEligible(f('SentenceTranslation')), isTrue);
    expect(srsFieldAiEligible(f('Sentence')), isTrue);
    expect(srsFieldAiEligible(f('My notes')), isTrue);
    expect(srsFieldAiEligible(f('Picture')), isFalse);
    expect(srsFieldAiEligible(f('SentenceAudio')), isFalse);
    expect(srsFieldAiEligible(f('IsClickCard')), isFalse);
    expect(srsFieldAiEligible(f('Back image')), isFalse);
  });
}
