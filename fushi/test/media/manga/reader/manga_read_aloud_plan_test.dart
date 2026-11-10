import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_plan.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';

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

List<String> _texts(
  MokuroImage page, {
  bool rightToLeft = true,
  List<TtsPronunciationRule> pronunciation = const <TtsPronunciationRule>[],
  int maxInputLength = 0,
}) => <String>[
  for (final MangaReadAloudUtterance u in planMangaPageReadAloud(
    page,
    pageIndex: 3,
    rightToLeft: rightToLeft,
    pronunciation: pronunciation,
    maxInputLength: maxInputLength,
  ))
    u.displayText,
];

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
  test('RTL：同一行带内右列先读，下一行带在后；LTR 镜像', () {
    final MokuroImage page = _page(<MokuroBlock>[
      _vertical(100, 100, 140, 300, '左です。'),
      _vertical(800, 100, 840, 300, '右です。'),
      _vertical(450, 1000, 490, 1200, '下です。'),
    ]);
    expect(_texts(page), <String>['右です。', '左です。', '下です。']);
    expect(_texts(page, rightToLeft: false), <String>['左です。', '右です。', '下です。']);
  });

  test('注音不进朗读文本，也不影响正文顺序', () {
    final MokuroImage withRuby = _page(<MokuroBlock>[_ruby, ..._body]);
    final MokuroImage withoutRuby = _page(_body);
    expect(_texts(withRuby), <String>['なに?', '大丈夫だよな?']);
    expect(_texts(withRuby), _texts(withoutRuby));
    for (final String text in _texts(withRuby)) {
      expect(text, isNot(contains('だいじょうぶ')));
    }
  });

  test('跨块的一句只读一次，组号与 overlay 的句子分组一致', () {
    final MokuroImage page = _page(<MokuroBlock>[_ruby, ..._body]);
    final List<MangaReadAloudUtterance> plan = planMangaPageReadAloud(
      page,
      pageIndex: 3,
      rightToLeft: true,
      pronunciation: const <TtsPronunciationRule>[],
      maxInputLength: 0,
    );
    expect(plan, hasLength(2));
    final MangaReadAloudUtterance joined = plan[1];
    expect(joined.pageIndex, 3);
    // 这一组包含注音块 + 三列正文（下标 0..3），不含右边的「なに?」（下标 4）。
    expect(mangaSentenceGroupBlockIndices(page, joined.group), <int>[
      0,
      1,
      2,
      3,
    ]);
    expect(mangaSentenceGroupBlockIndices(page, plan[0].group), <int>[4]);
  });

  test('只有标点的气泡跳过；发音词典生效；超长句按上限切块', () {
    final MokuroImage page = _page(<MokuroBlock>[
      _vertical(800, 100, 840, 300, '……！？'),
      _vertical(600, 100, 640, 300, '明日来る。'),
      _vertical(400, 100, 440, 300, 'あいうえおかきくけこ'),
    ]);
    final List<MangaReadAloudUtterance> plan = planMangaPageReadAloud(
      page,
      pageIndex: 0,
      rightToLeft: true,
      pronunciation: const <TtsPronunciationRule>[
        TtsPronunciationRule(written: '明日', spoken: 'あした'),
      ],
      maxInputLength: 4,
    );
    expect(plan.map((MangaReadAloudUtterance u) => u.displayText), <String>[
      '明日来る。',
      'あいうえおかきくけこ',
    ]);
    expect(plan[0].spokenChunks, <String>['あした来', 'る。']);
    expect(plan[1].spokenChunks, <String>['あいうえ', 'おかきく', 'けこ']);
  });

  test('空页没有句子', () {
    expect(_texts(_page(const <MokuroBlock>[])), isEmpty);
  });
}
