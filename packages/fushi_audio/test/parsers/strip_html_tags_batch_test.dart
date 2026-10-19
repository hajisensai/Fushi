// HBK-AUDIT-008：增强 LRC 每行都带 `<MM:SS.xx>`，原先 lrc_parser 逐行调 stripHtmlTags、
// 每行跨一次 FFI。现在整份的行一次交给 `stripHtmlTagsBatch`
// （`ffc_parse_subtitle_strip_html_tags_batch`，循环在 Rust）。这里钉住两件事：批量结果逐项等于
// 单条入口；LrcParser 整份解析的产物与逐行剥离时一致。
@TestOn('vm')
library;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_audio/src/parsers/strip_html_tags.dart';
import 'package:test/test.dart';

void main() {
  test('stripHtmlTagsBatch 逐项等于 stripHtmlTags（含跨条不匹配、无 < 的行、空串）', () {
    final List<String> texts = <String>[
      '<00:12.34>こん<00:12.99>にちは',
      '',
      '  吾輩は猫である。  ',
      '<ruby>震<rt>ふる</rt></ruby>',
      '<ruby>震<rt>ふる</ruby>',
      '<ruby>震<rp>（</rp><rt>ふる</rt><rp>）</rp></ruby>',
      '<ruby>漢字<rtc><rt>かんじ</rt></rtc></ruby>',
      '<RUBY>震<RT>ふる</RT></RUBY>',
      '前<ruby>震<rt>ふる</rt></ruby>後',
      '震<rt>ふる',
      '<c.yellow><i>こんにちは</i></c>',
      '<rtl>こんにちは</rtl>',
      // 条尾未闭合的 `<` 不能借下一条的 `>` 把下一条正文吃掉。
      'a<b',
      'c>d',
      '<ruby>漢<rt かん</ruby>の話',
      'a<rt/>b',
      ' <> ',
      '\t<b> x </b>　',
      for (int i = 0; i < 100; i++) '<00:0$i.00>行$i<00:0$i.50>${' ' * (i % 3)}',
    ];
    expect(stripHtmlTagsBatch(texts), <String>[
      for (final String t in texts) stripHtmlTags(t),
    ]);
    expect(stripHtmlTagsBatch(const <String>[]), isEmpty);
    expect(stripHtmlTagsBatch(const <String>['  x  ', 'y']), <String>[
      'x',
      'y',
    ]);
  });

  test('增强 LRC 整份解析：词级标签剥净、同行多时间标签、剥空的行跳过', () {
    const String lrc =
        '﻿[ti:曲名]\r\n'
        '[ar:作者]\n'
        '\n'
        '[00:01.00]<00:01.00>吾輩<00:01.40>は<00:01.60>猫である。\n'
        '[00:04.50][00:20.00] <00:04.50>名前は<00:05.00>まだ<00:05.30>無い。 \n'
        '[00:08.20]<00:08.20><00:08.90>\n'
        '[00:09.00]<ruby>見当<rt>けんとう</rt></ruby>がつかぬ。\n'
        '[00:12.00]a<b\n'
        '[00:13.00]c>d\n';
    final List<AudioCue> cues = LrcParser.parseString(
      content: lrc,
      bookKey: 'b',
    );
    expect(
      <(int, int, String)>[
        for (final AudioCue c in cues) (c.startMs, c.endMs, c.text),
      ],
      <(int, int, String)>[
        (1000, 4500, '吾輩は猫である。'),
        (4500, 9000, '名前はまだ無い。'),
        (9000, 12000, '見当がつかぬ。'),
        (12000, 13000, 'a<b'),
        (13000, 20000, 'c>d'),
        (20000, 25000, '名前はまだ無い。'),
      ],
    );
    expect(
      <int>[for (final AudioCue c in cues) c.sentenceIndex],
      <int>[0, 1, 2, 3, 4, 5],
    );
  });
}
