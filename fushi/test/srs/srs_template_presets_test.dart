// 「添加卡片模板」的起点预设：不再照抄第一个模板（Discord 反馈：照抄 = 同一道题考两遍、复习量翻倍），
// 反向 / 听力 / 空白按笔记类型的字段自动映射，正面与已有模板相同的预设不可用。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_template_presets.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_template_duplicates.dart';
import 'package:fushi_srs/fushi_srs.dart';

SrsNoteTypeView _type({
  required List<String> fieldNames,
  required List<({String front, String back})> templatesByName,
  String? builtinKey,
  String? termField,
  String css = '',
}) {
  final List<SrsFieldDef> fields = <SrsFieldDef>[
    for (int i = 0; i < fieldNames.length; i++)
      SrsFieldDef(id: 'f$i', name: fieldNames[i], ord: i),
  ];
  final Map<String, String> ids = <String, String>{
    for (final SrsFieldDef f in fields) f.name: f.id,
  };
  return SrsNoteTypeView(
    id: 'nt',
    ankiNum: 1,
    kind: SrsNoteTypeKind.standard,
    name: 'T',
    termFieldId: termField == null ? null : ids[termField],
    deletedAt: null,
    edits: SrsEntityEdits(<String, SrsRegister>{}),
    builtinKey: builtinKey,
    fields: fields,
    templates: <SrsTemplateDef>[
      for (int i = 0; i < templatesByName.length; i++)
        SrsTemplateDef(
          id: 't$i',
          name: 'Card ${i + 1}',
          ord: i,
          front: templateNamesToIds(templatesByName[i].front, ids),
          back: templateNamesToIds(templatesByName[i].back, ids),
        ),
    ],
    css: css,
  );
}

SrsNoteTypeView _fushi({String? front, String? back}) => _type(
  fieldNames: FushiCardNoteType.fields,
  templatesByName: <({String front, String back})>[
    (
      front: front ?? kFushiCardFrontTemplate,
      back: back ?? kFushiCardBackTemplate,
    ),
  ],
  builtinKey: kSrsBuiltinFushiCardKey,
  termField: 'Term',
  css: kFushiCardStylingCss,
);

String _names(SrsNoteTypeView t, String body) => templateIdsToNames(
  body,
  <String, String>{for (final SrsFieldDef f in t.fields) f.id: f.name},
);

bool _empty(SrsNoteTypeView t, String front, Map<String, String> values) =>
    isAnkiCardEmpty(
      questionTemplate: _names(t, front),
      noteFields: <String, String>{
        for (final SrsFieldDef f in t.fields) f.name: values[f.name] ?? '',
      },
      cardOrd: 1,
      isCloze: false,
    );

SrsTemplatePreset _of(List<SrsTemplatePreset> ps, SrsTemplatePresetKind k) =>
    ps.singleWhere((SrsTemplatePreset p) => p.kind == k);

