import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// 区块布局：模板是唯一的数据来源（`data-fc-block` 标记 + `data-fc-opt-*` 选项），
/// [fushiCardLayoutOf] 读、[fushiCardTemplateFor] 写，两者互逆。
void main() {
  FushiCardBlockItem b(Enum block, [Map<String, String> o = const {}]) =>
      FushiCardBlockItem(block, options: o);

  String snippet(Enum block) => fushiCardItemSnippet(b(block));

  test('默认正面 / 背面认出默认布局，默认布局生成回默认模板', () {
    expect(fushiCardBackLayoutOf(kFushiCardBackTemplate), kFushiCardDefaultBackItems);
    expect(
      fushiCardFrontLayoutOf(kFushiCardFrontTemplate),
      kFushiCardDefaultFrontItems,
    );
    expect(
      fushiCardBackTemplateFor(kFushiCardDefaultBackItems),
      kFushiCardBackTemplate,
    );
    expect(
      fushiCardTemplateFor(FushiCardSide.front, kFushiCardDefaultFrontItems),
      kFushiCardFrontTemplate,
    );
  });

  test('生成的模板认回同一布局：调序、删区块、选项、字段区块、HTML 区块', () {
    final List<List<FushiCardItem>> backs = <List<FushiCardItem>>[
      <FushiCardItem>[
        b(FushiCardBlock.picture),
        b(FushiCardBlock.term),
        b(FushiCardBlock.reading, <String, String>{kFushiOptPitch: '0'}),
        b(FushiCardBlock.definitions, <String, String>{kFushiOptExpand: '1'}),
        b(FushiCardBlock.sentence, <String, String>{
          kFushiOptTranslation: '0',
          kFushiOptAudio: '0',
        }),
        b(FushiCardBlock.source, <String, String>{kFushiOptLabel: '出处 "A&B"'}),
        b(FushiCardBlock.frequency),
      ],
      <FushiCardItem>[b(FushiCardBlock.term), b(FushiCardBlock.definitions)],
      <FushiCardItem>[],
      <FushiCardItem>[
        b(FushiCardBlock.term),
        FushiCardFieldItem(
          field: 'MiscInfo',
          style: FushiCardFieldStyle.quote,
          title: '备注 <x>',
        ),
        FushiCardFieldItem(field: 'Hint', style: FushiCardFieldStyle.tag),
        const FushiCardHtmlItem('<p style="color:red">{{Term}}</p>'),
        b(FushiCardBlock.reading),
        b(FushiCardBlock.sentence),
        b(FushiCardBlock.definitions),
        const FushiCardHtmlItem('<i>页脚</i>'),
        b(FushiCardBlock.source),
        FushiCardFieldItem(field: 'Tags2', style: FushiCardFieldStyle.small),
      ],
    ];
    for (final List<FushiCardItem> c in backs) {
      expect(fushiCardBackLayoutOf(fushiCardBackTemplateFor(c)), c);
    }
    final List<List<FushiCardItem>> fronts = <List<FushiCardItem>>[
      <FushiCardItem>[
        b(FushiCardFrontBlock.hint),
        b(FushiCardFrontBlock.prompt, <String, String>{kFushiOptPitch: '0'}),
      ],
      <FushiCardItem>[
        FushiCardFieldItem(field: 'MainDefinition'),
        b(FushiCardFrontBlock.frequency),
        const FushiCardHtmlItem('<b>反向卡</b>'),
        b(FushiCardFrontBlock.hint),
      ],
    ];
    for (final List<FushiCardItem> c in fronts) {
      expect(
        fushiCardFrontLayoutOf(fushiCardTemplateFor(FushiCardSide.front, c)),
        c,
      );
    }
  });

  test('选项写进模板，导出到 Anki 一样生效', () {
    final String off = fushiCardItemSnippet(
      b(FushiCardBlock.reading, <String, String>{
        kFushiOptPitch: '0',
        kFushiOptAudio: '0',
        kFushiOptFreq: '0',
      }),
    );
    expect(off, contains('data-fc-opt-pitch="0"'));
    expect(off, isNot(contains('fc-pitch-tags')));
    expect(off, isNot(contains('TermAudio')));
    expect(off, isNot(contains('FrequencyRank')));
    expect(off, contains('TermReading'));
    final String label = fushiCardItemSnippet(
      b(FushiCardBlock.frequency, <String, String>{kFushiOptLabel: '频'}),
    );
    expect(label, contains('fc-meta-label--custom">频</span>'));
    // 默认值不写进模板。
    expect(
      b(FushiCardBlock.reading, <String, String>{kFushiOptPitch: '1'}).options,
      isEmpty,
    );
    final String defs = fushiCardDefinitionsTemplateFor(
      b(FushiCardBlock.definitions, <String, String>{kFushiOptExpand: '1'}),
    );
    expect(defs, contains('data-fc-opt-expand="1"'));
    expect(defs, contains('fc-defs-only'));
    expect(
      kFushiCardDefinitionsTemplate,
      contains('data-fc-block="definitions">'),
    );
    final String prompt = fushiCardItemSnippet(
      b(FushiCardFrontBlock.prompt, <String, String>{kFushiOptPitch: '0'}),
    );
    expect(prompt, isNot(contains('fc-front-pitch')));
  });

  test('手改模板：整段剪切挪位置、改缩进与注释仍认得', () {
    final String picture = snippet(FushiCardBlock.picture);
    final String moved = kFushiCardBackTemplate
        .replaceFirst(picture, '')
        .replaceFirst(
          '<footer class="fc-foot">',
          '<footer class="fc-foot">\n        $picture\n',
        )
        .replaceFirst('<!--', '<!-- 我改过 ');
    expect(fushiCardBackLayoutOf(moved), <FushiCardItem>[
      b(FushiCardBlock.term),
      b(FushiCardBlock.reading),
      b(FushiCardBlock.sentence),
      b(FushiCardBlock.definitions),
      b(FushiCardBlock.picture),
      b(FushiCardBlock.frequency),
      b(FushiCardBlock.source),
    ]);
  });

  test('改了区块内部：那一块按 HTML 区块（原文不动），其余照旧', () {
    final String edited = kFushiCardBackTemplate.replaceFirst(
      'fc-sentence-body',
      'my-body',
    );
    final List<FushiCardItem>? layout = fushiCardBackLayoutOf(edited);
    expect(layout, isNotNull);
    expect(layout![3], isA<FushiCardHtmlItem>());
    final FushiCardHtmlItem raw = layout[3] as FushiCardHtmlItem;
    expect(raw.wrapped, isFalse);
    expect(raw.html, contains('my-body'));
    expect(raw.html, startsWith('{{#Sentence}}'));
    expect(layout[0], b(FushiCardBlock.term));
    expect(layout[4], b(FushiCardBlock.definitions));
    // 写回去仍是同一份（再读一次结果不变）。
    final String again = fushiCardBackTemplateFor(layout);
    expect(fushiCardBackLayoutOf(again), layout);
    // 重复的内置区块：第二个按 HTML 区块。
    final String source = snippet(FushiCardBlock.source);
    final List<FushiCardItem>? dup = fushiCardBackLayoutOf(
      kFushiCardBackTemplate.replaceFirst(source, '$source$source'),
    );
    expect(dup!.last, isA<FushiCardHtmlItem>());
    expect(dup[dup.length - 2], b(FushiCardBlock.source));
  });

  test('改了骨架或标记坏了：认不出（回退 WebView）', () {
    expect(
      fushiCardBackLayoutOf(
        kFushiCardBackTemplate.replaceFirst(
          '<footer class="fc-foot">',
          '<p>额外文字</p><footer class="fc-foot">',
        ),
      ),
      isNull,
    );
    expect(
      fushiCardFrontLayoutOf(
        kFushiCardFrontTemplate.replaceFirst('fc-front"', 'fc-front x"'),
      ),
      isNull,
    );
    // 标记元素没闭合。
    expect(
      fushiCardBackLayoutOf(
        kFushiCardBackTemplate.replaceFirst(
          '<footer class="fc-foot">',
          '<div data-fc-block="html"><footer class="fc-foot">',
        ),
      ),
      isNull,
    );
  });

  test('字段区块：字段名取自条件段，字段改名后仍认得', () {
    final String t = fushiCardBackTemplateFor(<FushiCardItem>[
      FushiCardFieldItem(field: 'Old', title: 'T'),
    ]).replaceAll('{{#Old}}', '{{#New}}').replaceAll('{{Old}}', '{{New}}').replaceAll('{{/Old}}', '{{/New}}');
    expect(fushiCardBackLayoutOf(t), <FushiCardItem>[
      FushiCardFieldItem(field: 'New', title: 'T'),
    ]);
  });

  test('布局项 JSON 往返', () {
    final List<FushiCardItem> items = <FushiCardItem>[
      b(FushiCardBlock.reading, <String, String>{kFushiOptAudio: '0'}),
      b(FushiCardFrontBlock.frequency),
      FushiCardFieldItem(field: 'X', style: FushiCardFieldStyle.small, title: 't'),
      const FushiCardHtmlItem('<b>x</b>', wrapped: false),
    ];
    expect(
      <FushiCardItem?>[
        for (final FushiCardItem i in items) FushiCardItem.fromJson(i.toJson()),
      ],
      items,
    );
    expect(FushiCardItem.fromJson(<String, Object?>{'t': 'zz'}), isNull);
  });

  test('样式：空白差异不算改', () {
    expect(fushiCardCssIsDefault('$kFushiCardStylingCss\n\n'), isTrue);
    expect(fushiCardCssIsDefault('$kFushiCardStylingCss .x{}'), isFalse);
  });
}
