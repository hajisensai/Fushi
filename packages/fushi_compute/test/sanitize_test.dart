// 阅读器章节 HTML / CSS 清洗链的原生实现（ffc_parse_sanitize_*）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。库按 FushiCompute.instance 的默认
// 规则定位（本地跑时用环境变量 FUSHI_COMPUTE_LIB 指向 cargo 产物）。
//
// 删 Dart 实现前，用旧 Dart 正则实现（fushi/lib/src/reader/reader_resource_sanitizer.dart
// 的 sanitizeXhtml / markImagesLazy / injectImagesAfterBodyOpen / injectReaderHead /
// sanitizeCss，前面接 utf8.decode(allowMalformed: true)、后面接 utf8.encode）冻结了下面的
// 期望值：代表样例的逐字输出，以及两组语料（模糊用例、BMP 每个码点放进所有判定位置）的
// 输出摘要。另外对全部真书章节与 CSS 逐文件比过 SHA-1（不入库），全部一致。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

const String kHeadStart =
    '<style id="fushi-cloak">body{visibility:hidden!important}</style>';
const String kHeadEnd =
    '<meta name="viewport" content="width=device-width">\n'
    '<style>html{font-family:"明朝"}</style>';
const String kImages =
    '<div class="fushi-merged-image"><img src="a.png" class="block-img" '
    'loading="eager"/></div>';

/// (步骤位, 插图串)：单步 + 生产的两种组合（普通章 / 纯图片章带合并插图）。
const List<(int, String)> kOps = <(int, String)>[
  (1, ''),
  (2, ''),
  (4, kImages),
  (8, ''),
  (15, ''),
  (13, kImages),
];

const List<String> kFuzzTokens = <String>[
  '<',
  '>',
  '/',
  '"',
  "'",
  ' ',
  '\t',
  '\n',
  '\r',
  '=',
  ':',
  ';',
  '{',
  '}',
  'img',
  'IMG',
  'Img',
  'a',
  'A',
  'p',
  'body',
  'BODY',
  'head',
  '</head',
  'HEAD',
  'header',
  '-epub-',
  'writing-mode',
  'hyphens',
  'text-combine',
  'class',
  'gaiji',
  'loading',
  'script',
  'br',
  'hr',
  '_',
  '-',
  '　',
  ' ',
  ' ',
  ' ',
  '\u0085',
  '\u000b',
  '\u000c',
  'ſ',
  'ı',
  'K',
  'あ',
  '😀',
  '﻿',
  '<!--',
  '-->',
  '<![CDATA[',
  ']]>',
  'x',
  '1',
  '&amp;',
];

const List<List<int>> kFuzzBadBytes = <List<int>>[
  <int>[0xFF],
  <int>[0xC3],
  <int>[0xE3, 0x81],
  <int>[0xED, 0xA0, 0x80],
  <int>[0xF0, 0x9F],
  <int>[0x80],
  <int>[0xC0, 0x80],
  <int>[0xF8, 0x88],
];

/// 确定性伪随机（32 位 LCG），不依赖 dart:math 的 Random 实现细节。
final class Lcg {
  Lcg(this._state);
  int _state;
  int next(int bound) {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return (_state >> 8) % bound;
  }
}

/// 第 [count] 个模糊用例的原始字节（标记 token + 非法 UTF-8 片段随机拼接）。
List<List<int>> fuzzCorpus(int count, List<int> Function(String) encode) {
  final Lcg rnd = Lcg(20261018);
  final List<List<int>> out = <List<int>>[];
  for (int c = 0; c < count; c++) {
    final List<int> bytes = <int>[];
    final int n = 1 + rnd.next(40);
    for (int i = 0; i < n; i++) {
      if (rnd.next(12) == 0) {
        bytes.addAll(kFuzzBadBytes[rnd.next(kFuzzBadBytes.length)]);
      } else {
        bytes.addAll(encode(kFuzzTokens[rnd.next(kFuzzTokens.length)]));
      }
    }
    out.add(bytes);
  }
  return out;
}

/// 每个码点 [c] 放进所有「字符类 / 大小写折叠 / 空白集合 / 行终止符」决定结果的位置。
String codePointComposite(String c) =>
    '<html><head$c>\n</head$c>\n<body$c>'
    '<a$c/$c>'
    '<a $c/>'
    '<${c}b/>'
    '<im$c src=a>'
    '<i${c}g src=a>'
    '<img$c src=a>'
    '<img loading$c=x>'
    '<img ${c}loading=x>'
    '<img load${c}ng=x>'
    '<img class$c=${c}gaiji>'
    '<img class="$c gaiji">'
    '<img class="${c}gaiji">'
    '<img clas$c="gaiji">'
    '<img class="ga${c}ji">'
    '<${c}mg src=a>'
    '<b${c}dy>'
    '</h${c}ad>'
    '</body></html>\n'
    '$c-epub-${c}hyphens$c:${c}auto$c;\n'
    '-epub-x$c:y;$c-epub-writing-mode:v;\n'
    '-epub-text-combine:$c;';