void main() {
  group('内置 Fushi 卡片', () {
    test('三种预设都可用，没有一个与第一个模板重复（不再照抄 Card 1）', () {
      final SrsNoteTypeView t = _fushi();
      final List<SrsTemplatePreset> ps = srsTemplatePresets(t);
      expect(ps.map((SrsTemplatePreset p) => p.kind), <SrsTemplatePresetKind>[
        SrsTemplatePresetKind.reverse,
        SrsTemplatePresetKind.listening,
        SrsTemplatePresetKind.blank,
      ]);
      for (final SrsTemplatePreset p in ps) {
        expect(p.available, isTrue, reason: '${p.kind}');
        expect(
          srsTemplatesWithSameFront(t, '', front: p.front),
          isEmpty,
          reason: '${p.kind} 的正面不能与已有模板相同',
        );
      }
    });

    test('反向：正面是只放主释义的区块布局（原生卡面可调），背面沿用第一个模板认得出的背面', () {
      final String back = fushiCardBackTemplateFor(<FushiCardItem>[
        FushiCardBlockItem(FushiCardBlock.term),
        FushiCardBlockItem(FushiCardBlock.definitions),
      ]);
      final SrsNoteTypeView t = _fushi(back: back);
      final SrsTemplatePreset p = _of(
        srsTemplatePresets(t),
        SrsTemplatePresetKind.reverse,
      );
      expect(p.meaning!.name, 'MainDefinition');
      expect(p.term!.name, 'Term');
      expect(fushiCardFrontLayoutOf(_names(t, p.front)), <FushiCardItem>[
        FushiCardFieldItem(field: 'MainDefinition'),
      ]);
      expect(p.back, t.templates.single.back);
      expect(_empty(t, p.front, <String, String>{'Term': '猫'}), isTrue);
      expect(
        _empty(t, p.front, <String, String>{'MainDefinition': 'cat'}),
        isFalse,
      );
    });

    test('第一个模板背面认不出区块布局：新模板用默认背面', () {
      final SrsNoteTypeView t = _fushi(back: '<p>x</p>{{Term}}');
      final SrsTemplatePreset p = _of(
        srsTemplatePresets(t),
        SrsTemplatePresetKind.reverse,
      );
      expect(
        fushiCardBackLayoutOf(_names(t, p.back)),
        kFushiCardDefaultBackItems,
      );
    });

    test('听力：正面只放单词音频，没有音频的笔记是空卡（不出卡）', () {
      final SrsNoteTypeView t = _fushi();
      final SrsTemplatePreset p = _of(
        srsTemplatePresets(t),
        SrsTemplatePresetKind.listening,
      );
      expect(p.audio!.name, 'TermAudio');
      expect(_names(t, p.front), contains('{{TermAudio}}'));
      expect(_names(t, p.front), isNot(contains('{{Term}}')));
      expect(
        _empty(t, p.front, <String, String>{
          'Term': '猫',
          'MainDefinition': 'x',
        }),
        isTrue,
      );
      expect(
        _empty(t, p.front, <String, String>{'TermAudio': '[sound:a.mp3]'}),
        isFalse,
      );
    });

    test('空白：正面认得出区块布局但不引用字段——一张卡都不出，不算重复', () {
      final SrsNoteTypeView t = _fushi();
      final SrsTemplatePreset p = _of(
        srsTemplatePresets(t),
        SrsTemplatePresetKind.blank,
      );
      expect(p.makesCards, isFalse);
      expect(fushiCardFrontLayoutOf(_names(t, p.front)), isEmpty);
      expect(srsTemplateFrontUsesFields(p.front), isFalse);
      expect(
        _empty(t, p.front, <String, String>{
          for (final String f in FushiCardNoteType.fields) f: 'x',
        }),
        isTrue,
      );
    });
  });

  group('普通笔记类型', () {
    SrsNoteTypeView basic() => _type(
      fieldNames: const <String>['Front', 'Back'],
      templatesByName: const <({String front, String back})>[
        (front: '{{Front}}', back: '{{FrontSide}}<hr id=answer>{{Back}}'),
      ],
      termField: 'Front',
    );

    test('问答类型：反向 = 正面 Back、背面 Front；没有音频字段时听力不可用并说明', () {
      final SrsNoteTypeView t = basic();
      final List<SrsTemplatePreset> ps = srsTemplatePresets(t);
      final SrsTemplatePreset rev = _of(ps, SrsTemplatePresetKind.reverse);
      expect(rev.available, isTrue);
      expect(rev.meaning!.name, 'Back');
      expect(_names(t, rev.front), contains('{{Back}}'));
      expect(_names(t, rev.front), isNot(contains('{{Front}}')));
      expect(_names(t, rev.back), contains('{{FrontSide}}'));
      expect(_names(t, rev.back), contains('{{Front}}'));
      final SrsTemplatePreset listen = _of(ps, SrsTemplatePresetKind.listening);
      expect(listen.missingField, isTrue);
      expect(listen.available, isFalse);
      expect(_of(ps, SrsTemplatePresetKind.blank).available, isTrue);
    });

    test('有音频字段：听力正面只放音频；已有同正面的模板时该预设不可用并指出是哪个', () {
      final SrsNoteTypeView plain = _type(
        fieldNames: const <String>['Word', 'Meaning', 'WordAudio'],
        templatesByName: const <({String front, String back})>[
          (front: '{{Word}}', back: '{{FrontSide}}<hr id=answer>{{Meaning}}'),
        ],
        termField: 'Word',
      );
      final SrsTemplatePreset listen = _of(
        srsTemplatePresets(plain),
        SrsTemplatePresetKind.listening,
      );
      expect(listen.available, isTrue);
      expect(listen.audio!.name, 'WordAudio');
      expect(_names(plain, listen.front), contains('{{WordAudio}}'));
      expect(_names(plain, listen.front), isNot(contains('{{Word}}')));

      // 已经按这个预设加过一次：再选就是重复。
      final SrsNoteTypeView again = SrsNoteTypeView(
        id: plain.id,
        ankiNum: plain.ankiNum,
        kind: plain.kind,
        name: plain.name,
        termFieldId: plain.termFieldId,
        deletedAt: null,
        edits: plain.edits,
        builtinKey: null,
        fields: plain.fields,
        templates: <SrsTemplateDef>[
          ...plain.templates,
          SrsTemplateDef(
            id: 'tl',
            name: 'Listening',
            ord: 1,
            front: listen.front,
            back: listen.back,
          ),
        ],
        css: '',
      );
      final SrsTemplatePreset dup = _of(
        srsTemplatePresets(again),
        SrsTemplatePresetKind.listening,
      );
      expect(dup.duplicateOf?.name, 'Listening');
      expect(dup.available, isFalse);
    });
  });
}
