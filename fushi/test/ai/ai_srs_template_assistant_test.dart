// 「复习卡片模板」AI 助手：回复的本地校验（只认已有字段 / 固定枚举，清掉 HTML，不让一面被清空）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi_srs/fushi_srs.dart';

const List<SrsFieldDef> _fields = <SrsFieldDef>[
  SrsFieldDef(id: 'f1', name: 'Expression', ord: 0),
  SrsFieldDef(id: 'f2', name: 'Meaning', ord: 1),
];

AiSrsTemplateSuggestion _parse(Object reply, {bool isCloze = false}) =>
    parseAiSrsTemplateSuggestion(
      reply is String ? reply : jsonEncode(reply),
      fields: _fields,
      isCloze: isCloze,
    );

void main() {
  test('合法回复：两面块 + 说明，字段可按 id 或按名字（不分大小写）引用', () {
    final AiSrsTemplateSuggestion s = _parse(<String, Object?>{
      'explanation': '把词放大居中',
      'front': <Object?>[
        <String, Object?>{
          'kind': 'field',
          'field': 'f1',
          'size': 'display',
          'bold': 'true',
          'tone': 'accent',
        },
      ],
      'back': <Object?>[
        <String, Object?>{'kind': 'frontSide'},
        <String, Object?>{'kind': 'divider'},
        <String, Object?>{
          'kind': 'field',
          'field': 'meaning',
          'label': '<i>释义</i>',
          'align': 'start',
          'boxed': true,
        },
      ],
      'fieldDescriptions': <String, Object?>{
        'f2': '<b>中文释义</b>',
        'Expression': '要记的词',
        'nope': 'x',
      },
    });
    expect(s.explanation, '把词放大居中');
    final SrsVisualBlock head = s.front!.single;
    expect(head.fieldId, 'f1');
    expect(head.size, SrsVisualSize.display);
    expect(head.bold, isTrue);
    expect(head.tone, SrsVisualTone.accent);
    expect(s.back!.map((SrsVisualBlock b) => b.kind), <SrsVisualBlockKind>[
      SrsVisualBlockKind.frontSide,
      SrsVisualBlockKind.divider,
      SrsVisualBlockKind.field,
    ]);
    expect(s.back!.last.fieldId, 'f2');
    expect(s.back!.last.label, '释义', reason: '标签被剥掉');
    expect(s.back!.last.align, SrsVisualAlign.start);
    expect(s.back!.map((SrsVisualBlock b) => b.id), <String>['b1', 'b2', 'b3']);
    expect(s.fieldDescriptions, <String, String>{'f2': '中文释义', 'f1': '要记的词'});
  });

  test('非法内容丢弃：未知字段 / 未知种类 / 正面的「正面内容」/ 空文字；非填空类型降级填空', () {
    final AiSrsTemplateSuggestion s = _parse(<String, Object?>{
      'front': <Object?>[
        <String, Object?>{'kind': 'frontSide'},
        <String, Object?>{'kind': 'field', 'field': 'Ghost'},
        <String, Object?>{'kind': 'script', 'text': 'alert(1)'},
        <String, Object?>{'kind': 'text', 'text': '<script></script>'},
        <String, Object?>{'kind': 'field', 'field': 'f1', 'filter': 'cloze'},
        <String, Object?>{'kind': 'field', 'field': 'f2', 'size': 'gigantic'},
      ],
    });
    expect(s.front!.map((SrsVisualBlock b) => b.fieldId), <String?>[
      'f1',
      'f2',
    ]);
    expect(s.front!.first.filter, SrsVisualFilter.plain);
    expect(s.front!.last.size, SrsVisualSize.body, reason: '认不出的取默认');
    expect(s.back, isNull, reason: '没给背面 = 背面不改');
  });

  test('正面校验后没有字段块 → 正面不改；回复不是 JSON → 空建议', () {
    final AiSrsTemplateSuggestion s = _parse(<String, Object?>{
      'front': <Object?>[
        <String, Object?>{'kind': 'text', 'text': 'Hello'},
      ],
      'back': <Object?>[],
    });
    expect(s.front, isNull);
    expect(s.back, isNull);
    expect(s.isEmpty, isTrue);
    expect(_parse('sorry, I cannot').isEmpty, isTrue);
  });

  test('填空类型保留填空显示方式；JSON 裹在围栏和散文里也能抠出来', () {
    final AiSrsTemplateSuggestion s = _parse(
      'Sure!\n```json\n{"front":[{"kind":"field","field":"f1","filter":"cloze"}]}\n```',
      isCloze: true,
    );
    expect(s.front!.single.filter, SrsVisualFilter.cloze);
  });

  test('提示词带上字段 id / 说明 / 样例与当前布局，枚举清单与解析器同源', () {
    final String system = buildAiSrsTemplateSystemPrompt(isCloze: false);
    for (final SrsVisualSize v in SrsVisualSize.values) {
      expect(system, contains('"${v.name}"'));
    }
    expect(system, contains('NOT available'));
    final String user = buildAiSrsTemplateUserPrompt(
      request: '大字',
      noteTypeName: 'Mine',
      fields: const <AiSrsFieldBrief>[
        AiSrsFieldBrief(
          id: 'f1',
          name: 'Expression',
          meaning: '词',
          sample: '猫',
        ),
      ],
      currentFront: const <SrsVisualBlock>[
        SrsVisualBlock(id: 'b1', kind: SrsVisualBlockKind.field, fieldId: 'f1'),
      ],
      currentBack: null,
    );
    expect(user, contains('"id":"f1"'));
    expect(user, contains('"meaning":"词"'));
    expect(user, contains('"sample":"猫"'));
    expect(user, contains('Current front'));
    expect(user, isNot(contains('Current back')));
  });

  test('aiSrsPlainText：去标签、去花括号、折叠空白、截断', () {
    expect(aiSrsPlainText('<b>a</b>  {{b}}\n c', 100), 'a b c');
    expect(aiSrsPlainText('abcdef', 3), 'abc');
  });
}
