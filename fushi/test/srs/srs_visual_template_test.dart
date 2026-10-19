// 可视化卡片模板：块 ⇄ 模板正文的编译 / 解析，以及编译结果经真实 Anki 渲染器的效果。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_srs/fushi_srs.dart';

const SrsVisualCompileContext _ctx = SrsVisualCompileContext(
  fieldNameById: <String, String>{'f1': 'Front', 'f2': 'Back', 'f3': 'Reading'},
);

SrsVisualBlock _field(String id, String fieldId, {SrsVisualFilter? filter}) =>
    SrsVisualBlock(
      id: id,
      kind: SrsVisualBlockKind.field,
      fieldId: fieldId,
      filter: filter ?? SrsVisualFilter.plain,
    );

AnkiRenderedCard _render(String front, String back, Map<String, String> v) =>
    renderAnkiCard(
      questionTemplate: front,
      answerTemplate: back,
      noteFields: v,
      cardOrd: 0,
      isCloze: false,
    );

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('块编码进注释后能原样读回；注释里不出现会破坏模板 / HTML 注释的 }} 与 --', () {
    final List<SrsVisualBlock> blocks = <SrsVisualBlock>[
      const SrsVisualBlock(
        id: 'b1',
        kind: SrsVisualBlockKind.field,
        fieldId: 'f1',
        size: SrsVisualSize.display,
        bold: true,
        tone: SrsVisualTone.accent,
        label: '词 -- }} {{x}}',
      ),
      const SrsVisualBlock(id: 'b2', kind: SrsVisualBlockKind.divider),
      const SrsVisualBlock(
        id: 'b3',
        kind: SrsVisualBlockKind.text,
        text: 'a}}b--c',
        align: SrsVisualAlign.start,
        boxed: true,
        hideWhenEmpty: false,
      ),
    ];
    final String marker = srsVisualMarker(blocks);
    final String inner = marker.substring(
      kSrsVisualMarkerPrefix.length,
      marker.length - '-->'.length,
    );
    expect(inner.contains('}}'), isFalse);
    expect(inner.contains('--'), isFalse);
    final List<SrsVisualBlock> back = srsParseVisualMarker(marker)!;
    expect(
      back.map((SrsVisualBlock b) => b.toJson()).toList(),
      blocks.map((SrsVisualBlock b) => b.toJson()).toList(),
    );
  });

  test('没有标记 / 标记损坏的模板不算可视化模板', () {
    expect(srsParseVisualMarker('{{Front}}'), isNull);
    expect(srsParseVisualMarker('<!--fushi-visual:v1:!!!-->{{Front}}'), isNull);
    expect(srsReadVisualSide('<div>{{Front}}</div>', _ctx).isVisual, isFalse);
  });

  test('编译结果经 Anki 渲染器：字段显示、空字段整块（含小标题）消失、过滤器生效', () {
    final String front = srsCompileVisualSide(<SrsVisualBlock>[
      _field('b1', 'f1'),
    ], _ctx);
    final String back = srsCompileVisualSide(<SrsVisualBlock>[
      const SrsVisualBlock(id: 'b1', kind: SrsVisualBlockKind.frontSide),
      const SrsVisualBlock(id: 'b2', kind: SrsVisualBlockKind.divider),
      _field('b3', 'f3', filter: SrsVisualFilter.furigana),
      const SrsVisualBlock(
        id: 'b4',
        kind: SrsVisualBlockKind.field,
        fieldId: 'f2',
        label: 'Meaning',
      ),
    ], _ctx);
    final AnkiRenderedCard full = _render(front, back, <String, String>{
      'Front': '猫',
      'Back': 'cat',
      'Reading': '猫[ねこ]',
    });
    expect(_text(full.question), '猫');
    expect(full.answer, contains('<ruby>'), reason: '注音过滤器把读音标上');
    expect(_text(full.answer), contains('Meaning cat'));
    expect(full.answer, contains('<hr'));

    final AnkiRenderedCard empty = _render(front, back, <String, String>{
      'Front': '猫',
      'Back': '',
      'Reading': '',
    });
    expect(_text(empty.answer), isNot(contains('Meaning')));
    expect(empty.answer, isNot(contains('<ruby>')));
  });

  test('文字块转义 HTML 与模板花括号，渲染出来是字面文字', () {
    final String front = srsCompileVisualSide(<SrsVisualBlock>[
      _field('b1', 'f1'),
      const SrsVisualBlock(
        id: 'b2',
        kind: SrsVisualBlockKind.text,
        text: '<b>{{Back}}</b>',
      ),
    ], _ctx);
    final AnkiRenderedCard card = _render(
      front,
      '{{FrontSide}}',
      <String, String>{'Front': '猫', 'Back': 'SECRET', 'Reading': ''},
    );
    expect(card.question, isNot(contains('SECRET')));
    expect(card.question, contains('&lt;b&gt;'));
  });

  test('填空显示方式只给填空类型；引用已删字段的块编译时跳过', () {
    final String plain = srsCompileVisualBody(<SrsVisualBlock>[
      _field('b1', 'f1', filter: SrsVisualFilter.cloze),
      _field('b2', 'gone'),
    ], _ctx);
    expect(plain, contains('{{Front}}'));
    expect(plain, isNot(contains('cloze:')));
    expect(plain, isNot(contains('gone')));
    final String cloze = srsCompileVisualBody(
      <SrsVisualBlock>[_field('b1', 'f1', filter: SrsVisualFilter.cloze)],
      SrsVisualCompileContext(fieldNameById: _ctx.fieldNameById, isCloze: true),
    );
    expect(cloze, contains('{{cloze:Front}}'));
    expect(cloze, isNot(contains('{{#Front}}')), reason: '填空字段不包条件段');
  });

  test('按 fieldId 存：保存时换成 id 引用、改字段名后再读回仍是同一批块且未被判成手改', () {
    final List<SrsVisualBlock> blocks = <SrsVisualBlock>[_field('b1', 'f1')];
    final String named = srsCompileVisualSide(blocks, _ctx);
    final String stored = templateNamesToIds(named, <String, String>{
      'Front': 'f1',
      'Back': 'f2',
      'Reading': 'f3',
    });
    expect(stored, contains('{{fld:f1}}'));
    final String reopened = templateIdsToNames(stored, <String, String>{
      'f1': 'Word',
      'f2': 'Back',
      'f3': 'Reading',
    });
    final SrsVisualSideState state = srsReadVisualSide(
      reopened,
      const SrsVisualCompileContext(
        fieldNameById: <String, String>{
          'f1': 'Word',
          'f2': 'Back',
          'f3': 'Reading',
        },
      ),
    );
    expect(state.isVisual, isTrue);
    expect(state.edited, isFalse);
    expect(state.blocks!.single.fieldId, 'f1');
    expect(reopened, contains('{{Word}}'));
  });

  test('代码页手改过编译结果 → 判成手改（可视化页会提示覆盖）', () {
    final String named = srsCompileVisualSide(<SrsVisualBlock>[
      _field('b1', 'f1'),
    ], _ctx);
    expect(srsReadVisualSide(named, _ctx).edited, isFalse);
    expect(srsReadVisualSide('$named\n<p>extra</p>', _ctx).edited, isTrue);
  });

  test('自动布局（内置 Lapis）：正面只放词条；背面不放开关 / 数据字段，按惯例顺序', () {
    final SrsBuiltinNoteType lapis = srsBuiltinLapis('p1');
    final SrsNoteTypeView type = SrsNoteTypeView(
      id: 'nt',
      ankiNum: 1,
      kind: lapis.kind,
      name: lapis.name,
      fields: lapis.fields,
      templates: lapis.templates,
      css: lapis.css,
      termFieldId: lapis.termFieldId,
      deletedAt: null,
      builtinKey: lapis.key,
      edits: SrsEntityEdits(<String, SrsRegister>{}),
    );
    final ({List<SrsVisualBlock> front, List<SrsVisualBlock> back}) layout =
        srsSuggestVisualLayout(type);
    String nameOf(SrsVisualBlock b) =>
        type.fieldById(b.fieldId ?? '')?.name ?? b.kind.name;
    expect(layout.front.map(nameOf), <String>['Expression']);
    final List<String> back = layout.back.map(nameOf).toList();
    expect(back.take(2), <String>['frontSide', 'divider']);
    expect(back[2], 'ExpressionFurigana', reason: '分隔线下第一块是带注音的词条');
    for (final String hidden in <String>[
      'IsWordAndSentenceCard',
      'IsClickCard',
      'IsSentenceCard',
      'IsAudioCard',
      'PitchPosition',
      'PitchCategories',
      'FreqSort',
    ]) {
      expect(back, isNot(contains(hidden)));
      expect(srsKnownField(hidden)!.backOrder, isNull);
    }
    expect(
      back.indexOf('ExpressionReading'),
      lessThan(back.indexOf('Glossary')),
    );
    final Set<String> ids = <String>{
      for (final SrsVisualBlock b in layout.back) b.id,
    };
    expect(ids.length, layout.back.length, reason: '块 id 唯一');
  });

  test('自动布局（自建类型）：未知字段排在后面并带字段名小标题', () {
    final SrsNoteTypeView type = SrsNoteTypeView(
      id: 'nt',
      ankiNum: 1,
      kind: SrsNoteTypeKind.standard,
      name: 'Mine',
      fields: const <SrsFieldDef>[
        SrsFieldDef(id: 'a', name: '单词', ord: 0),
        SrsFieldDef(id: 'b', name: '我的笔记', ord: 1),
      ],
      templates: const <SrsTemplateDef>[],
      css: '',
      termFieldId: null,
      deletedAt: null,
      builtinKey: null,
      edits: SrsEntityEdits(<String, SrsRegister>{}),
    );
    final ({List<SrsVisualBlock> front, List<SrsVisualBlock> back}) layout =
        srsSuggestVisualLayout(type);
    expect(layout.front.single.fieldId, 'a');
    final SrsVisualBlock note = layout.back.last;
    expect(note.fieldId, 'b');
    expect(note.label, '我的笔记');
  });

  test('字段 id 换了（克隆 / 跨设备导入）：按注释里记下的字段名认回，不算手改', () {
    final String named = srsCompileVisualSide(<SrsVisualBlock>[
      _field('b1', 'f1'),
      _field('b2', 'f2'),
    ], _ctx);
    // 克隆后的类型：同名字段、全新 id；正文按名字形式不变。
    const SrsVisualCompileContext cloned = SrsVisualCompileContext(
      fieldNameById: <String, String>{
        'n1': 'Front',
        'n2': 'Back',
        'n3': 'Reading',
      },
    );
    final SrsVisualSideState state = srsReadVisualSide(named, cloned);
    expect(state.blocks!.map((SrsVisualBlock b) => b.fieldId), <String>[
      'n1',
      'n2',
    ]);
    expect(state.edited, isFalse);
    // 再编译一次，正文与原来一致（不会丢字段块）。
    expect(
      srsCompileVisualBody(state.blocks!, cloned),
      srsCompileVisualBody(<SrsVisualBlock>[
        _field('b1', 'f1'),
        _field('b2', 'f2'),
      ], _ctx),
    );
  });

  test('删字段：可视化的一面去掉引用它的块整面重编（不留小标题空壳）；没引用 / 非可视化返回 null', () {
    final String named = srsCompileVisualSide(<SrsVisualBlock>[
      _field('b1', 'f1'),
      const SrsVisualBlock(
        id: 'b2',
        kind: SrsVisualBlockKind.field,
        fieldId: 'f2',
        label: 'Meaning',
      ),
    ], _ctx);
    final String dropped = srsVisualDropField(named, 'f2', _ctx)!;
    expect(dropped, isNot(contains('Meaning')));
    expect(dropped, isNot(contains('{{Back}}')));
    expect(srsReadVisualSide(dropped, _ctx).edited, isFalse);
    expect(srsReadVisualSide(dropped, _ctx).blocks!.length, 1);
    expect(srsVisualDropField(named, 'f3', _ctx), isNull);
    expect(srsVisualDropField('{{Back}}', 'f2', _ctx), isNull);
  });

  test('自动布局（填空类型）：背面自己放填空字段而不是重复正面，答案面显示挖出的词', () {
    final SrsNoteTypeView type = SrsNoteTypeView(
      id: 'nt',
      ankiNum: 1,
      kind: SrsNoteTypeKind.cloze,
      name: 'Cloze',
      fields: const <SrsFieldDef>[
        SrsFieldDef(id: 'f1', name: 'Text', ord: 0),
        SrsFieldDef(id: 'f2', name: 'Back Extra', ord: 1),
      ],
      templates: const <SrsTemplateDef>[],
      css: '',
      termFieldId: null,
      deletedAt: null,
      builtinKey: null,
      edits: SrsEntityEdits(<String, SrsRegister>{}),
    );
    final ({List<SrsVisualBlock> front, List<SrsVisualBlock> back}) layout =
        srsSuggestVisualLayout(type);
    expect(
      layout.back.any(
        (SrsVisualBlock b) => b.kind == SrsVisualBlockKind.frontSide,
      ),
      isFalse,
    );
    final SrsVisualCompileContext ctx = SrsVisualCompileContext.of(type);
    final AnkiRenderedCard card = renderAnkiCard(
      questionTemplate: srsCompileVisualSide(layout.front, ctx),
      answerTemplate: srsCompileVisualSide(layout.back, ctx),
      noteFields: const <String, String>{
        'Text': '猫は{{c1::動物}}です',
        'Back Extra': '',
      },
      cardOrd: 0,
      isCloze: true,
    );
    expect(_text(card.question), isNot(contains('動物')));
    expect(_text(card.answer), contains('動物'));
  });
}