/// 32 位 FNV-1a 摘要累加器。
final class Fnv {
  int hash = 0x811c9dc5;
  void add(List<int> bytes) {
    for (final int b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
  }

  void mark(int b) => add(<int>[b]);
}

/// 旧实现的摘要（见文件头）。
const int _oldFuzzDigest = 0xe0e1715c;
const int _oldCodePointDigest = 0x66ee2ce4;

/// (输入, 步骤位, 插图串, 旧实现输出)。输入按磁盘字节（UTF-8 编码后）喂给链。
const List<(String, int, String, String)>
_htmlSamples = <(String, int, String, String)>[
  ('<a id="toc-1"/><p>本文</p>', 1, '', '<a id="toc-1"></a><p>本文</p>'),
  (
    '<A HREF="a/>b"/><br/><Script src=x />',
    1,
    '',
    '<A HREF="a/>b"></A><br/><Script src=x></Script>',
  ),
  (
    '<a- /><ab_c/><p\u{3000}/\u{3000}><a title="open/>',
    1,
    '',
    '<a-></a><ab_c/><p></p><a title="open/>',
  ),
  ('<br title="<a/>"/><title/>', 1, '', '<br title="<a/>"/><title></title>'),
  (
    '<!-- <a/> --><![CDATA[<b/>]]>',
    1,
    '',
    '<!-- <a></a> --><![CDATA[<b></b>]]>',
  ),
  (
    '<IMG SRC=a><img loading="eager"><img class="x gaiji-line" src=g>',
    2,
    '',
    '<img loading="lazy" decoding="async" SRC=a><img loading="eager"><img class="x gaiji-line" src=g>',
  ),
  (
    '<img class="xgaiji"><img xloading=1><imgx><img alt="a>b" src=c/>',
    2,
    '',
    '<img loading="lazy" decoding="async" class="xgaiji"><img loading="lazy" decoding="async" xloading=1><imgx><img loading="lazy" decoding="async" alt="a>b" src=c/>',
  ),
  ('<img alt="unterminated', 2, '', '<img alt="unterminated'),
  (
    '<html><body class="a>b"><p>x</p></body></html>',
    4,
    kImages,
    '<html><body class="a>\n<div class="fushi-merged-image"><img src="a.png" class="block-img" loading="eager"/></div>\nb"><p>x</p></body></html>',
  ),
  (
    '<p>no body</p>',
    4,
    kImages,
    '\n<div class="fushi-merged-image"><img src="a.png" class="block-img" loading="eager"/></div>\n<p>no body</p>',
  ),
  (
    '<html><head><title>t</title></head><body></body></html>',
    8,
    '',
    '<html><head>\n<style id="fushi-cloak">body{visibility:hidden!important}</style><title>t</title>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n</head><body></body></html>',
  ),
  (
    '<HTML><HEAD>\r\n</HEAD  ><BODY>',
    8,
    '',
    '<HTML><HEAD>\n<style id="fushi-cloak">body{visibility:hidden!important}</style>\r\n\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n</HEAD  ><BODY>',
  ),
  (
    '<head><meta charset="utf-8"/>',
    8,
    '',
    '<head>\n<style id="fushi-cloak">body{visibility:hidden!important}</style>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style><meta charset="utf-8"/>',
  ),
  (
    '<p>fragment</p>',
    8,
    '',
    '<style id="fushi-cloak">body{visibility:hidden!important}</style>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n<p>fragment</p>',
  ),
  (
    '<header>x</header></head\t>',
    8,
    '',
    '<header>\n<style id="fushi-cloak">body{visibility:hidden!important}</style>x</header>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n</head\t>',
  ),
  (
    '\u{feff}<?xml version="1.0"?><html><head/><body><a id="x"/><img src="p.png"/></body></html>',
    15,
    '',
    '<?xml version="1.0"?><html><head>\n<style id="fushi-cloak">body{visibility:hidden!important}</style>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n</head><body><a id="x"></a><img loading="lazy" decoding="async" src="p.png"/></body></html>',
  ),
  (
    '<html><head></head><body><img src="p1.png"/></body></html>',
    13,
    kImages,
    '<html><head>\n<style id="fushi-cloak">body{visibility:hidden!important}</style>\n<meta name="viewport" content="width=device-width">\n<style>html{font-family:"明朝"}</style>\n</head><body>\n<div class="fushi-merged-image"><img src="a.png" class="block-img" loading="eager"/></div>\n<img src="p1.png"/></body></html>',
  ),
];

/// (输入, 旧实现输出)。
const List<(String, String)> _cssSamples = <(String, String)>[
  (
    'p {\n  -epub-writing-mode: vertical-rl;\n  -epub-line-break: strict;\n}',
    'p {\n\n  -webkit-line-break: strict;\n  line-break: strict;\n}',
  ),
  (
    '\t-epub-word-break : break-all ;\n-epub-hyphens:auto;',
    '\t-webkit-word-break: break-all;\n\tword-break: break-all;\n-webkit-hyphens: auto;\nhyphens: auto;',
  ),
  (
    '-epub-text-combine: horizontal;\n-epub-text-emphasis-style: filled sesame;',
    '-webkit-text-combine: horizontal;\ntext-combine-upright: all;\n-webkit-text-emphasis-style: filled sesame;\ntext-emphasis-style: filled sesame;',
  ),
  (
    '-epub-text-emphasis-color: red;-epub-hyphens:none;\n-epub-foo bar : baz qux ;',
    '-webkit-text-emphasis-color: red;\ntext-emphasis-color: red;-epub-hyphens:none;\nfoo bar: baz qux;',
  ),
  (
    'a\u{2028}-epub-hyphens:\u{3000}x\u{3000};\r\n-epub-\u{85}hyphens\u{85}:y;',
    'a\u{2028}-webkit-hyphens: x;\nhyphens: x;\r\n-webkit-hyphens: y;\nhyphens: y;',
  ),
  (
    '-EPUB-hyphens:none;\n-epub-: x;\n-epub-hyphens:no{ne;\n-epub-hyphens:none',
    '-EPUB-hyphens:none;\n-epub-: x;\n-epub-hyphens:no{ne;\n-epub-hyphens:none',
  ),
];

ReaderSanitizeNative get _native => ReaderSanitizeNative.instance;

Uint8List _chain(List<int> bytes, int steps, String images) =>
    _native.chapterHtml(
      Uint8List.fromList(bytes),
      steps: steps,
      images: utf8.encode(images),
      headStart: utf8.encode(kHeadStart),
      headEnd: utf8.encode(kHeadEnd),
    );

void _addOutput(Fnv fnv, Uint8List Function() run) {
  try {
    fnv.add(run());
    fnv.mark(0x00);
  } on RangeError {
    fnv.mark(0x01);
  }
}

int _digest(Iterable<List<int>> corpus) {
  final Fnv fnv = Fnv();
  for (final List<int> bytes in corpus) {
    for (final (int steps, String images) in kOps) {
      _addOutput(fnv, () => _chain(bytes, steps, images));
    }
    _addOutput(fnv, () => _native.css(Uint8List.fromList(bytes)));
  }
  return fnv.hash;
}

void main() {
  setUpAll(() {
    expect(
      () => ReaderSanitizeNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('representative chapter samples match the old Dart output', () {
    for (final (String input, int steps, String images, String expected)
        in _htmlSamples) {
      expect(
        utf8.decode(_chain(utf8.encode(input), steps, images)),
        expected,
        reason: 'steps=$steps input=$input',
      );
    }
  });

  test('representative CSS samples match the old Dart output', () {
    for (final (String input, String expected) in _cssSamples) {
      expect(utf8.decode(_native.css(utf8.encode(input))), expected);
    }
  });

  test('fuzz corpus digest matches the old Dart implementation', () {
    expect(_digest(fuzzCorpus(20000, utf8.encode)), _oldFuzzDigest);
  });

  test('every BMP code point at every class / fold / whitespace site', () {
    final Iterable<List<int>> corpus = <List<int>>[
      for (int cp = 0; cp <= 0xFFFF; cp++)
        if (cp < 0xD800 || cp > 0xDFFF)
          utf8.encode(codePointComposite(String.fromCharCode(cp))),
    ];
    expect(_digest(corpus), _oldCodePointDigest);
  });

  test('malformed UTF-8 and BOM follow utf8.decode(allowMalformed: true)', () {
    expect(
      _chain(<int>[0xE3, 0x81, 0x3C, 0x61, 0x2F, 0x3E, 0xFF], 1, ''),
      <int>[239, 191, 189, 60, 97, 62, 60, 47, 97, 62, 239, 191, 189],
    );
    expect(
      utf8.decode(
        _chain(
          <int>[
            0xED,
            0xA0,
            0x80,
            0xF0,
            0x9F,
            0x98,
            0xC0,
            0xAF,
            0xF4,
            0x90,
            0x80,
            0x80,
          ],
          0,
          '',
        ),
      ),
      '\u{FFFD}' * 10,
    );
    // 磁盘字节开头一个 BOM 去掉（Dart 解码器同款），第二个保留。
    expect(
      _chain(<int>[0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61], 0, ''),
      <int>[0xEF, 0xBB, 0xBF, 0x61],
    );
    // 已解码文本（String 入口）的 U+FEFF 是正文。
    expect(
      _native.chapterHtml(
        Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, 0x61]),
        steps: ReaderSanitizeNative.inputIsText,
      ),
      <int>[0xEF, 0xBB, 0xBF, 0x61],
    );
  });

  test('</head> before the <head> open tag ends throws RangeError', () {
    expect(
      () => _chain(utf8.encode('<head </head>'), 8, ''),
      throwsA(isA<RangeError>()),
    );
  });

  test('unknown step bits are rejected', () {
    expect(
      () => _native.chapterHtml(Uint8List(0), steps: 0x10),
      throwsA(isA<StateError>()),
    );
  });
}
