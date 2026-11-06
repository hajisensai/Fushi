import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

/// [AudioTextNormalizer] 已搬进 Rust（`native/fushi_compute/src/parse/fold.rs`），没有
/// Dart 回退。下面的摘要由删除前的旧 Dart 实现（e35042dda1 的 `foldCodePoint` /
/// `normalizeWithOffsets`）生成，钉住逐码点与整段（含偏移）输出完全一致：
///
/// - [_kPerCodePointDigest]：0..0x10FFFF 每个码点的折叠结果（丢弃记 -1），按小端 i32
///   喂 FNV-1a 32 位。Rust 侧 `fold_matches_dart_digest` 钉同一个值。
/// - [_syntheticDigests]：确定性伪随机 UTF-16 串（白名单各段 / 白名单外 / 补充平面 /
///   孤立代理）的 `normalizeWithOffsets` 结果（文本码元 + starts + ends）摘要。
///
/// 原生库找不到时本测试直接失败（硬依赖，不 skip）。
const int _kPerCodePointDigest = 0x078eced4;

const List<(int, int, int)> _syntheticDigests = <(int, int, int)>[
  // (长度, 种子, 摘要)
  (1 << 20, 0x12345678, 0x6b035e03),
  (4097, 0x9e3779b9, 0x6d9ca606),
];

