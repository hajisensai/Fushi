// 笔记编辑器向 Anki 靠拢的三块（纯函数 + 整页 widget 测试，MD3 与 Apple 两套设计系统）：
// 1. 富文本里直接加注音（ruby）：选字 → 注音按钮 → 填读音，写成 <ruby>…<rt>…</rt></ruby>；
// 2. 词典排版字段所见即所得：「编辑文字」把预览换成原生排出的版面，直接在排版里改字，标签不动；
// 3. 可视化模板里块的间距 / 图片大小可调，编译进模板正文、注释能读回。
// 产物只进草稿：没点保存前库里不变。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rich_text_controller.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/srs/srs_field_markup.dart';
import 'package:fushi/src/srs/srs_html_layout.dart';
import 'package:fushi/src/srs/srs_html_text_parts.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_rich_format.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// Yomitan 结构化释义：列表 + 斜体词典名 + 内联样式的词条 + 第二条带 <br> 的释义。
const String _kGlossary =
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '<li data-dictionary="大辞林"><i>(大辞林)</i> '
    '<span class="gloss-sc-span" style="font-weight: bold; color: #c00;">かよう</span>'
    '</li><li data-dictionary="明鏡">行き来する<br>往復する</li></ol></div>';

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

Future<void> _pump(
  WidgetTester tester,
  SrsDbStore store,
  Widget page, {
  bool apple = false,
  Size size = const Size(1100, 2600),
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
          home: page,
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

Future<String> _field(
  WidgetTester tester,
  SrsDbStore store,
  String note,
  String name,
) async => (await _db(tester, () => store.note(note)))!.field(_fid(name));

EditableText _editable(WidgetTester tester, String key) =>
    tester.widget<EditableText>(
      find.descendant(of: _key(key), matching: find.byType(EditableText)),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('注音（ruby）纯函数', () {
    test('解析 <ruby>：基字带注音组，未改动原样往返', () {
      const String html =
          '<ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>を<b>読</b>む';
      final SrsRichFormatDoc doc = srsParseRichFormatHtml(html)!;
      expect(doc.text, '漢字を読む');
      expect(doc.formats[0].ruby?.reading, 'かんじ');
      expect(doc.formats[1].ruby, doc.formats[0].ruby);
      expect(doc.formats[2].ruby, isNull);
      expect(srsEditorFieldKindOf('Sentence', html), SrsFieldKind.rich);
      final SrsRichTextController c = SrsRichTextController.tryParse(html)!;
      expect(c.html, html);
      c.dispose();
    });

    test('一个 ruby 里多组 + 基字带格式；序列化回 ruby 写法', () {
      final SrsRichFormatDoc doc = srsParseRichFormatHtml(
        '<ruby><b>漢</b><rt>かん</rt>字<rt>じ</rt></ruby>',
      )!;
      expect(doc.text, '漢字');
      expect(doc.formats[0].ruby?.reading, 'かん');
      expect(doc.formats[1].ruby?.reading, 'じ');
      expect(doc.formats[0].bold, isTrue);
      expect(
        srsRichFormatToHtml(doc.text, doc.formats),
        '<ruby><b>漢</b><rt>かん</rt></ruby><ruby>字<rt>じ</rt></ruby>',
      );
    });

    test('子集之外：rt 里带标签 / ruby 里换行 → 不当富文本', () {
      expect(srsParseRichFormatHtml('<ruby>a<rt><b>x</b></rt></ruby>'), isNull);
      expect(srsParseRichFormatHtml('<ruby>a<br>b<rt>x</rt></ruby>'), isNull);
      expect(srsParseRichFormatHtml('<ruby>a<rt>x</ruby>'), isNull);
    });

    test('控制器：选字加注音、组中打字归组、组边打字不带注音、清空读音去注音', () {
      final SrsRichTextController c = SrsRichTextController.tryParse('図書館に通う')!;
      expect(c.setRuby(const TextRange(start: 0, end: 3), 'としょかん'), isTrue);
      expect(c.html, '<ruby>図書館<rt>としょかん</rt></ruby>に通う');
      // 组中间插字：归进这组。
      c.value = const TextEditingValue(
        text: '図書X館に通う',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(c.html, '<ruby>図書X館<rt>としょかん</rt></ruby>に通う');
      // 组尾后面打字：不带注音。
      c.value = const TextEditingValue(
        text: '図書X館Yに通う',
        selection: TextSelection.collapsed(offset: 5),
      );
      expect(c.html, '<ruby>図書X館<rt>としょかん</rt></ruby>Yに通う');
      c.selection = const TextSelection.collapsed(offset: 2);
      expect(c.activeRubyRange, const TextRange(start: 0, end: 4));
      expect(c.activeRubyReading, 'としょかん');
      // 换行不能注音。
      c.value = const TextEditingValue(
        text: '図書X館Y\nに通う',
        selection: TextSelection.collapsed(offset: 6),
      );
      expect(c.setRuby(const TextRange(start: 4, end: 7), 'x'), isFalse);
      expect(c.setRuby(const TextRange(start: 0, end: 4), ''), isTrue);
      expect(c.hasRuby, isFalse);
      expect(c.html, '図書X館Y<br>に通う');
      c.dispose();
    });
  });

  group('词典排版版面纯函数', () {
    test('列表 / 分隔 / 外观：段落按块分，词典名斜体、词条加粗带色', () {
      final SrsHtmlTextParts parts = srsSplitHtmlText(_kGlossary);
      final SrsLayoutBlock root = srsLayoutHtml(parts);
      final List<SrsLayoutParagraph> paras = srsLayoutParagraphs(root);
      expect(paras, hasLength(2));
      final List<SrsLayoutSeg> first = paras[0].segs;
      expect(first.map((SrsLayoutSeg s) => s.text).join(), '(大辞林) かよう');
      expect(first[0].look.italic, isTrue);
      expect(first[1].part, isNull, reason: '词典名与词条之间的空白是分隔');
      expect(first[2].look.bold, isTrue);
      expect(first[2].look.color, 0xFFCC0000);
      expect(
        paras[1].segs.map((SrsLayoutSeg s) => s.text).join(),
        '行き来する\n往復する',
      );
      // 列表项符号按 <ol> 编号。
      final SrsLayoutBlock list =
          (root.children.single as SrsLayoutBlock).children.single
              as SrsLayoutBlock;
      final List<String?> markers = <String?>[
        for (final SrsLayoutBox b in list.children)
          (b as SrsLayoutBlock).marker,
      ];
      expect(markers, <String>['1.', '2.']);
    });

    test('style / script 内容不进版面，display:none 隐藏', () {
      final SrsLayoutBlock root = srsLayoutHtml(
        srsSplitHtmlText(
          '<style>.a>b{color:red}</style><div>甲<span style="display:none">乙</span></div>'
          '<script>if (a<b) {}</script>',
        ),
      );
      final List<SrsLayoutParagraph> paras = srsLayoutParagraphs(root);
      expect(paras, hasLength(1));
      expect(paras.single.segs.single.text, '甲');
    });

    test('分段改字：段内改只换那段；跨分隔删除保留分隔', () {
      final List<SrsLayoutSeg> segs = srsLayoutParagraphs(
        srsLayoutHtml(srsSplitHtmlText(_kGlossary)),
      ).first.segs;
      final List<String> texts = <String>[
        for (final SrsLayoutSeg s in segs) s.text,
      ];
      final ({List<String> texts, int caret}) a = srsApplySegmentEdit(
        segs,
        texts,
        '(大辞林) かよう（通う）',
        13,
      )!;
      expect(a.texts, <String>['(大辞林)', ' ', 'かよう（通う）']);
      expect(a.caret, 13);
      // 选中「林) か」删掉：两段各删一截，中间的空白分隔留着。
      final ({List<String> texts, int caret}) b = srsApplySegmentEdit(
        segs,
        texts,
        '(大辞よう',
        3,
      )!;
      expect(b.texts, <String>['(大辞', ' ', 'よう']);
      expect(b.caret, 3);
      final SrsHtmlTextParts parts = srsSplitHtmlText(_kGlossary);
      expect(
        parts.join(<String>['(大辞', 'よう', parts.texts[2], parts.texts[3]]),
        _kGlossary.replaceFirst('(大辞林)', '(大辞').replaceFirst('かよう', 'よう'),
      );
    });
  });

  group('可视化模板间距 / 图片大小纯函数', () {
    const SrsVisualCompileContext ctx = SrsVisualCompileContext(
      fieldNameById: <String, String>{'f1': 'Picture'},
    );

    test('默认值的编译结果不变（旧模板不会被判成手改过）', () {
      final String body = srsCompileVisualBody(const <SrsVisualBlock>[
        SrsVisualBlock(id: 'b1', kind: SrsVisualBlockKind.field, fieldId: 'f1'),
        SrsVisualBlock(id: 'b2', kind: SrsVisualBlockKind.divider),
      ], ctx);
      expect(body, contains('margin:0.45em 0'));
      expect(body, contains('margin:0.9em 0'));
      expect(body, isNot(contains('<style>')));
      expect(body, isNot(contains('fv-img')));
    });

    test('间距与图片宽度编译进正文，注释读回', () {
      const List<SrsVisualBlock> blocks = <SrsVisualBlock>[
        SrsVisualBlock(
          id: 'b1',
          kind: SrsVisualBlockKind.field,
          fieldId: 'f1',
          spacing: SrsVisualSpacing.loose,
          imageSize: SrsVisualImageSize.medium,
        ),
        SrsVisualBlock(
          id: 'b2',
          kind: SrsVisualBlockKind.divider,
          spacing: SrsVisualSpacing.none,
        ),
      ];
      final String side = srsCompileVisualSide(blocks, ctx);
      expect(side, contains('class="fv-block fv-img-50"'));
      expect(side, contains('margin:0.9em 0'));
      expect(side, contains('margin:0em 0'));
      expect(
        side,
        contains(
          '<style>.fushi-visual .fv-img-50 img{max-width:50%;width:50%;'
          'height:auto}</style>',
        ),
      );
      expect(side, isNot(contains('}}height')), reason: '不产生模板标签结尾');
      final SrsVisualSideState state = srsReadVisualSide(side, ctx);
      expect(state.edited, isFalse);
      expect(state.blocks![0].spacing, SrsVisualSpacing.loose);
      expect(state.blocks![0].imageSize, SrsVisualImageSize.medium);
      expect(state.blocks![1].spacing, SrsVisualSpacing.none);
    });
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 富文本加注音：选字 → 注音按钮 → 读音，上方显示注音，保存写 ruby', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _open(tester);
      final String note = await _note(tester, store, <String, String>{
        'Expression': '通う',
        'Sentence': '図書館に通う',
      });
      await _pump(
        tester,
        store,
        SrsNoteEditorPage(noteId: note),
        apple: apple,
        size: const Size(700, 2600),
      );
      await tester.tap(_key('srs-field-input-Sentence'));
      await _settle(tester, rounds: 4);
      final TextEditingController c = _editable(
        tester,
        'srs-field-input-Sentence',
      ).controller;
      // 没选字：只给提示，不弹框。
      c.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      await tester.tap(_key('srs-format-ruby-Sentence'));
      await _settle(tester, rounds: 4);
      expect(find.text(t.srs_note_furigana_reading(base: '図書館')), findsNothing);

      c.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();
      await tester.tap(_key('srs-format-ruby-Sentence'));
      await _settle(tester, rounds: 6);
      expect(
        find.text(t.srs_note_furigana_reading(base: '図書館')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(EditableText).last, 'としょかん');
      await tester.pump();
      await tester.tap(find.text(t.dialog_ok).last);
      await _settle(tester, rounds: 6);
      expect(_key('srs-ruby-preview-Sentence'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('srs-ruby-Sentence-0'),
          matching: find.text('としょかん'),
        ),
        findsOneWidget,
        reason: '读音画在基字上方',
      );
      // 只进草稿：没保存前库里不变。
      expect(await _field(tester, store, note, 'Sentence'), '図書館に通う');

      // 点上方的注音改读音。
      await tester.tap(_key('srs-ruby-Sentence-0'));
      await _settle(tester, rounds: 6);
      await tester.enterText(find.byType(EditableText).last, 'としょ');
      await tester.pump();
      await tester.tap(find.text(t.dialog_ok).last);
      await _settle(tester, rounds: 6);

      await tester.tap(_key('srs_note_save').first);
      await _settle(tester);
      expect(
        await _field(tester, store, note, 'Sentence'),
        '<ruby>図書館<rt>としょ</rt></ruby>に通う',
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 词典排版所见即所得：在版面里改字，标签骨架原样，保存才落库', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _open(tester);
      final String note = await _note(tester, store, <String, String>{
        'Expression': '通う',
        'MainDefinition': _kGlossary,
      });
      await _pump(tester, store, SrsNoteEditorPage(noteId: note), apple: apple);
      expect(_key('srs-field-preview-MainDefinition'), findsOneWidget);
      await tester.ensureVisible(_key('srs-field-parts-MainDefinition'));
      await tester.tap(_key('srs-field-parts-MainDefinition'));
      await _settle(tester, rounds: 4);
      // 预览位置换成版面：两条释义各是一个段落，列表编号画出来。
      expect(_key('srs-field-preview-MainDefinition'), findsNothing);
      expect(_key('srs-field-layout-MainDefinition'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('srs-field-layout-MainDefinition'),
          matching: find.text('2.'),
        ),
        findsOneWidget,
      );
      final TextEditingController first = _editable(
        tester,
        'srs-field-layout-MainDefinition-0',
      ).controller;
      expect(first.text, '(大辞林) かよう');
      // 词条加粗 + 红色，原生画出来。
      final TextSpan span = first.buildTextSpan(
        context: tester.element(_key('srs-field-layout-MainDefinition-0')),
        withComposing: false,
      );
      final TextSpan entry = span.children![2] as TextSpan;
      expect(entry.text, 'かよう');
      expect(entry.style?.fontWeight, FontWeight.w700);
      expect(entry.style?.color, const Color(0xFFCC0000));

      await tester.enterText(
        find.descendant(
          of: _key('srs-field-layout-MainDefinition-0'),
          matching: find.byType(EditableText),
        ),
        '(大辞林) かよう（通う）',
      );
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: _key('srs-field-layout-MainDefinition-1'),
          matching: find.byType(EditableText),
        ),
        '行き来する\n往復する・通勤する',
      );
      await tester.pump();
      expect(
        await _field(tester, store, note, 'MainDefinition'),
        _kGlossary,
        reason: '只进草稿',
      );
      // 完成 → 回到卡片预览。
      await tester.tap(_key('srs-field-parts-MainDefinition'));
      await _settle(tester, rounds: 4);
      expect(_key('srs-field-preview-MainDefinition'), findsOneWidget);

      await tester.tap(_key('srs_note_save').first);
      await _settle(tester);
      expect(
        await _field(tester, store, note, 'MainDefinition'),
        _kGlossary
            .replaceFirst('かよう<', 'かよう（通う）<')
            .replaceFirst('往復する<', '往復する・通勤する<'),
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 可视化模板：块的间距 / 图片大小可调，保存写进模板正文', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _open(tester);
      final String nt = await _db(
        tester,
        () => store.createStockNoteType(SrsStockNoteType.basic, 'B'),
      );
      final SrsNoteTypeView v = (await _db(tester, () => store.noteType(nt)))!;
      await _pump(
        tester,
        store,
        SrsTemplateEditorPage(
          noteTypeId: nt,
          templateId: v.templates.single.id,
        ),
        apple: apple,
        size: const Size(1100, 1600),
      );
      await tester.tap(_key('srs-visual-generate'));
      await _settle(tester);
      await tester.tap(find.text(t.srs_visual_generate).last);
      await _settle(tester);
      await tester.tap(_key('srs-visual-block-tile-b1'));
      await _settle(tester, rounds: 6);

      // 分段行放不下时设计系统会收成弹出菜单：两种形态都按文字选。
      Future<void> pick(String row, String label) async {
        await tester.ensureVisible(_key(row));
        await tester.pump();
        final Finder segment = find.descendant(
          of: _key(row),
          matching: find.text(label),
        );
        if (segment.evaluate().isEmpty) {
          await tester.tap(_key(row));
          await _settle(tester, rounds: 4);
          await tester.tap(find.text(label).last);
        } else {
          await tester.tap(segment);
        }
        await _settle(tester, rounds: 4);
      }

      await pick('srs-visual-spacing-b1', t.srs_visual_spacing_loose);
      await pick('srs-visual-image-size-b1', t.srs_visual_image_full);

      await tester.tap(_key('srs_template_save').first);
      await _settle(tester);
      final SrsTemplateDef saved = (await _db(
        tester,
        () => store.noteType(nt),
      ))!.templates.single;
      expect(saved.front, contains('margin:0.9em 0'));
      expect(saved.front, contains('fv-img-100'));
      final SrsVisualBlock b1 = srsParseVisualMarker(saved.front)!.first;
      expect(b1.spacing, SrsVisualSpacing.loose);
      expect(b1.imageSize, SrsVisualImageSize.full);
      await _unmount(tester);
    });
  }
}
