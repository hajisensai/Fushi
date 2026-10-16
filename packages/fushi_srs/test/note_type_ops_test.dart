import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String kP = 'profile-uid';

/// 测试用的「名字 → fieldId」改写（真实宿主用 fushi_anki 的模板解析器）。
String _namesToIds(String tpl, Map<String, String> nameToId) =>
    tpl.replaceAllMapped(RegExp(r'\{\{([#^/]?)([^{}]*?)\}\}'), (Match m) {
      final String key = m[2]!;
      final int colon = key.lastIndexOf(':');
      final String name = colon < 0 ? key : key.substring(colon + 1);
      final String prefix = colon < 0 ? '' : key.substring(0, colon + 1);
      final String? id = nameToId[name];
      return id == null ? m[0]! : '{{${m[1]}${prefix}fld:$id}}';
    });

int Function() _counter([int start = 1000]) {
  int n = start;
  return () => n++;
}

SrsNoteTypeView _view(SrsNewNoteType nt) => SrsNoteTypeView(
  id: nt.id,
  ankiNum: nt.record.payload['ankiNum']! as int,
  kind: nt.record.payload['ntKind']! as String,
  name: nt.name,
  fields: nt.fields,
  templates: nt.templates,
  css: nt.css,
  termFieldId: nt.termFieldId,
  deletedAt: null,
  builtinKey: null,
  edits: SrsEntityEdits(const <String, SrsRegister>{}),
);

SrsNoteView _note(String id, String typeId, Map<String, String> fields) =>
    SrsNoteView(
      id: id,
      noteTypeId: typeId,
      guid: 'g',
      createdAt: 0,
      fields: fields,
      tags: const <String>[],
      source: null,
      deckId: null,
      deletedAt: null,
      edits: SrsEntityEdits(const <String, SrsRegister>{}),
    );

