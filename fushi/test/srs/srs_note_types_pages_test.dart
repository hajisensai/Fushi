// 复习的笔记类型管理页 / 模板编辑器 / 更改笔记类型：关键流程，MD3 与 Apple 两套设计系统。
//
// 内存库 + 确定性假排程内核；卡面换成纯文本实现（widget 测试里没有 WebView）。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_change_note_type_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_info_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_type_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart' show srsFieldDisplayName;
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

/// 让真异步（drift）与帧都推进。
Future<void> _settle(WidgetTester tester, {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  required Widget page,
  Widget Function(BuildContext, SrsCardFace)? faceBuilder,
}) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsCardFaceBuilderProvider.overrideWithValue(
          faceBuilder ??
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
          home: page,
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// 计数卡面：每次 initState（= 卡面被新建一次）加一。
int _faceInits = 0;

class _CountingFace extends StatefulWidget {
  const _CountingFace();

  @override
  State<_CountingFace> createState() => _CountingFaceState();
}

class _CountingFaceState extends State<_CountingFace> {
  @override
  void initState() {
    super.initState();
    _faceInits++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// 文本输入对话框：填字、点确认。
Future<void> _submitTextDialog(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(EditableText).last, text);
  await tester.pump();
  await tester.tap(find.text(t.dialog_ok).last);
  await _settle(tester);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 笔记类型页：列出类型与笔记数，内置类型标注、点行进编辑页', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'My basic'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _db(
        tester,
        () => store.createNote(
          noteTypeId: nt,
          fieldsById: <String, String>{v.fields[0].id: '猫'},
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsNoteTypesPage(),
      );
      expect(
        isGlassDesign(tester.element(find.byType(SrsNoteTypesPage))),
        apple,
      );
      final Finder row = find.byKey(ValueKey<String>('srs-note-type-$nt'));
      expect(row, findsOneWidget);
      // 摘要逐段渲染（SrsMetaLine：段内不断行），按段断言。
      for (final String segment in SrsMetaLine.split(
        t.srs_note_types_summary(notes: 1, fields: 2, cards: 1),
      )) {
        expect(
          find.descendant(of: row, matching: find.textContaining(segment)),
          findsOneWidget,
          reason: segment,
        );
      }
      final Finder lapis = find.byKey(
        ValueKey<String>('srs-note-type-${store.lapisNoteTypeId}'),
      );
      expect(
        find.descendant(
          of: lapis,
          matching: find.textContaining(t.srs_note_types_builtin),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('My basic'));
      await _settle(tester);
      expect(find.byType(SrsNoteTypeEditorPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-field-Front')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-template-Card 1')),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 编辑页：加字段写库；删有内容的字段先确认，确认后定义标删除', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _db(
        tester,
        () => store.createNote(
          noteTypeId: nt,
          fieldsById: <String, String>{
            v.fields[0].id: 'front',
            v.fields[1].id: 'back',
          },
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsNoteTypeEditorPage(noteTypeId: nt),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('srs-note-type-add-field')),
      );
      await _settle(tester);
      await _submitTextDialog(tester, 'Extra');
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-field-Extra')),
        findsOneWidget,
      );
      expect(
        (await _db(
          tester,
          () => store.noteType(nt),
        ))!.fields.map((SrsFieldDef f) => f.name),
        <String>['Front', 'Back', 'Extra'],
      );

      // 删 Back：行内菜单 → 删除 → 确认框给出有内容的笔记数。
      final Finder backRow = find.byKey(
        const ValueKey<String>('srs-note-type-field-Back'),
      );
      await tester.tap(
        find.descendant(
          of: backRow,
          matching: find.byWidgetPredicate((Widget w) => w is PopupMenuButton),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text(t.srs_note_types_field_delete).last);
      await _settle(tester);
      expect(
        find.text(t.srs_note_types_field_delete_confirm(name: 'Back', n: 1)),
        findsOneWidget,
      );
      await tester.tap(find.text(t.srs_note_types_field_delete).last);
      await _settle(tester);
      final SrsNoteTypeView after = (await _db(
        tester,
        () => store.noteType(nt),
      ))!;
      expect(after.fields.map((SrsFieldDef f) => f.name), <String>[
        'Front',
        'Extra',
      ]);
      expect(after.templates.single.back, isNot(contains(v.fields[1].id)));
      await _unmount(tester);
    });

    testWidgets('[$ds] 模板编辑器：预览用真实笔记；改正面保存写库；未知字段报错不保存', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _db(
        tester,
        () => store.createNote(
          noteTypeId: nt,
          fieldsById: <String, String>{
            v.fields[0].id: '猫',
            v.fields[1].id: 'cat',
          },
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsTemplateEditorPage(
          noteTypeId: nt,
          templateId: v.templates.single.id,
          initialTab: SrsTemplateEditorTab.front,
        ),
      );
      final Finder face = find.byKey(
        const ValueKey<String>('srs-face-question'),
      );
      expect(face, findsOneWidget);
      expect((tester.widget(face) as Text).data, '猫');
      expect(find.text('{{Front}}'), findsOneWidget, reason: '编辑器按字段名显示');

      await tester.enterText(find.byType(EditableText).first, '{{Back}}');
      await _settle(tester);
      expect((tester.widget(face) as Text).data, 'cat', reason: '实时预览');
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_template_save')).first,
      );
      await _settle(tester);
      expect(
        (await _db(tester, () => store.noteType(nt)))!.templates.single.front,
        '{{fld:${v.fields[1].id}}}',
      );

      await tester.enterText(find.byType(EditableText).first, '{{Nope}}');
      await _settle(tester);
      expect(
        find.textContaining(t.srs_note_types_template_error(error: '').trim()),
        findsWidgets,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_template_save')).first,
      );
      await _settle(tester);
      expect(
        (await _db(tester, () => store.noteType(nt)))!.templates.single.front,
        '{{fld:${v.fields[1].id}}}',
        reason: '模板有错误时不写库',
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 模板编辑器可视化页：代码模板 → 按字段生成 → 预览 → 删块 → 保存写库且能读回布局', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _db(
        tester,
        () => store.createNote(
          noteTypeId: nt,
          fieldsById: <String, String>{
            v.fields[0].id: '猫',
            v.fields[1].id: 'cat',
          },
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsTemplateEditorPage(
          noteTypeId: nt,
          templateId: v.templates.single.id,
        ),
      );
      // 默认打开可视化页；现有模板是代码写的 → 先给「转成可视化」。
      expect(
        find.byKey(const ValueKey<String>('srs-visual-convert')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-visual-generate')),
      );
      await _settle(tester);
      // 模板已有内容 → 确认替换。
      await tester.tap(find.text(t.srs_visual_generate).last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-visual-block-b1')),
        findsOneWidget,
      );
      final Finder question = find.byKey(
        const ValueKey<String>('srs-face-question'),
      );
      expect((tester.widget(question) as Text).data, '猫', reason: '正面放词条');

      // 换到背面：重复正面 + 分隔线 + 其余字段（未知字段带字段名小标题）。
      await tester.tap(find.text(t.srs_note_types_side_back).first);
      await _settle(tester);
      final Finder answer = find.byKey(
        const ValueKey<String>('srs-face-answer'),
      );
      expect((tester.widget(answer) as Text).data, contains('cat'));
      final Finder del = find.byKey(
        const ValueKey<String>('srs-visual-delete-b3'),
      );
      await tester.ensureVisible(del);
      await tester.tap(del);
      await _settle(tester);
      expect((tester.widget(answer) as Text).data, isNot(contains('cat')));

      await tester.tap(
        find.byKey(const ValueKey<String>('srs_template_save')).first,
      );
      await _settle(tester);
      final SrsTemplateDef saved = (await _db(
        tester,
        () => store.noteType(nt),
      ))!.templates.single;
      expect(saved.front, startsWith(kSrsVisualMarkerPrefix));
      expect(saved.front, contains('{{fld:${v.fields[0].id}}}'));
      expect(saved.back, isNot(contains('fld:${v.fields[1].id}')));
      final List<SrsVisualBlock> back = srsParseVisualMarker(saved.back)!;
      expect(back.map((SrsVisualBlock b) => b.kind), <SrsVisualBlockKind>[
        SrsVisualBlockKind.frontSide,
        SrsVisualBlockKind.divider,
      ]);
      await _unmount(tester);
    });

    testWidgets('[$ds] 内置 Lapis 类型：概览卡、开关字段折叠组、模板行副标题列出正面字段', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsNoteTypeEditorPage(noteTypeId: store.lapisNoteTypeId),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-overview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-flag-fields')),
        findsOneWidget,
      );
      final SrsNoteTypeView lapis = (await _db(
        tester,
        () => store.noteType(store.lapisNoteTypeId),
      ))!;
      final SrsTemplateDef tpl = lapis.templates.first;
      final List<SrsFieldDef> front = srsFieldsShownOnSide(lapis, tpl.front);
      expect(front, isNotEmpty);
      final Finder row = find.byKey(
        ValueKey<String>('srs-note-type-template-${tpl.name}'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining(srsFieldDisplayName(front.first)),
        ),
        findsWidgets,
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 编辑页：没被任何模板引用的新字段带「未上卡面」标签', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsNoteTypeEditorPage(noteTypeId: nt),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-field-unused-Front')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-note-type-add-field')),
      );
      await _settle(tester);
      await _submitTextDialog(tester, 'Extra');
      expect(
        find.byKey(const ValueKey<String>('srs-note-type-field-unused-Extra')),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] Lapis 模板编辑页可视化 tab：内置类型出内置说明而不是转换说明', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final SrsNoteTypeView lapis = (await _db(
        tester,
        () => store.noteType(store.lapisNoteTypeId),
      ))!;
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsTemplateEditorPage(
          noteTypeId: store.lapisNoteTypeId,
          templateId: lapis.templates.first.id,
        ),
      );
      final Finder note = find.byKey(
        const ValueKey<String>('srs-visual-builtin-note'),
      );
      expect(note, findsOneWidget);
      expect(
        (tester.widget(note) as Text).data,
        t.srs_visual_builtin_other_note,
      );
      expect(find.text(t.srs_visual_builtin_title), findsOneWidget);
      expect(find.text(t.srs_visual_convert_title), findsNothing);
      await _unmount(tester);
    });

    testWidgets('[$ds] 模板编辑器：正面改成语法错误再改回，卡面不被拆掉重建', (
      WidgetTester tester,
    ) async {
      _faceInits = 0;
      final SrsDbStore store = await _openStore(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _db(
        tester,
        () => store.createNote(
          noteTypeId: nt,
          fieldsById: <String, String>{
            v.fields[0].id: '猫',
            v.fields[1].id: 'cat',
          },
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        faceBuilder: (BuildContext context, SrsCardFace face) =>
            const _CountingFace(),
        page: SrsTemplateEditorPage(
          noteTypeId: nt,
          templateId: v.templates.single.id,
          initialTab: SrsTemplateEditorTab.front,
        ),
      );
      expect(_faceInits, 1);
      // 引用不存在的字段：模板渲染报错（与「未知字段报错不保存」同一错误路径）。
      await tester.enterText(find.byType(EditableText).first, '{{Nope}}');
      await tester.pump(const Duration(milliseconds: 250));
      await _settle(tester);
      expect(
        find.textContaining(t.srs_note_types_template_error(error: '').trim()),
        findsWidgets,
        reason: '确实进了错误态',
      );
      await tester.enterText(find.byType(EditableText).first, '{{Back}}');
      await tester.pump(const Duration(milliseconds: 250));
      await _settle(tester);
      expect(_faceInits, 1, reason: '错误态只盖提示层，卡面不拆');
      await _unmount(tester);
    });

    testWidgets('[$ds] 字段说明：内置字段显示人话名字与内置说明；自建字段写说明保存写库、编辑页字段行显示', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsFieldInfoPage(
          noteTypeId: store.lapisNoteTypeId,
          fieldId: srsLapisFieldId(store.profileUid, 'ExpressionReading'),
        ),
      );
      expect(find.text(t.srs_field_info_expression_reading_name), findsWidgets);
      expect(
        find.text(t.srs_field_info_raw_name(name: 'ExpressionReading')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('srs-field-info-builtin-description'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.srs_field_info_mining(slot: t.handlebar_reading)),
        findsOneWidget,
        reason: '制卡时自动填入读音',
      );
      await _unmount(tester);

      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsFieldInfoPage(noteTypeId: nt, fieldId: v.fields[1].id),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('srs-field-info-description-input'),
          ),
          matching: find.byType(EditableText),
        ),
        '中文释义',
      );
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-field-info-save')).first,
      );
      await _settle(tester);
      expect(
        (await _db(tester, () => store.noteType(nt)))!.fields[1].description,
        '中文释义',
      );
      await _unmount(tester);

      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsNoteTypeEditorPage(noteTypeId: nt),
      );
      expect(find.textContaining('中文释义'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('[$ds] 更改笔记类型：编辑页类型行 → 映射页（默认按名字）→ 确认 → 卡片带着复习历史过去', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String to = await _db(
        tester,
        // 名字排在内置「Fushi Card」之前：映射页默认选列表里第一个目标类型。
        () => store.createStockNoteType(SrsStockNoteType.basic, 'A Target'),
      );
      final SrsNoteTypeView vt = (await _db(tester, () => store.noteType(to)))!;
      // 目标类型加一个与 Lapis 同名的字段，默认映射按名字对上。
      await _db(
        tester,
        () => store.renameField(to, vt.fields[0].id, 'Expression'),
      );
      final String note = await _db(
        tester,
        () => store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): '犬',
          },
        ),
      );
      final String oldCard = (await _db(
        tester,
        () => store.cardsOfNote(note),
      )).single.id;
      final SrsReviewLog log = await _db(
        tester,
        () => store.answer(oldCard, 3),
      );

      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsNoteEditorPage(noteId: note),
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-note-type-row')));
      await _settle(tester, rounds: 20);
      expect(find.byType(SrsChangeNoteTypePage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('srs-change-type-field-Expression'),
          ),
          matching: find.text('← Expression'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-change-type-unused')),
        findsOneWidget,
        reason: 'Lapis 其余字段不会带过去，要提示',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_change_type_apply')).first,
      );
      await _settle(tester);
      await tester.tap(find.text(t.srs_change_type_apply).last);
      await _settle(tester, rounds: 20);
      expect(find.byType(SrsChangeNoteTypePage), findsNothing);

      final SrsNoteView n = (await _db(tester, () => store.note(note)))!;
      expect(n.noteTypeId, to);
      expect(n.field(vt.fields[0].id), '犬');
      final String newCard = SrsIds.card(note, vt.templates.single.id, 0);
      final SrsCardCacheRow c = (await _db(
        tester,
        () => store.cardRow(newCard),
      ))!;
      expect(c.hidden, isFalse);
      expect(c.lastLogId, log.id);
      // 编辑页重读后显示新类型。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-note-type-row')),
          matching: find.text('A Target'),
        ),
        findsOneWidget,
      );
      await _unmount(tester);
    });
  }

  test('srsFieldsShownOnSide：条件段不算、过滤器算、按出现位置排序', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final String nt = await store.createStockNoteType(
      SrsStockNoteType.basic,
      'B',
    );
    final SrsNoteTypeView v = (await store.noteType(nt))!;
    final String a = v.fields[0].id;
    final String b = v.fields[1].id;
    expect(
      srsFieldsShownOnSide(
        v,
        '{{#fld:$a}}x{{/fld:$a}}{{furigana:fld:$b}}{{fld:$a}}',
      ).map((SrsFieldDef x) => x.id),
      <String>[b, a],
    );
    expect(
      srsFieldsShownOnSide(v, '{{#fld:$a}}x{{/fld:$a}}'),
      isEmpty,
      reason: '只有条件段 = 没显示',
    );
  });

  testWidgets('[Apple] 牌组列表的「笔记类型」入口打开管理页', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _pumpPage(
      tester,
      store: store,
      apple: true,
      page: const SrsDeckListPage(),
    );
    await tester.tap(find.byKey(const ValueKey<String>('srs_note_types')));
    await _settle(tester);
    expect(find.byType(SrsNoteTypesPage), findsOneWidget);
    await _unmount(tester);
  });
}