int _fnvI32(int hash, int v) {
  for (int k = 0; k < 4; k++) {
    hash ^= (v >> (8 * k)) & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

const int _fnvOffset = 0x811c9dc5;

String _syntheticText(int length, int seed) {
  int state = seed;
  int next() {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    return state & 0xFFFFFFFF;
  }

  const List<(int, int)> ranges = <(int, int)>[
    (0x20, 0x7E),
    (0x3000, 0x30FF),
    (0x4E00, 0x9FFF),
    (0xFF00, 0xFFEF),
    (0x2E80, 0x2FDF),
    (0xF900, 0xFAFF),
    (0x25C0, 0x25FF),
    (0x3400, 0x4DBF),
  ];
  final List<int> units = <int>[];
  while (units.length < length) {
    final int r = next() % 100;
    if (r < 70) {
      final (int lo, int hi) = ranges[next() % ranges.length];
      units.add(lo + next() % (hi - lo + 1));
    } else if (r < 80) {
      units.add(next() % 0x10000);
    } else if (r < 92) {
      final int v = next() % 0x100000;
      units
        ..add(0xD800 + (v >> 10))
        ..add(0xDC00 + (v & 0x3FF));
    } else if (r < 97) {
      final int v = 0x20000 + next() % 0x13000 - 0x10000;
      units
        ..add(0xD800 + (v >> 10))
        ..add(0xDC00 + (v & 0x3FF));
    } else {
      units.add(0xD800 + next() % 0x800);
    }
  }
  return String.fromCharCodes(units);
}

int _digestWithOffsets(NormalizedTextWithOffsets n) {
  int h = _fnvOffset;
  h = _fnvI32(h, n.text.length);
  for (int i = 0; i < n.text.length; i++) {
    h = _fnvI32(h, n.text.codeUnitAt(i));
  }
  for (final int v in n.starts) {
    h = _fnvI32(h, v);
  }
  for (final int v in n.ends) {
    h = _fnvI32(h, v);
  }
  return h;
}

String _hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

void main() {
  test('逐码点折叠与旧 Dart 实现的全码点摘要一致', () {
    // 非代理码点拼成一整串（代理对编码补充平面），一次调用；按 starts 还原每个输入码点的结果。
    final List<int> results = List<int>.filled(0x110000, -1);
    final StringBuffer all = StringBuffer();
    final List<int> unitToCodePoint = <int>[];
    for (int cp = 0; cp < 0x110000; cp++) {
      if (cp >= 0xD800 && cp <= 0xDFFF) continue;
      all.writeCharCode(cp);
      unitToCodePoint.add(cp);
      if (cp > 0xFFFF) unitToCodePoint.add(-1);
    }
    final NormalizedTextWithOffsets n =
        AudioTextNormalizer.normalizeWithOffsets(all.toString());
    for (int j = 0; j < n.text.length; j++) {
      final int cp = unitToCodePoint[n.starts[j]];
      final int unit = n.text.codeUnitAt(j);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        results[cp] =
            n.text.codeUnitAt(j + 1) -
            0xDC00 +
            ((unit - 0xD800) << 10) +
            0x10000;
        j++;
      } else {
        results[cp] = unit;
      }
    }
    // 孤立代理（Dart `runes` 按码元值本身给出）逐个单独喂，免得相邻高低代理拼成一对。
    for (int u = 0xD800; u <= 0xDFFF; u++) {
      final String out = AudioTextNormalizer.normalize(String.fromCharCode(u));
      if (out.isNotEmpty) results[u] = out.runes.single;
    }
    int h = _fnvOffset;
    for (final int v in results) {
      h = _fnvI32(h, v);
    }
    expect(_hex(h), _hex(_kPerCodePointDigest));
  });

  for (final (int length, int seed, int digest) in _syntheticDigests) {
    test('伪随机 UTF-16 串（长 $length）normalizeWithOffsets 摘要一致', () {
      final String s = _syntheticText(length, seed);
      final NormalizedTextWithOffsets n =
          AudioTextNormalizer.normalizeWithOffsets(s);
      expect(_hex(_digestWithOffsets(n)), _hex(digest));
      expect(n.starts.length, n.text.length);
      expect(n.ends.length, n.text.length);
      expect(AudioTextNormalizer.normalize(s), n.text);
    });
  }

  test('代表样本', () {
    expect(
      AudioTextNormalizer.normalize('「カタカナ、ＡＢＣ」ｶﾀｶﾅabcDEF１２３'),
      'かたかなabcかたかなabcdef123',
    );
    expect(AudioTextNormalizer.normalize('ヴァー・ヽヾ'), 'ゔぁーヽヾ');
    expect(AudioTextNormalizer.normalize(''), '');
    expect(AudioTextNormalizer.normalize('、。！？'), '');
    expect(AudioTextNormalizer.normalize('😀x'), 'x');
  });

  test('补充平面汉字：两个输出码元映到同一原文区间', () {
    final NormalizedTextWithOffsets n =
        AudioTextNormalizer.normalizeWithOffsets('a𠮷、b');
    expect(n.text, 'a𠮷b');
    expect(n.starts, <int>[0, 1, 1, 4]);
    expect(n.ends, <int>[1, 3, 3, 5]);
    expect(n.originalSlice('a𠮷、b', 1, 4), '𠮷、b');
  });

  test('孤立代理丢弃，不与相邻码元拼对', () {
    final String s = String.fromCharCodes(<int>[
      0x61,
      0xD800,
      0x62,
      0xDC00,
      0xD840,
    ]);
    final NormalizedTextWithOffsets n =
        AudioTextNormalizer.normalizeWithOffsets(s);
    expect(n.text, 'ab');
    expect(n.starts, <int>[0, 2]);
    expect(n.ends, <int>[1, 3]);
  });

  test('appendNormalized 等价于分段 normalize 拼接', () {
    final StringBuffer buf = StringBuffer('x');
    AudioTextNormalizer.appendNormalized(buf, 'アイ、');
    AudioTextNormalizer.appendNormalized(buf, '');
    AudioTextNormalizer.appendNormalized(buf, 'ＵＰ');
    expect(buf.toString(), 'xあいup');
  });

  test('normalizeConcat 等价于逐段 appendNormalized，段起点按段前总长', () {
    final List<String> pieces = <String>[
      'アイ、',
      '',
      '。',
      'ＵＰ',
      // 相邻段首尾的孤立代理不能拼成一个代理对（逐段 runes 解码的口径）。
      String.fromCharCodes(<int>[0x6F22, 0xD842]),
      String.fromCharCodes(<int>[0xDFB7, 0x5B57]),
      '𠮷',
      '',
    ];
    final StringBuffer buf = StringBuffer();
    final List<int> starts = <int>[];
    for (final String p in pieces) {
      starts.add(buf.length);
      AudioTextNormalizer.appendNormalized(buf, p);
    }
    final ({String text, List<int> starts}) joined =
        AudioTextNormalizer.normalizeConcat(pieces);
    expect(joined.text, buf.toString());
    expect(joined.text, 'あいup漢字𠮷');
    expect(joined.starts, starts);
    expect(AudioTextNormalizer.normalizeConcat(<String>[]).text, '');
    expect(AudioTextNormalizer.normalizeConcat(<String>['', '']).starts, <int>[
      0,
      0,
    ]);
    // 固定种子的随机段：与逐段拼接逐码元一致。
    int seed = 20261019;
    const String alphabet = 'ア、aZ１ｶﾞ漢 。\u0301';
    for (int round = 0; round < 300; round++) {
      final List<String> ps = <String>[
        for (int k = 0; k < round % 7; k++)
          String.fromCharCodes(<int>[
            for (int i = 0; i < (k * 5 + round) % 9; i++)
              () {
                seed = (seed * 1103515245 + 12345) & 0x7fffffff;
                final int r = seed % (alphabet.length + 3);
                return r < alphabet.length
                    ? alphabet.codeUnitAt(r)
                    : <int>[0xD842, 0xDFB7, 0xDC00][r - alphabet.length];
              }(),
          ]),
      ];
      final StringBuffer b = StringBuffer();
      final List<int> st = <int>[];
      for (final String p in ps) {
        st.add(b.length);
        AudioTextNormalizer.appendNormalized(b, p);
      }
      final ({String text, List<int> starts}) j =
          AudioTextNormalizer.normalizeConcat(ps);
      expect(j.text, b.toString(), reason: '$ps');
      expect(j.starts, st, reason: '$ps');
    }
  });
}
