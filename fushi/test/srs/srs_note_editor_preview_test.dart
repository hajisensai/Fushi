// 笔记编辑页的反馈 #1 四件事（整页 widget 测试，内存库 + 纯文本卡面）：
// 1. 实时预览：宽窗右栏常驻、字段一改就重渲染；窄窗顶栏「预览」打开底部抽屉；
// 2. 结构化字段（词典排版）在排版里改文字，标签骨架原样；富文本高亮；
// 3. 字段名翻译 + ⓘ 展开说明（含制卡来源），未知字段显示原名；
// 4. 字段「AI 改写 / 补全」抽屉：结果替换 / 追加进草稿（请求经注入的假 runner）。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart'
    show SrsTemplatePreview;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

const String _kGlossary =
    '<div class="yomitan-glossary"><ol><li data-dictionary="大辞林">'
    '<i>(大辞林)</i> <span class="g" style="color: #c00;">かよう</span></li>'
    '</ol></div>';

String _fid(String name) => srsFushiCardFieldId(kSrsTestProfile, name);

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<SrsDbStore> _open(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = await _db(
    tester,
    () => openSrsTestStore(),
  );
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<String> _note(
  WidgetTester tester,
  SrsDbStore store,
  Map<String, String> fields,
) => _db(
  tester,
  () => store.createNote(
    noteTypeId: store.fushiCardNoteTypeId,
    fieldsById: <String, String>{
      for (final MapEntry<String, String> e in fields.entries)
        _fid(e.key): e.value,
    },
  ),
);

Future<void> _pump(
  WidgetTester tester,
  SrsDbStore store,
  String noteId, {
  required Size size,
  bool apple = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
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
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: SrsNoteEditorPage(noteId: noteId),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Finder _inPreview(Finder f) =>
    find.descendant(of: _key('srs-note-preview'), matching: f);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('填空编号：升序去重', () {
    expect(
      srsClozeOrdinals(<String>['{{c2::a}} {{c1::b}}', '{{c2::c}}', 'x']),
      <int>[1, 2],
    );
    expect(srsClozeOrdinals(<String>['plain']), isEmpty);
  });

  testWidgets('原生混合预览的判据与复习页一致：模板改过就退回整面 WebView', (WidgetTester tester) async {
    final SrsDbStore store = await _open(tester);
    final SrsNoteTypeView type = (await _db(
      tester,
      () => store.noteType(store.fushiCardNoteTypeId),
    ))!;
    final Map<String, String> values = <String, String>{
      _fid('Term'): '食べる',
      _fid('Media'): '[sound:clip.mp4]',
    };
    final SrsTemplateDef tpl = type.templates.first;
    expect(
      srsNotePreviewNativeFushiCard(
        type: type,
        template: tpl,
        valuesById: values,
      ),
      isNotNull,
      reason: '内置模板 + 原生画得全的片段 → 原生混合渲染',
    );
    final SrsTemplateDef edited = SrsTemplateDef(
      id: tpl.id,
      name: tpl.name,
      ord: tpl.ord,
      front: '${tpl.front}<p>x</p>',
      back: tpl.back,
    );
    expect(
      srsNotePreviewNativeFushiCard(
        type: type,
        template: edited,
        valuesById: values,
      ),
      isNull,
      reason: '模板改过 → 整面 WebView（复习页同样如此）',
    );
    expect(
      srsNotePreviewNativeFushiCard(
        type: type,
        template: tpl,
        valuesById: <String, String>{
          ...values,
          _fid('Media'): '<img src="https://example.com/a.png">',
        },
      ),
      isNull,
      reason: '远程图片原生画不了 → 整面 WebView',
    );
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 宽窗：右栏常驻预览，字段改动即时反映', (WidgetTester tester) async {
      final SrsDbStore store = await _open(tester);
      final String note = await _note(tester, store, <String, String>{
        'Term': '食べる',
        'IsWordAndSentenceCard': 'x',
      });
      await _pump(
        tester,
        store,
        note,
        size: const Size(1280, 1000),
        apple: apple,
      );
      expect(
        find.descendant(
          of: find.byKey(SrsAdaptiveSections.secondaryPaneKey),
          matching: _key('srs-note-preview'),
        ),
        findsOneWidget,
      );
      expect(_key('srs_note_preview'), findsNothing, reason: '宽窗不需要顶栏预览按钮');
      // BUG-3732：模板未改的 Fushi 卡片与复习页同一个原生混合卡面，不退回整面 WebView。
      expect(_inPreview(_key('srs-note-preview-native')), findsOneWidget);
      expect(_inPreview(find.textContaining('食べる')), findsWidgets);
      await tester.enterText(
        find.descendant(
          of: _key('srs-field-input-Term'),
          matching: find.byType(EditableText),
        ),
        '飲む',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester, rounds: 3);
      expect(_inPreview(find.textContaining('飲む')), findsWidgets);
      expect(_inPreview(find.textContaining('食べる')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('[$ds] 窄窗：顶栏「预览」打开底部抽屉', (WidgetTester tester) async {
      final SrsDbStore store = await _open(tester);
      final String note = await _note(tester, store, <String, String>{
        'Term': '食べる',
        'IsWordAndSentenceCard': 'x',
      });
      await _pump(
        tester,
        store,
        note,
        size: const Size(390, 844),
        apple: apple,
      );
      expect(_key('srs-note-preview'), findsNothing);
      await tester.tap(_key('srs_note_preview').first);
      await _settle(tester);
      expect(_key('srs-note-preview-sheet'), findsOneWidget);
      expect(_inPreview(find.textContaining('食べる')), findsWidgets);
      await _unmount(tester);
    });
  }

  testWidgets('字段名翻译 + ⓘ 展开说明与制卡来源', (WidgetTester tester) async {
    final SrsDbStore store = await _open(tester);
    final String note = await _note(tester, store, <String, String>{
      'Term': '食べる',
    });
    await _pump(tester, store, note, size: const Size(1280, 1600));
    final Text label = tester.widget<Text>(
      _key('srs-field-label-TermFurigana'),
    );
    expect(label.textSpan!.toPlainText(), contains('TermFurigana'));
    expect(
      label.textSpan!.toPlainText(),
      contains(t.srs_field_info_expression_furigana_name),
    );
    expect(_key('srs-field-help-panel-TermFurigana'), findsNothing);
    await tester.tap(_key('srs-field-help-TermFurigana'));
    await _settle(tester, rounds: 4);
    expect(_key('srs-field-help-panel-TermFurigana'), findsOneWidget);
    expect(
      find.text(t.srs_field_info_expression_furigana_desc),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('srs-field-help-panel-TermFurigana'),
        matching: find.text(t.srs_field_info_raw_name(name: 'TermFurigana')),
      ),
      findsOneWidget,
    );
    // 内置 Fushi 卡片的这个字段有制卡映射：说明里给出「制卡时自动填入」一句。
    expect(
      find.descendant(
        of: _key('srs-field-help-panel-TermFurigana'),
        matching: find.byType(Text),
      ),
      findsNWidgets(3),
    );
    await _unmount(tester);
  });

  testWidgets('结构化字段在排版里改文字：只换那段文字，标签骨架原样', (WidgetTester tester) async {
    final SrsDbStore store = await _open(tester);
    final String note = await _note(tester, store, <String, String>{
      'Term': '通う',
      'MainDefinition': _kGlossary,
    });
    await _pump(tester, store, note, size: const Size(1280, 2600));
    await tester.tap(_key('srs-field-parts-MainDefinition'));
    await _settle(tester, rounds: 4);
    expect(_key('srs-field-layout-MainDefinition-0'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: _key('srs-field-layout-MainDefinition-0'),
        matching: find.byType(EditableText),
      ),
      '(大辞林) かよう（通う）',
    );
    await tester.pump();
    await tester.tap(_key('srs_note_save').first);
    await _settle(tester);
    final String saved = (await _db(
      tester,
      () => store.note(note),
    ))!.field(_fid('MainDefinition'));
    expect(saved, _kGlossary.replaceFirst('かよう<', 'かよう（通う）<'));
    await _unmount(tester);
  });

  testWidgets('字段 AI 抽屉：生成 → 替换 / 追加', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<(AiSrsFieldTask, String)> calls = <(AiSrsFieldTask, String)>[];
    String? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () async {
                    result = await showSrsFieldAiSheet(
                      context,
                      fieldLabel: 'Sentence translation',
                      fieldName: 'SentenceTranslation',
                      current: 'old',
                      run: (AiSrsFieldTask task, String instruction) async {
                        calls.add((task, instruction));
                        return const AiSrsFieldSuggestion(
                          value: 'I go <b>every day</b>.',
                        );
                      },
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(_key('open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(calls.single.$1, AiSrsFieldTask.translate, reason: '翻译字段默认翻译');
    expect(find.text('I go every day.'), findsOneWidget);
    await tester.tap(_key('srs-field-ai-append'));
    await tester.pumpAndSettle();
    expect(result, 'old<br>I go <b>every day</b>.');
  });

  test('AI 结果替换 / 追加（纯函数）', () {
    expect(srsApplyFieldAi('a', 'b', append: false), 'b');
    expect(srsApplyFieldAi('a', 'b', append: true), 'a<br>b');
    expect(srsApplyFieldAi(' ', 'b', append: true), 'b');
    expect(srsDefaultFieldAiTask('MainDefinition'), AiSrsFieldTask.define);
    expect(srsDefaultFieldAiTask('Sentence'), AiSrsFieldTask.rewrite);
  });

  testWidgets('预览渲染纯函数：按当前值出卡；空正面给空卡', (WidgetTester tester) async {
    final SrsDbStore store = await _open(tester);
    final SrsNoteTypeView type = (await _db(
      tester,
      () => store.noteType(store.fushiCardNoteTypeId),
    ))!;
    final SrsTemplatePreview r = srsRenderNotePreview(
      type: type,
      template: type.templates.first,
      valuesById: <String, String>{
        _fid('Term'): '走る',
        _fid('IsWordAndSentenceCard'): 'x',
      },
    );
    expect(r.error, isNull);
    expect(r.card!.question, contains('走る'));
    expect(kSrsBuiltinFushiCardKey, type.builtinKey);
  });
}
