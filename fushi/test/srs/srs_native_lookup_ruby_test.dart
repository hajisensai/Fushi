import 'package:flutter/rendering.dart' show RenderParagraph, TextBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:material_ui/material_ui.dart';

void main() {
  test('srsLookupRubySpansForTerm：平移、截断丢弃', () {
    const List<FushiRubySpan> spans = <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 2, reading: 'まいにち'),
      FushiRubySpan(start: 5, end: 6, reading: 'かよ'),
    ];
    expect(srsLookupRubySpansForTerm(spans, 0, 7), spans);
    expect(srsLookupRubySpansForTerm(spans, 1, 6), const <FushiRubySpan>[
      FushiRubySpan(start: 4, end: 5, reading: 'かよ'),
    ]);
    expect(srsLookupRubySpansForTerm(spans, 0, 5), const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 2, reading: 'まいにち'),
    ]);
    expect(srsLookupRubySpansForTerm(const <FushiRubySpan>[], 0, 5), isEmpty);
  });

  testWidgets('点注音文字：命中携带取词串内的来源注音', (WidgetTester tester) async {
    final GlobalKey root = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: root,
            child: const SrsRubyText(
              segments: <SrsInline>[
                SrsInline('毎日', ruby: 'まいにち'),
                SrsInline('のように'),
                SrsInline('通', ruby: 'かよ'),
                SrsInline('う'),
              ],
              style: TextStyle(fontSize: 20),
              rubyStyle: TextStyle(fontSize: 10),
              lookup: true,
            ),
          ),
        ),
      ),
    );
    final RenderBox box = root.currentContext!.findRenderObject()! as RenderBox;
    Offset center(String chars) {
      for (final Element e
          in find
              .descendant(of: find.byKey(root), matching: find.byType(RichText))
              .evaluate()) {
        final RenderParagraph p = e.renderObject! as RenderParagraph;
        final String text = p.text.toPlainText(includeSemanticsLabels: false);
        final int i = text.indexOf(chars);
        if (i < 0) continue;
        final List<TextBox> boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        return p.localToGlobal(boxes.first.toRect().center);
      }
      fail('没找到文字 $chars');
    }

    final SrsNativeLookupHit first = srsNativeLookupHitAt(box, center('毎'))!;
    expect(first.term, '毎日のように通う');
    expect(first.rubySpans, const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 2, reading: 'まいにち'),
      FushiRubySpan(start: 6, end: 7, reading: 'かよ'),
    ]);
    final SrsNativeLookupHit mid = srsNativeLookupHitAt(box, center('よ'))!;
    expect(mid.term, 'ように通う');
    expect(mid.rubySpans, const <FushiRubySpan>[
      FushiRubySpan(start: 3, end: 4, reading: 'かよ'),
    ]);
  });
}
