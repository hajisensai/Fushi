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

  // A2 自证骨架标记（反馈 O5YDP27Xko）：旧代码读到更新版本生成的模板，骨架不认识，但标记
  // 证明骨架是代码生成、没被人改过，照样认出区块布局。
  group('自证骨架标记', () {
    final RegExp marker = RegExp(
      '<!--$kFushiCardSkeletonMarker:([0-9a-f]{64})-->',
    );

    String markOf(String template) =>
        fushiCardSha256(fushiCardMarkedSkeletonOf(template)!);

    /// 模拟「未来版本」的背面：骨架多一段标记，末尾换成按新骨架算的标记。
    String futureBack({required bool rightMarker}) {
      final String changed = kFushiCardBackTemplate
          .replaceAll(marker, '')
          .replaceFirst('<script>', '<div class="fc-future"></div>\n<script>');
      final String mark = rightMarker
          ? markOf(changed)
          : markOf(kFushiCardBackTemplate);
      return '$changed<!--$kFushiCardSkeletonMarker:$mark-->\n';
    }

    test('内置模板与 fushiCardTemplateFor 生成的模板都带正确标记', () {
      for (final String t in <String>[
        kFushiCardFrontTemplate,
        kFushiCardBackTemplate,
        fushiCardTemplateFor(FushiCardSide.back, <FushiCardItem>[
          FushiCardBlockItem(FushiCardBlock.definitions),
          FushiCardBlockItem(FushiCardBlock.term),
        ]),
        fushiCardTemplateFor(FushiCardSide.front, <FushiCardItem>[
          const FushiCardHtmlItem('<b>{{Term}}</b>'),
        ]),
      ]) {
        final List<RegExpMatch> ms = marker.allMatches(t).toList();
        expect(ms, hasLength(1));
        expect(ms.single.group(1), markOf(t));
      }
    });

    test('未知骨架 + 正确标记：认得出布局', () {
      final String t = futureBack(rightMarker: true);
      expect(markOf(t), isNot(markOf(kFushiCardBackTemplate)));
      expect(fushiCardBackLayoutOf(t), kFushiCardDefaultBackItems);
    });

    test('未知骨架 + 标记对不上（手改过骨架）：认不出，带差异原文', () {
      final String t = futureBack(rightMarker: false);
      final FushiCardLayoutProbe p = fushiCardLayoutProbe(
        t,
        FushiCardSide.back,
      );
      expect(p.items, isNull);
      expect(p.mismatch, contains('fc-future'));
    });
  });
}
