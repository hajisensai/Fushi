import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

void main() {
  const List<FushiCardBlock> all = FushiCardBlock.values;

  test('默认背面认出默认顺序', () {
    expect(fushiCardBackLayoutOf(kFushiCardBackTemplate), all);
    expect(fushiCardBackTemplateFor(all), kFushiCardBackTemplate);
  });

  test('生成的模板认回同一顺序（调序 + 删区块）', () {
    final List<List<FushiCardBlock>> cases = <List<FushiCardBlock>>[
      <FushiCardBlock>[
        FushiCardBlock.picture,
        FushiCardBlock.term,
        FushiCardBlock.reading,
        FushiCardBlock.definitions,
        FushiCardBlock.sentence,
        FushiCardBlock.source,
        FushiCardBlock.frequency,
      ],
      <FushiCardBlock>[FushiCardBlock.term, FushiCardBlock.definitions],
      <FushiCardBlock>[],
    ];
    for (final List<FushiCardBlock> c in cases) {
      expect(fushiCardBackLayoutOf(fushiCardBackTemplateFor(c)), c);
    }
  });

  test('手改模板：整段剪切挪位置、改缩进与注释仍认得', () {
    final String picture = kFushiCardBackSnippets[FushiCardBlock.picture]!;
    final String moved = kFushiCardBackTemplate
        .replaceFirst(picture, '')
        .replaceFirst(
          '<footer class="fc-foot">',
          '<footer class="fc-foot">\n        $picture\n',
        )
        .replaceFirst('<!--', '<!-- 我改过 ');
    expect(fushiCardBackLayoutOf(moved), <FushiCardBlock>[
      FushiCardBlock.term,
      FushiCardBlock.reading,
      FushiCardBlock.sentence,
      FushiCardBlock.definitions,
      FushiCardBlock.picture,
      FushiCardBlock.frequency,
      FushiCardBlock.source,
    ]);
  });

  test('改了区块内部、骨架或重复区块：认不出（回退 WebView）', () {
    expect(
      fushiCardBackLayoutOf(
        kFushiCardBackTemplate.replaceFirst('fc-sentence-body', 'my-body'),
      ),
      isNull,
    );
    expect(
      fushiCardBackLayoutOf(
        kFushiCardBackTemplate.replaceFirst(
          '<footer class="fc-foot">',
          '<p>额外文字</p><footer class="fc-foot">',
        ),
      ),
      isNull,
    );
    final String source = kFushiCardBackSnippets[FushiCardBlock.source]!;
    expect(
      fushiCardBackLayoutOf(
        kFushiCardBackTemplate.replaceFirst(source, '$source$source'),
      ),
      isNull,
    );
  });

  test('正面 / 样式：空白差异不算改', () {
    expect(fushiCardFrontIsDefault('  $kFushiCardFrontTemplate\n'), isTrue);
    expect(
      fushiCardFrontIsDefault('$kFushiCardFrontTemplate<b>x</b>'),
      isFalse,
    );
    expect(fushiCardCssIsDefault('$kFushiCardStylingCss\n\n'), isTrue);
    expect(fushiCardCssIsDefault('$kFushiCardStylingCss .x{}'), isFalse);
  });
}
