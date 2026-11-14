import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/reader/manga_page_sentences.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 漫画「复制 OCR 文本」（反馈 hjUlprxxKI）的文本真值：点中那句 / 整页按阅读顺序。
MokuroBlock _vertical(
  double l,
  double t,
  double r,
  double b,
  String text, {
  double fontSize = 34,
}) => MokuroBlock(
  rectangle: MokuroRect.fromLTRB(l, t, r, b),
  isVertical: true,
  fontSize: fontSize,
  zIndex: 0,
  lines: <String>[text],
);

MokuroImage _page(List<MokuroBlock> blocks) => MokuroImage(
  url: 'p.png',
  size: const MokuroSize(1000, 1400),
  blocks: blocks,
);

/// BUG-1333 的真实页：右起「なに?」，中间是注音「だいじょうぶ」，左边三列拼成
/// 一句「大丈夫だよな?」。
const MokuroBlock _ruby = MokuroBlock(
  rectangle: MokuroRect.fromLTRB(288, 565, 309, 675),
  isVertical: true,
  fontSize: 21,
  zIndex: 0,
  lines: <String>['だいじょうぶ'],
);
final List<MokuroBlock> _body = <MokuroBlock>[
  _vertical(250, 561, 288, 687, '大丈夫', fontSize: 37),
  _vertical(205, 565, 240, 687, 'だよな'),
  _vertical(164, 644, 177, 683, '?', fontSize: 22),
  _vertical(322, 560, 360, 686, 'なに?'),
];

void main() {
  test('复制本页文字：按阅读顺序一行一句，RTL / LTR 镜像', () {
    final MokuroImage page = _page(<MokuroBlock>[
      _vertical(100, 100, 140, 300, '左です。'),
      _vertical(800, 100, 840, 300, '右です。'),
      _vertical(450, 1000, 490, 1200, '下です。'),
    ]);
    expect(mangaPageCopyText(page, rightToLeft: true), '右です。\n左です。\n下です。');
    expect(mangaPageCopyText(page, rightToLeft: false), '左です。\n右です。\n下です。');
  });

  test('复制本页文字：跨列的一句合成一行，注音不进文本', () {
    final MokuroImage page = _page(<MokuroBlock>[_ruby, ..._body]);
    final String? text = mangaPageCopyText(page, rightToLeft: true);
    expect(text, 'なに?\n大丈夫だよな?');
    expect(text, isNot(contains('だいじょうぶ')));
  });

  test('复制文字：点中任一列（含注音块）都得到整句，组号与 overlay 同源', () {
    final MokuroImage page = _page(<MokuroBlock>[_ruby, ..._body]);
    final List<MangaBlockSentence> groups = mangaBlockSentenceGroups(page);
    // 下标 0 是注音块，1..3 是「大丈夫 / だよな / ?」三列，4 是「なに?」。
    for (final int block in <int>[0, 1, 2, 3]) {
      expect(
        mangaSentenceGroupCopyText(page, groups[block].group),
        '大丈夫だよな?',
        reason: '块 $block',
      );
    }
    expect(mangaSentenceGroupCopyText(page, groups[4].group), 'なに?');
  });

  test('复制文字：不存在的组号 / 空白句返回 null', () {
    final MokuroImage page = _page(<MokuroBlock>[
      _vertical(800, 100, 840, 300, '  '),
    ]);
    expect(mangaSentenceGroupCopyText(page, 99), isNull);
    expect(
      mangaSentenceGroupCopyText(page, mangaBlockSentenceGroups(page)[0].group),
      isNull,
    );
    expect(mangaPageCopyText(page, rightToLeft: true), isNull);
  });

  test('空页（无 OCR）没有可复制文本', () {
    final MokuroImage page = _page(const <MokuroBlock>[]);
    expect(mangaPageSentencesInReadingOrder(page, rightToLeft: true), isEmpty);
    expect(mangaPageCopyText(page, rightToLeft: true), isNull);
  });
}
