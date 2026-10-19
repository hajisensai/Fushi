// ffc_text_align_positions 回归向量的确定性输入（只依赖 dart:core）。
//
// 冻结向量（test/fixtures/text_align_positions_vectors.json）由删除前的纯 Dart 实现
// （fushi_audio `CueSentenceResegmenter._alignPositions`）对这里生成的输入算出。改这里的
// 任何一个数字都会让向量作废——只能追加新用例，不能改旧用例。
library;

/// splitmix64（Dart VM 的 int 是 64 位补码，乘法按 2^64 回绕，跨平台确定）。
final class AlignRng {
  AlignRng(this._state);

  int _state;

  int nextU64() {
    _state = _state + 0x9E3779B97F4A7C15;
    int z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// [0, bound)。
  int nextInt(int bound) => (nextU64() >>> 1) % bound;
}

/// 一组对齐输入：[a] = cue 的归一化听写，[b] = 命中的正文切片。
typedef AlignCase = ({String id, List<(String, String)> pairs, int maxCells});

/// 假名 + 常用汉字 + 长音 + 一个代理对（𠮷），模拟归一化后的日语听写 / 正文。
const String _alphabet =
    'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'
    'がぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽゃゅょっー'
    '日本語学校先生時間今何私彼女言思見行来出入上下中大小';

String _word(AlignRng rng, int length) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < length; i++) {
    if (rng.nextInt(97) == 0) {
      out.write('𠮷');
    } else {
      out.write(_alphabet[rng.nextInt(_alphabet.length)]);
    }
  }
  return out.toString();
}

/// 把 [b] 按 ASR 的典型错法改写：替换（同音错字）、漏字、多字、整段截断。
String _mutate(AlignRng rng, String b, int ratePerMille) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < b.length) {
    final int roll = rng.nextInt(1000);
    if (roll < ratePerMille ~/ 3) {
      out.write(_alphabet[rng.nextInt(_alphabet.length)]);
      i++;
    } else if (roll < ratePerMille * 2 ~/ 3) {
      i++; // 漏字
    } else if (roll < ratePerMille) {
      out.write(_alphabet[rng.nextInt(_alphabet.length)]);
      out.write(b[i]);
      i++;
    } else {
      out.write(b[i]);
      i++;
    }
  }
  return out.toString();
}

List<AlignCase> alignCases() {
  final AlignRng rng = AlignRng(2323);
  final List<(String, String)> typical = <(String, String)>[];
  for (int k = 0; k < 400; k++) {
    final String b = _word(rng, 2 + rng.nextInt(60));
    typical.add((_mutate(rng, b, 30 + rng.nextInt(300)), b));
  }
  final List<(String, String)> heavy = <(String, String)>[];
  for (int k = 0; k < 40; k++) {
    final String b = _word(rng, 200 + rng.nextInt(400));
    heavy.add((_mutate(rng, b, 100 + rng.nextInt(500)), b));
  }
  final List<(String, String)> overBudget = <(String, String)>[];
  for (int k = 0; k < 6; k++) {
    final String b = _word(rng, 700 + rng.nextInt(300));
    overBudget.add((_mutate(rng, b, 150), b));
  }
  return <AlignCase>[
    (
      id: 'edge',
      pairs: <(String, String)>[
        ('', ''),
        ('', 'あいう'),
        ('あいう', ''),
        ('あ', 'あ'),
        ('あ', 'い'),
        ('あいう', 'あいう'),
        ('ああああ', 'あ'),
        ('あ', 'ああああ'),
        ('あいあい', 'いあいあ'),
        ('abcabc', 'cbacba'),
        ('𠮷野家', '吉野家'),
        ('𠮷', '𠮷𠮷'),
        ('きょうはいいてんき', '今日はいい天気'),
        ('とうきょう', 'とーきょー'),
      ],
      maxCells: 400000,
    ),
    (id: 'typical-400', pairs: typical, maxCells: 400000),
    (id: 'heavy-40', pairs: heavy, maxCells: 400000),
    (id: 'over-budget-linear', pairs: overBudget, maxCells: 400000),
    (id: 'tiny-budget', pairs: typical.sublist(0, 80), maxCells: 50),
    (id: 'zero-budget', pairs: typical.sublist(80, 120), maxCells: 0),
  ];
}
