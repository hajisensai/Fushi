// TTS 整章切句的原生实现（ffc_parse_tts_split_utf16）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。库按 FushiCompute.instance 的默认
// 规则定位（本地跑时用环境变量 FUSHI_COMPUTE_LIB 指向 cargo 产物）。
//
// 期望值全部来自删掉的旧 Dart 实现（fushi/lib/src/media/audiobook/tts/tts_book_plan.dart
// 的 splitTtsText）：边界用例逐句钉、伪随机章节钉摘要。删 Dart 前还用旧实现对 41 本日文书 +
// 1 本英文书的全部章节（maxLength 8 / 40 / 120 / 300）逐句全字段对拍过，结果完全一致。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

// ---- 边界用例：输入与旧 Dart 实现的输出（start, end, spokenText） ----
typedef _Case = ({
  String name,
  String text,
  List<(int, int, String)> rubies,
  List<int> blockEnds,
  List<int> sceneBreaks,
  int maxLength,
});

final List<_Case> _cases = <_Case>[
  (
    name: 'empty',
    text: '',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'all whitespace',
    text: String.fromCharCodes(<int>[
      0x20,
      0x09,
      0x0A,
      0x3000,
      0xA0,
      0x2028,
      0xFEFF,
      0x20,
    ]),
    rubies: [],
    blockEnds: [3],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'long without punctuation',
    text: 'あ' * 300,
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'long without punctuation, minimum length',
    text: 'いろはにほへとちりぬるを' * 3,
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 8,
  ),
  (
    name: 'supplementary plane',
    text: '𠮷野家の𩸽を食べた。𠮷𠮷𠮷𠮷𠮷𠮷𠮷𠮷𠮷',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 8,
  ),
  (
    name: 'lone surrogates',
    text: '\ud800あ。\udc00い\ud83d',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'ruby across a sentence end',
    text: '彼は走。った。次。',
    rubies: [(2, 5, 'はしっ')],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'ruby filters',
    text: '漢字と漢字と漢字と漢字。',
    rubies: [
      (0, 2, 'かんじ'),
      (1, 3, 'じと'),
      (3, 5, '   '),
      (6, 8, 'あいうえおかきくけこ'),
      (9, 11, 'かんじ'),
      (9, 30, 'x'),
      (-1, 0, 'x'),
      (11, 11, 'x'),
    ],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 16,
  ),
  (
    name: 'ruby reading at exactly half the limit',
    text: '鬱。鬱。',
    rubies: [(0, 1, 'うつうつうつうつ'), (2, 3, 'うつうつうつうつう')],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 16,
  ),
  (
    name: 'ruby over punctuation',
    text: 'え!?ほんと」』',
    rubies: [(1, 3, 'びっくり'), (6, 8, 'かっこ')],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'ruby inside a surrogate pair',
    text: '𠮷あ𠮷い。',
    rubies: [(1, 3, 'x'), (3, 4, 'よし')],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'consecutive punctuation',
    text: '本当？！……！！」」次。。。です\n\n終わり',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'nested quotes',
    text: '「彼は『いや』と言った。」そして『「ああ」』。「『え？』」',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'english abbreviations',
    text:
        'Mr. Smith went to Washington. He said "Hi!" (e.g. here) U.S.A. is big? Yes; really: no, maybe.',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 40,
  ),
  (
    name: 'hard breaks unsorted, duplicated, out of range',
    text: '見出し本文です。場面◇◇◇次の場面',
    rubies: [],
    blockEnds: [8, 3, 3, -1, 1000],
    sceneBreaks: [11, 3],
    maxLength: 120,
  ),
  (
    name: 'hard break inside a ruby',
    text: '漢字です。',
    rubies: [(0, 2, 'かんじ')],
    blockEnds: [1],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'soft breaks',
    text: 'あいう、えおか，きくけ；こさし：すせそ,たちつ;てと:なにぬねの。',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 8,
  ),
  (
    name: 'closer after whitespace',
    text: 'あ。 」い。　）う',
    rubies: [],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
  (
    name: 'whitespace-only ruby reading is ignored but blank atoms trimmed',
    text: '  あ  ',
    rubies: [(2, 3, '　')],
    blockEnds: [],
    sceneBreaks: [],
    maxLength: 120,
  ),
];

const List<List<(int, int, String)>> _expected = <List<(int, int, String)>>[
  // empty
  <(int, int, String)>[],
  // all whitespace
  <(int, int, String)>[],
  // long without punctuation
  <(int, int, String)>[
    (
      0,
      120,
      'ああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああ',
    ),
    (
      120,
      240,
      'ああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああ',
    ),
    (240, 300, 'ああああああああああああああああああああああああああああああああああああああああああああああああああああああああああああ'),
  ],
  // long without punctuation, minimum length
  <(int, int, String)>[
    (0, 8, 'いろはにほへとち'),
    (8, 16, 'りぬるをいろはに'),
    (16, 24, 'ほへとちりぬるを'),
    (24, 32, 'いろはにほへとち'),
    (32, 36, 'りぬるを'),
  ],
  // supplementary plane
  <(int, int, String)>[
    (0, 8, '𠮷野家の𩸽を'),
    (8, 12, '食べた。'),
    (12, 20, '𠮷𠮷𠮷𠮷'),
    (20, 28, '𠮷𠮷𠮷𠮷'),
    (28, 30, '𠮷'),
  ],
  // lone surrogates
  <(int, int, String)>[(0, 3, '\ud800あ。'), (3, 6, '\udc00い\ud83d')],
  // ruby across a sentence end
  <(int, int, String)>[(0, 7, '彼ははしった。'), (7, 9, '次。')],
  // ruby filters
  <(int, int, String)>[(0, 12, 'かんじと漢字と漢字とかんじ。')],
  // ruby reading at exactly half the limit
  <(int, int, String)>[(0, 2, 'うつうつうつうつ。'), (2, 4, '鬱。')],
  // ruby over punctuation
  <(int, int, String)>[(0, 3, 'えびっくり'), (3, 8, 'ほんとかっこ')],
  // ruby inside a surrogate pair
  <(int, int, String)>[(0, 7, '𠮷あよし\udfb7い。')],
  // consecutive punctuation
  <(int, int, String)>[
    (0, 10, '本当？！\u2026\u2026！！」」'),
    (10, 14, '次。。。'),
    (14, 16, 'です'),
    (18, 21, '終わり'),
  ],
  // nested quotes
  <(int, int, String)>[
    (0, 7, '「彼は『いや』'),
    (7, 13, 'と言った。」'),
    (13, 23, 'そして『「ああ」』。'),
    (23, 29, '「『え？』」'),
  ],
  // english abbreviations
  <(int, int, String)>[
    (0, 40, 'Mr. Smith went to Washington. He said "H'),
    (40, 42, 'i!'),
    (42, 70, '" (e.g. here) U.S.A. is big?'),
    (71, 94, 'Yes; really: no, maybe.'),
  ],
  // hard breaks unsorted, duplicated, out of range
  <(int, int, String)>[
    (0, 3, '見出し'),
    (3, 8, '本文です。'),
    (8, 11, '場面\u25c7'),
    (11, 17, '\u25c7\u25c7次の場面'),
  ],
  // hard break inside a ruby
  <(int, int, String)>[(0, 2, 'かんじ'), (2, 5, 'です。')],
  // soft breaks
  <(int, int, String)>[
    (0, 8, 'あいう、えおか，'),
    (8, 16, 'きくけ；こさし：'),
    (16, 24, 'すせそ,たちつ;'),
    (24, 27, 'てと:'),
    (27, 33, 'なにぬねの。'),
  ],
  // closer after whitespace
  <(int, int, String)>[(0, 2, 'あ。'), (3, 4, '」'), (4, 6, 'い。'), (7, 9, '）う')],
  // whitespace-only ruby reading is ignored but blank atoms trimmed
  <(int, int, String)>[(2, 3, 'あ')],
];

// ---- 伪随机章节（与旧实现对拍后钉摘要）：输入生成与输出摘要，测试里同一份 ----

typedef _FuzzInput = ({
  String text,
  List<(int, int, String)> rubies,
  List<int> blockEnds,
  List<int> sceneBreaks,
  int maxLength,
});

/// 码元池：假名 / 汉字 / 标点 / 收尾括号 / 软切点 / 空白 / 英文 / 补充平面 / 孤立代理。
const List<String> _fuzzAlphabet = <String>[
  'あ',
  'い',
  'う',
  'ア',
  'ン',
  '漢',
  '字',
  '々',
  'a',
  'B',
  '7',
  '.',
  '。',
  '！',
  '？',
  '!',
  '?',
  '…',
  '\n',
  '」',
  '』',
  '”',
  '’',
  '）',
  ')',
  ']',
  '】',
  '〉',
  '》',
  '»',
  '「',
  '『',
  '、',
  '，',
  ',',
  '；',
  ';',
  '：',
  ':',
  ' ',
  '　',
  '\t',
  '𠮷',
  '𩸽',
];

int _fuzzSeed = 1;
int _next(int bound) {
  _fuzzSeed = (_fuzzSeed * 1103515245 + 12345) & 0x7fffffff;
  return _fuzzSeed % bound;
}

List<_FuzzInput> _fuzzInputs() {
  _fuzzSeed = 20261018;
  final List<_FuzzInput> out = <_FuzzInput>[];
  const List<int> lengths = <int>[8, 13, 40, 120];
  for (int c = 0; c < 400; c++) {
    final StringBuffer b = StringBuffer();
    final int atoms = _next(600);
    for (int k = 0; k < atoms; k++) {
      final int r = _next(100);
      if (r < 2) {
        b.writeCharCode(0xD800 + _next(0x800)); // 孤立代理（偶尔恰好拼成合法对）
      } else {
        b.write(_fuzzAlphabet[_next(_fuzzAlphabet.length)]);
      }
    }
    final String text = b.toString();
    final int n = text.length;
    final List<(int, int, String)> rubies = <(int, int, String)>[];
    int at = 0;
    while (n > 0 && at < n && _next(4) != 0) {
      at += _next(30);
      final int start = _next(10) == 0 ? at - _next(5) : at; // 偶尔回退 → 重叠
      final int end = start + _next(5) - (_next(20) == 0 ? 4 : 0);
      final int readingLength = _next(10) == 0 ? 0 : 1 + _next(9);
      final StringBuffer reading = StringBuffer();
      for (int k = 0; k < readingLength; k++) {
        reading.write(_next(15) == 0 ? ' ' : 'かな𠮷'[_next(3)]);
      }
      rubies.add((start, end + (_next(40) == 0 ? n : 0), reading.toString()));
      at = end > at ? end : at + 1;
    }
    final List<int> blockEnds = <int>[
      for (int k = _next(12); k > 0; k--) _next(n + 3) - 1,
    ];
    final List<int> sceneBreaks = <int>[
      for (int k = _next(4); k > 0; k--) _next(n + 3) - 1,
    ];
    out.add((
      text: text,
      rubies: rubies,
      blockEnds: blockEnds,
      sceneBreaks: sceneBreaks,
      maxLength: lengths[_next(lengths.length)],
    ));
  }
  return out;
}

int _fnv = 0;
void _mixInt(int v) {
  for (int k = 0; k < 4; k++) {
    _fnv ^= (v >> (k * 8)) & 0xff;
    _fnv = (_fnv * 0x01000193) & 0xffffffff;
  }
}

void _mixString(String s) {
  _mixInt(s.length);
  for (int i = 0; i < s.length; i++) {
    _mixInt(s.codeUnitAt(i));
  }
}

/// 全部伪随机章节切句结果（句数、每句 start / end / text / spokenText）的 32 位 FNV-1a。
int _fuzzDigest(
  List<({int start, int end, String text, String spokenText})> Function(
    _FuzzInput input,
  )
  split,
) {
  _fnv = 0x811c9dc5;
  for (final _FuzzInput input in _fuzzInputs()) {
    final List<({int start, int end, String text, String spokenText})> segs =
        split(input);
    _mixInt(segs.length);
    for (final ({int start, int end, String text, String spokenText}) s
        in segs) {
      _mixInt(s.start);
      _mixInt(s.end);
      _mixString(s.text);
      _mixString(s.spokenText);
    }
  }
  return _fnv;
}

/// 旧 Dart 实现对 [_fuzzInputs] 全部 400 章（12.5 万码元、2.2 万句，其中 795 句含 ruby
/// 读音）的 [_fuzzDigest] 是 `0x5b5451ff`。
///
/// BUG-3773 有意改了一条语义：读音里没有任何文字的 ruby（傍点 `・・` / `﹅` / `●`）不再收、
/// 底本照原文读，所以伪随机章节里这类 ruby 的句子与旧实现不同，摘要随之变成下面这个值。
/// 核对过：只去掉 `tts_split.rs` 的 `is_emphasis_only` 判定重编，摘要回到 `0x5b5451ff`
/// （其余语义与旧 Dart 实现仍逐句一致）。旧 Dart 实现已删除，无法再按它重算。
const int _fuzzDigestAfterBug3773 = 0x5c1b42ce;

List<TtsSplitSegment> _split(
  String text, {
  List<(int, int, String)> rubies = const <(int, int, String)>[],
  List<int> blockEnds = const <int>[],
  List<int> sceneBreaks = const <int>[],
  required int maxLength,
}) => TtsSplitNative.instance.split(
  text,
  rubies: <TtsSplitRuby>[
    for (final (int start, int end, String reading) in rubies)
      (start: start, end: end, reading: reading),
  ],
  blockEnds: blockEnds,
  sceneBreaks: sceneBreaks,
  maxLength: maxLength,
);

void main() {
  setUpAll(() {
    // 硬依赖：库不可用时 instance 抛 FushiComputeUnavailableError，整组失败。
    expect(
      () => TtsSplitNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('边界用例与旧 Dart 实现逐句一致', () {
    expect(_cases, hasLength(_expected.length));
    for (int c = 0; c < _cases.length; c++) {
      final _Case input = _cases[c];
      final List<TtsSplitSegment> segs = _split(
        input.text,
        rubies: input.rubies,
        blockEnds: input.blockEnds,
        sceneBreaks: input.sceneBreaks,
        maxLength: input.maxLength,
      );
      expect(
        <(int, int, String)>[
          for (final TtsSplitSegment s in segs) (s.start, s.end, s.spokenText),
        ],
        _expected[c],
        reason: input.name,
      );
      for (final TtsSplitSegment s in segs) {
        expect(
          s.text,
          input.text.substring(s.start, s.end),
          reason: input.name,
        );
      }
    }
  });

  test('伪随机章节摘要与旧 Dart 实现（加 BUG-3773 傍点规则）一致', () {
    final int digest = _fuzzDigest((_FuzzInput input) {
      return <({int start, int end, String text, String spokenText})>[
        for (final TtsSplitSegment s in _split(
          input.text,
          rubies: input.rubies,
          blockEnds: input.blockEnds,
          sceneBreaks: input.sceneBreaks,
          maxLength: input.maxLength,
        ))
          (start: s.start, end: s.end, text: s.text, spokenText: s.spokenText),
      ];
    });
    expect(digest, _fuzzDigestAfterBug3773);
  });

  test('空白判定与 Dart String.trim 逐码点一致', () {
    // 每个码点各占一句（每个位置都是硬句界）：空白码点不成句，其余各成一句。
    // 代理区单独放在最后、按降序排，避免高代理后紧跟低代理被合成一对。
    final List<int> codePoints = <int>[
      for (int cp = 0; cp <= 0x10FFFF; cp++)
        if (cp < 0xD800 || cp > 0xDFFF) cp,
      for (int cp = 0xDFFF; cp >= 0xD800; cp--) cp,
    ];
    final StringBuffer text = StringBuffer();
    final List<int> breaks = <int>[];
    final List<(int, int)> expected = <(int, int)>[];
    int offset = 0;
    for (final int cp in codePoints) {
      final String ch = String.fromCharCode(cp);
      text.write(ch);
      if (ch.trim().isNotEmpty) expected.add((offset, offset + ch.length));
      offset += ch.length;
      breaks.add(offset);
    }
    final List<TtsSplitSegment> segs = _split(
      text.toString(),
      blockEnds: breaks,
      maxLength: 8,
    );
    expect(<(int, int)>[
      for (final TtsSplitSegment s in segs) (s.start, s.end),
    ], expected);
  });

  test('maxLength 小于 8 抛 ArgumentError', () {
    expect(() => _split('あ。', maxLength: 7), throwsArgumentError);
  });

  test('句内没有 ruby 时合成文本就是原文', () {
    final List<TtsSplitSegment> segs = _split(
      '漢字。かな。',
      rubies: const <(int, int, String)>[(0, 2, 'かんじ')],
      maxLength: 120,
    );
    expect(segs.map((TtsSplitSegment s) => s.spokenText), <String>[
      'かんじ。',
      'かな。',
    ]);
  });
}