void main() {
  SrsNewNoteType basic({String name = 'Basic', int start = 1000}) =>
      srsBuildNoteType(
        profileUid: kP,
        name: name,
        kind: SrsNoteTypeKind.standard,
        fieldNames: const <String>['Front', 'Back'],
        templates: const <SrsTemplateSpec>[
          SrsTemplateSpec(name: 'Card 1', front: '{{Front}}', back: '{{Back}}'),
          SrsTemplateSpec(name: 'Card 2', front: '{{Back}}', back: '{{Front}}'),
        ],
        css: '.card{}',
        namesToIds: _namesToIds,
        createdAt: 1,
        termFieldName: 'Front',
        nextAnkiNum: _counter(start),
      );

  group('新建 / 克隆的 ID（铁律 C）', () {
    test('笔记类型 / 字段 / 模板 ID 全部由 ankiNum 派生，模板正文是 fieldId 引用', () {
      final SrsNewNoteType nt = basic();
      expect(nt.id, SrsIds.noteType(kP, 1000));
      expect(nt.fields[0].id, SrsIds.field(nt.id, 1001));
      expect(nt.fields[0].ankiNum, 1001);
      expect(nt.templates[0].id, SrsIds.template(nt.id, 1003));
      expect(nt.templates[0].front, '{{fld:${nt.fields[0].id}}}');
      expect(nt.termFieldId, nt.fields[0].id);
      expect(nt.record.payload['ntKind'], SrsNoteTypeKind.standard);
    });

    test('克隆：ID 全新，模板引用跟着换到新字段，词条字段指向克隆出的字段', () {
      final SrsNewNoteType src = basic();
      final SrsNewNoteType copy = srsCloneNoteType(
        profileUid: kP,
        source: _view(src),
        name: 'Basic copy',
        createdAt: 2,
        nextAnkiNum: _counter(5000),
      );
      expect(copy.id, isNot(src.id));
      expect(copy.fields.map((SrsFieldDef f) => f.name), <String>[
        'Front',
        'Back',
      ]);
      expect(copy.templates[1].front, '{{fld:${copy.fields[1].id}}}');
      expect(copy.templates[0].front, isNot(contains(src.fields[0].id)));
      expect(copy.termFieldId, copy.fields[0].id);
    });
  });

  group('结构编辑', () {
    test('删字段：替换删掉、条件段保留段内内容，其它字段引用不动', () {
      const String a = 'aaaa-1';
      const String b = 'bbbb-2';
      final String tpl =
          '{{fld:$a}} {{text:fld:$a}} {{#fld:$a}}X{{fld:$b}}{{/fld:$a}} {{fld:$b}}';
      expect(srsRemoveFieldRefs(tpl, a), '  X{{fld:$b}} {{fld:$b}}');
    });

    test('调序只返回 ord 变了的项（没动过的内置项不写记录）', () {
      final SrsNewNoteType nt = basic();
      final List<SrsFieldDef> changed = srsReorderFields(nt.fields, <String>[
        nt.fields[0].id,
        nt.fields[1].id,
      ]);
      expect(changed, isEmpty);
      final List<SrsFieldDef> swapped = srsReorderFields(nt.fields, <String>[
        nt.fields[1].id,
        nt.fields[0].id,
      ]);
      expect(swapped.map((SrsFieldDef f) => (f.name, f.ord)), <(String, int)>[
        ('Back', 0),
        ('Front', 1),
      ]);
    });

    test('字段名校验：空 / 语法字符 / 特殊字段 / 不区分大小写重名', () {
      expect(srsValidateFieldName('  ', <String>[]), SrsNameProblem.empty);
      expect(
        srsValidateFieldName('a:b', <String>[]),
        SrsNameProblem.invalidChars,
      );
      expect(
        srsValidateFieldName('#a', <String>[]),
        SrsNameProblem.invalidChars,
      );
      expect(srsValidateFieldName('tags', <String>[]), SrsNameProblem.reserved);
      expect(
        srsValidateFieldName('front', <String>['Front']),
        SrsNameProblem.duplicate,
      );
      expect(srsValidateFieldName('Extra', <String>['Front']), isNull);
    });
  });

  group('更改笔记类型', () {
    test('默认映射：先按名字（不区分大小写），剩下的按顺序', () {
      final SrsNoteTypeView from = _view(basic());
      final SrsNoteTypeView to = _view(
        srsBuildNoteType(
          profileUid: kP,
          name: 'Other',
          kind: SrsNoteTypeKind.standard,
          fieldNames: const <String>['Word', 'front', 'Extra'],
          templates: const <SrsTemplateSpec>[
            SrsTemplateSpec(name: 'Recall', front: '{{Word}}', back: ''),
          ],
          css: '',
          namesToIds: _namesToIds,
          createdAt: 1,
          nextAnkiNum: _counter(9000),
        ),
      );
      final Map<String, String?> m = srsDefaultFieldMap(from, to);
      expect(m[to.fields[1].id], from.fields[0].id, reason: '按名字');
      expect(m[to.fields[0].id], from.fields[1].id, reason: '剩下的按顺序');
      expect(m[to.fields[2].id], isNull);
      final Map<String, String?> tm = srsDefaultTemplateMap(from, to);
      expect(tm[to.templates[0].id], from.templates[0].id);
    });

    test('普通 → 普通：字段按映射搬值、新卡连到旧卡、没映射的可见旧卡计为删除', () {
      final SrsNoteTypeView from = _view(basic());
      final SrsNoteTypeView to = _view(basic(name: 'B2', start: 7000));
      final SrsNoteView n = _note(
        SrsIds.note(kP, 'g1'),
        from.id,
        <String, String>{from.fields[0].id: '猫', from.fields[1].id: 'cat'},
      );
      final String c1 = SrsIds.card(n.id, from.templates[0].id, 0);
      final String c2 = SrsIds.card(n.id, from.templates[1].id, 0);
      final SrsNoteTypeChangePlan plan = srsPlanNoteTypeChange(
        note: n,
        from: from,
        to: to,
        // 正反对调：新 Front ← 旧 Back，新 Back ← 旧 Front。
        fieldMap: <String, String?>{
          to.fields[0].id: from.fields[1].id,
          to.fields[1].id: from.fields[0].id,
        },
        // 新 Card 1 ← 旧 Card 2；新 Card 2 不继承。
        templateMap: <String, String?>{
          to.templates[0].id: from.templates[1].id,
          to.templates[1].id: null,
        },
        existingCards: <SrsExistingCard>[
          SrsExistingCard(
            cardId: c1,
            templateId: from.templates[0].id,
            clozeOrd: 0,
            hidden: false,
          ),
          SrsExistingCard(
            cardId: c2,
            templateId: from.templates[1].id,
            clozeOrd: 0,
            hidden: false,
          ),
        ],
      );
      expect(plan.fieldValues, <String, String>{
        to.fields[0].id: 'cat',
        to.fields[1].id: '猫',
      });
      expect(plan.cardLinks, <String, String>{
        SrsIds.card(n.id, to.templates[0].id, 0): c2,
      });
      expect(plan.droppedCards, <String>[c1]);
    });

    test('普通 → 填空：第 i 个模板的卡对应 c(i+1)；填空 → 普通：cN 对应第 N 个模板', () {
      final SrsNoteTypeView std = _view(basic());
      final SrsNoteTypeView cloze = _view(
        srsBuildNoteType(
          profileUid: kP,
          name: 'Cloze',
          kind: SrsNoteTypeKind.cloze,
          fieldNames: const <String>['Text'],
          templates: const <SrsTemplateSpec>[
            SrsTemplateSpec(name: 'Cloze', front: '{{cloze:Text}}', back: ''),
          ],
          css: '',
          namesToIds: _namesToIds,
          createdAt: 1,
          nextAnkiNum: _counter(3000),
        ),
      );
      final SrsNoteView n = _note(
        SrsIds.note(kP, 'g2'),
        std.id,
        const <String, String>{},
      );
      final List<SrsExistingCard> stdCards = <SrsExistingCard>[
        for (final SrsTemplateDef t in std.templates)
          SrsExistingCard(
            cardId: SrsIds.card(n.id, t.id, 0),
            templateId: t.id,
            clozeOrd: 0,
            hidden: false,
          ),
      ];
      final SrsNoteTypeChangePlan toCloze = srsPlanNoteTypeChange(
        note: n,
        from: std,
        to: cloze,
        fieldMap: const <String, String?>{},
        templateMap: const <String, String?>{},
        existingCards: stdCards,
      );
      expect(toCloze.cardLinks, <String, String>{
        SrsIds.card(n.id, cloze.templates[0].id, 1): stdCards[0].cardId,
        SrsIds.card(n.id, cloze.templates[0].id, 2): stdCards[1].cardId,
      });
      expect(toCloze.droppedCards, isEmpty);

      final SrsNoteTypeChangePlan back = srsPlanNoteTypeChange(
        note: n,
        from: cloze,
        to: std,
        fieldMap: const <String, String?>{},
        templateMap: const <String, String?>{},
        existingCards: <SrsExistingCard>[
          for (final int ord in <int>[1, 2, 3])
            SrsExistingCard(
              cardId: SrsIds.card(n.id, cloze.templates[0].id, ord),
              templateId: cloze.templates[0].id,
              clozeOrd: ord,
              hidden: false,
            ),
        ],
      );
      expect(back.cardLinks.length, 2);
      expect(back.droppedCards, <String>[
        SrsIds.card(n.id, cloze.templates[0].id, 3),
      ]);
    });
  });
}
