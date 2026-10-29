import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// 区块 → 字段映射是原生渲染与导出模板的单一真相源：钉死两边显示同一组字段、同一顺序。
void main() {
  final RegExp ref = RegExp(r'\{\{[#^/]?(?:[a-z]+:)?([A-Za-z]+)\}\}');

  int firstRef(String field) {
    for (final RegExpMatch m in ref.allMatches(kFushiCardBackTemplate)) {
      if (m.group(1) == field) return m.start;
    }
    return -1;
  }

  test('every block field is referenced by the back template', () {
    for (final FushiCardBlock b in kFushiCardBackBlocks) {
      for (final String f in b.fields) {
        expect(firstRef(f), isNonNegative, reason: '${b.name}.$f');
      }
    }
  });

  test('blocks appear in the back template in mapping order', () {
    int previous = -1;
    for (final FushiCardBlock b in kFushiCardBackBlocks) {
      final int start = b.fields
          .map(firstRef)
          .reduce((int a, int c) => a < c ? a : c);
      expect(start, greaterThan(previous), reason: b.name);
      previous = start;
    }
  });

  test('blocks + switch + aux fields cover the note type exactly once', () {
    final List<String> all = <String>[
      for (final FushiCardBlock b in kFushiCardBackBlocks) ...b.fields,
      ...kFushiCardSwitchFields,
      ...kFushiCardAuxFields,
      ...kFushiCardUnusedFields,
    ];
    expect(all.toSet().length, all.length, reason: 'no field in two blocks');
    expect(all.toSet(), FushiCardNoteType.fields.toSet());
  });

  test('definition fields are exactly the WebView block', () {
    expect(kFushiCardDefinitionFields, <String>[
      'LookupSelection',
      'DefinitionMedia',
      'MainDefinition',
      'Glossary',
    ]);
  });

  test(
    'definitions-only template = back definitions section + back script',
    () {
      final String t = kFushiCardDefinitionsTemplate;
      expect(t, startsWith('<div class="fc fc-back fc-defs-only"'));
      final Set<String> refs = <String>{
        for (final RegExpMatch m in ref.allMatches(t)) m.group(1)!,
      };
      expect(refs, kFushiCardDefinitionFields.toSet());
      expect(t, contains('function setUpGlossary'));
      expect(t, isNot(contains('<footer class="fc-foot">')));
      expect(t, isNot(contains('<div class="fc-aside">')));
      final AnkiRenderedCard r = renderAnkiCard(
        questionTemplate: FushiCardNoteType.template.front,
        answerTemplate: t,
        noteFields: <String, String>{
          for (final String f in FushiCardNoteType.fields) f: '',
          'MainDefinition': '<ol><li>main</li></ol>',
          'Term': 'SHOULD-NOT-APPEAR',
        },
        cardOrd: 0,
        isCloze: false,
      );
      expect(r.answer, contains('main'));
      expect(r.answer, isNot(contains('SHOULD-NOT-APPEAR')));
    },
  );
}
