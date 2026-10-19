// 确定性的 Anki 媒体引用扫描语料：`anki_media_test.dart` 用它对原生实现复算摘要，与删除前
// 旧 Dart `MediaNameMatcher` 在同一语料上冻结的摘要比对（命中集合**和顺序**都算进摘要）。
//
// 语料只由本文件的代码与种子决定（自带 xorshift）；改了生成逻辑冻结摘要就作废，只能用旧实现
// 重新生成，不能改摘要了事。
import 'dart:convert';

/// 一组输入：一个匹配器的名字表 + 一批「组」（一组 = 一条笔记的全部字段）。
typedef AnkiMediaCase = ({List<String> names, List<List<String>> groups});

/// 被比对的实现：返回每组命中的名字（`Set` 的迭代序即命中序）。
typedef AnkiMediaScanner =
    List<Set<String>> Function(List<String> names, List<List<String>> groups);

final class _Rng {
  _Rng(this._state);

  int _state;

  int next() {
    int x = _state;
    x ^= x << 13;
    x ^= x >>> 7;
    x ^= x << 17;
    _state = x;
    return x >>> 1;
  }

  int below(int n) => next() % n;

  bool chance(int percent) => below(100) < percent;

  T pick<T>(List<T> values) => values[below(values.length)];
}

const List<String> _extensions = <String>[
  '.mp3',
  '.MP3',
  '.jpg',
  '.Png',
  '.webp',
  '.ogg',
  '.tar.gz',
  '.',
  '.ΣΑΣ',
  '.İ',
  '.\u{10400}',
];

const List<String> _stemAtoms = <String>[
  'a',
  'B',
  'x_1',
  'pic',
  'Pic',
  'paste-',
  'f6c1',
  '音声',
  'ラーメン',
  'İstanbul',
  'ΟΔΟΣ',
  'Straße',
  'ẞ',
  '\u{10400}\u{10401}',
  '\uD800',
  '\uDC00',
  'ǅ',
  '-',
  '.',
  ' ',
  '_',
];

String _stem(_Rng rng) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 1 + rng.below(4); i++) {
    out.write(rng.pick(_stemAtoms));
  }
  return out.toString();
}

String _name(_Rng rng) {
  if (rng.chance(3)) return '';
  if (rng.chance(8)) return _stem(rng);
  return '${_stem(rng)}${rng.pick(_extensions)}';
}

String _recase(_Rng rng, String text) => switch (rng.below(4)) {
  0 => text.toUpperCase(),
  1 => text.toLowerCase(),
  2 => String.fromCharCodes(<int>[
    for (final int unit in text.codeUnits)
      rng.chance(50) && unit < 0x80
          ? String.fromCharCode(unit).toUpperCase().codeUnitAt(0)
          : unit,
  ]),
  _ => text,
};

String _text(_Rng rng, List<String> names) {
  if (rng.chance(5)) return '';
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < rng.below(10); i++) {
    switch (rng.below(8)) {
      case 0:
        if (names.isNotEmpty)
          out.write('[sound:${_recase(rng, rng.pick(names))}]');
      case 1:
        if (names.isNotEmpty) {
          out.write('<img src="${_recase(rng, rng.pick(names))}">');
        }
      case 2:
        if (names.isNotEmpty) {
          final String name = rng.pick(names);
          // 名字的一截（只剩扩展名 / 掉了首字符等）。
          out.write(name.substring(rng.below(name.length + 1)));
        }
      case 3:
        out.write(rng.pick(_extensions));
      case 4:
        out.write(rng.pick(_stemAtoms));
      case 5:
        out.write(' ... ');
      case 6:
        if (names.isNotEmpty) out.write(_recase(rng, rng.pick(names)) * 2);
      default:
        out.write('<div>本文 ${rng.below(1000)}</div>');
    }
  }
  return out.toString();
}

/// 手写的代表样例（旧单测里的形态 + 大小写折叠的边界）。
const List<AnkiMediaCase> kHandWrittenAnkiCases = <AnkiMediaCase>[
  (
    names: <String>['a.mp3', 'Pic.PNG'],
    groups: <List<String>>[
      <String>['[sound:A.MP3] <img src="pic.png">'],
      <String>['[sound:ba.mp3x]'],
      <String>['a.mp4 pic.pn'],
      <String>[''],
      <String>[],
    ],
  ),
  (
    names: <String>['ab.mp3', 'b.mp3', 'xab.mp3'],
    groups: <List<String>>[
      <String>['<x>xab.mp3</x>'],
    ],
  ),
  (
    names: <String>['a.b.mp3', 'noext', 'Dup.jpg', 'dup.jpg', 'NoExt', ''],
    groups: <List<String>>[
      <String>['a.b.mp3'],
      <String>['xx NOEXT yy'],
      <String>['DUP.JPG'],
      <String>['dup.jpg a.b.mp3', 'NOEXT'],
    ],
  ),
  (
    names: <String>[
      'İ.png',
      'i.png',
      'ΟΔΟΣ.mp3',
      'οδοσ.mp3',
      'Straße.ogg',
      '\u{10400}.jpg',
    ],
    groups: <List<String>>[
      <String>['İ.PNG i.png'],
      <String>['ΟΔΟΣ.MP3', 'οδος.mp3'],
      <String>['STRASSE.OGG straße.ogg'],
      <String>['\u{10428}.JPG'],
    ],
  ),
  (
    names: <String>['x.', 'a.', '\uD800.mp3', 'b\uDC00.mp3'],
    groups: <List<String>>[
      <String>['x. a.. \uD800.MP3'],
      <String>['B\uDC00.MP3'],
    ],
  ),
];

/// 完整语料（确定性）。
List<AnkiMediaCase> buildAnkiMediaCorpus() {
  final List<AnkiMediaCase> cases = <AnkiMediaCase>[...kHandWrittenAnkiCases];
  final _Rng rng = _Rng(0x5eed2026);
  for (int c = 0; c < 300; c++) {
    final List<String> names = <String>[
      for (int i = 0; i < rng.below(30); i++) _name(rng),
    ];
    if (names.isNotEmpty && rng.chance(30)) names.add(rng.pick(names));
    if (names.isNotEmpty && rng.chance(30))
      names.add(rng.pick(names).toUpperCase());
    cases.add((
      names: names,
      groups: <List<String>>[
        for (int g = 0; g < rng.below(6); g++)
          <String>[for (int t = 0; t < rng.below(4); t++) _text(rng, names)],
      ],
    ));
  }
  return cases;
}

/// 结果的规范化描述：每组一行，命中名按迭代序 JSON 编码。
String describeAnkiOutcome(AnkiMediaCase input, AnkiMediaScanner scan) {
  final List<Set<String>> hits = scan(input.names, input.groups);
  return <String>[
    for (final Set<String> group in hits) jsonEncode(group.toList()),
  ].join(';');
}

/// 64 位 FNV-1a（对每条描述的 UTF-8 + 换行）。
int digestAnkiOutcomes(Iterable<String> outcomes) {
  int hash = 0xcbf29ce484222325;
  for (final String outcome in outcomes) {
    for (final int byte in utf8.encode('$outcome\n')) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
  }
  return hash;
}
