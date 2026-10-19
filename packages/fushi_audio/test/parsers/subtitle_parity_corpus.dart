// 字幕解析一致性回归的**确定性语料生成器**与**规范化序列化**（subtitle_native_parity_test 用）。
//
// 字幕解析从 Dart 搬到 Rust（native/fushi_compute/src/parse/subtitle/）时，用旧 Dart 实现对
// 这里生成的语料逐条求规范化输出、取 64 位 FNV-1a 摘要，钉进回归测试；新实现必须得到同一个
// 摘要（逐条、逐字段、逐位：double 按位模式、异常按类型与消息、对象形态按运行时类型与
// 共享关系）。
//
// 生成器只用自带的 xorshift64*，不依赖 dart:math Random（跨 SDK 版本不保证序列不变）。
// **改动本文件任何生成逻辑都会改变摘要**：那等于换了一套回归向量，必须先用旧实现
// （git 历史里删 Dart 实现之前的版本）重新求摘要，不能拿新实现的输出回填。
import 'dart:typed_data';

/// xorshift64*（确定性、平台无关）。
class ParityRng {
  ParityRng(int seed) : _s = seed == 0 ? 0x9E3779B97F4A7C15 : seed;

  int _s;

  int next() {
    int x = _s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    _s = x;
    return (x * 0x2545F4914F6CDD1D) >>> 11;
  }

  int below(int n) => next() % n;
  bool chance(int percent) => below(100) < percent;
  T pick<T>(List<T> xs) => xs[below(xs.length)];
}

// ── 字符池 ──────────────────────────────────────────────────────────────────

const List<String> _plainChars = <String>[
  'a', 'B', 'z', 'Q', '0', '9', ' ', ' ', '漢', '字', 'か', 'ア', 'ー', '。', '、', //
  '「', '」', '!', ',', '.', '-', '>', '<', '/', ':', '&', 'H', 'h', 'N', 'n', //
  '(', ')', '_', '=', '"', "'", 'e', 'E', 'x', 'r', 't', 'p', 'c', 'k', 'f',
];

/// 空白 / 代理 / 字素边界 / 大小写映射 / 控制字符上的刁钻码元。
const List<String> trickyChars = <String>[
  '\t', '\u000B', '\u000C', '\u0085', ' ', '﻿', ' ', ' ', //
  '　', '​', ' ', ' ', '́', '̈', '‍', //
  '‌', '️', '\u{1F468}', '\u{1F469}', '\u{1F467}', '\u{1F1EF}', //
  '\u{1F1F5}', '\u{1F1FA}', '\uD800', '\uDC00', '\uDBFF', '한', 'ᄀ', //
  'ᅡ', 'ᆨ', '가', 'क', '्', 'ष', 'ि', 'ำ', //
  'İ', 'K', 'ſ', 'ı', 'Σ', 'Ｒ', 'ʀ', '\u0000', '\u0007', '\u{20BB7}', //
  '\u{1F3FB}', '؀', 'เ', '\r', '\n', '\u{E0061}', '\u{10400}', //
];

String _chars(ParityRng r, int maxLen, {int trickyPercent = 15}) {
  final StringBuffer b = StringBuffer();
  final int n = r.below(maxLen + 1);
  for (int i = 0; i < n; i++) {
    b.write(
      r.chance(trickyPercent) ? r.pick(trickyChars) : r.pick(_plainChars),
    );
  }
  return b.toString();
}

/// 数字串：常规值、负数、小数、前导零、越界、超长、科学计数、NaN / Infinity、空白包裹等。
String number(ParityRng r, {bool allowNegative = true}) {
  if (r.chance(2)) {
    // 越界 / 溢出类（整数解析抛 FormatException、double 溢出成 Infinity）：一份文档里
    // 数字很多，出现太频繁会让大半文档整份抛错，压低到 2%。
    switch (r.below(3)) {
      case 0:
        return '9' * (17 + r.below(6)); // 跨 int64 上界
      case 1:
        return '1${'0' * (18 + r.below(3))}';
      default:
        return '1' * (300 + r.below(30));
    }
  }
  switch (r.below(22)) {
    case 0:
      return '${r.below(10)}';
    case 1:
      return '${r.below(2000)}';
    case 2:
      return '${r.below(100)}.${r.below(1000)}';
    case 3:
      return allowNegative ? '-${r.below(500)}' : '${r.below(500)}';
    case 4:
      return allowNegative ? '-${r.below(50)}.${r.below(99)}' : '0.5';
    case 5:
      return '${r.below(60)}';
    case 6:
      return '${r.below(10)}.${r.below(10)}';
    case 7:
      return '${r.below(3)}';
    case 8:
      return '000${r.below(100)}';
    case 9:
      return '${r.below(100)}.';
    case 10:
      return '.${r.below(100)}';
    case 11:
      return '1e${r.below(400)}';
    case 12:
      return r.pick(<String>[
        'NaN',
        '-NaN',
        '+NaN',
        'Infinity',
        '-Infinity',
        'inf',
      ]);
    case 13:
      return ' ${r.below(100)} ';
    case 14:
      return '\u0085${r.below(100)}';
    case 15:
      return '0x${r.below(4096).toRadixString(16)}';
    case 16:
      return '+${r.below(100)}';
    case 17:
      return '';
    case 18:
      return '${r.below(10)}${r.pick(<String>['a', '_', ',', ' 5', '　'])}';
    case 19:
      return '9223372036854775807';
    case 20:
      return '-9223372036854775808';
    default:
      return '${r.below(1 << 30)}.${'7' * r.below(25)}';
  }
}

String _hex(ParityRng r) {
  const String digits = '0123456789abcdefABCDEF';
  final int n = r.pick(<int>[0, 1, 2, 2, 6, 6, 8, 8, 9, 12]);
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < n; i++) {
    b.write(digits[r.below(digits.length)]);
  }
  if (r.chance(10)) b.write(r.pick(<String>['g', 'H', '&', ' ', 'x']));
  return b.toString();
}

String _ws(ParityRng r) =>
    r.chance(70) ? '' : r.pick(<String>[' ', '  ', '\t', '　', '\u0085', ' ']);

String _drawing(ParityRng r) {
  final StringBuffer b = StringBuffer();
  final int n = 1 + r.below(10);
  for (int i = 0; i < n; i++) {
    if (r.chance(40)) {
      b.write(
        r.pick(<String>[
          'm',
          'n',
          'l',
          'b',
          's',
          'p',
          'c',
          'M',
          'L',
          'B',
          'x',
          'İ',
          'ml',
        ]),
      );
    } else {
      b.write(number(r));
    }
    b.write(r.pick(<String>[' ', ' ', '  ', '\t', '　', '\u0085', '\n', ' ']));
  }
  return b.toString();
}

String _clipInner(ParityRng r) {
  switch (r.below(4)) {
    case 0:
      return '${number(r)},${number(r)},${number(r)},${number(r)}';
    case 1:
      return '${r.pick(<String>['1', '2', '3', '0', '-1', '64', '65', '0x2', ' 2 '])},${_drawing(r)}';
    case 2:
      return _drawing(r);
    default:
      return _chars(r, 8);
  }
}

String _trInner(ParityRng r) {
  final StringBuffer b = StringBuffer();
  switch (r.below(4)) {
    case 0:
      b.write('${_ws(r)}${number(r)}${_ws(r)},${_ws(r)}${number(r)}${_ws(r)},');
    case 1:
      b.write('${number(r)},${number(r)},${number(r)},');
    case 2:
      b.write('${number(r)},');
    default:
      break;
  }
  final int n = r.below(4);
  for (int i = 0; i < n; i++) {
    b.write(
      r.pick(<String Function()>[
        () => '\\fscx${number(r, allowNegative: false)}',
        () => '\\fscy${number(r, allowNegative: false)}',
        () => '\\1c&H${_hex(r)}&',
        () => '\\c&H${_hex(r)}',
        () => '\\alpha&H${_hex(r)}&',
        () => '\\1a${_hex(r)}',
        () => '\\blur${number(r)}',
        () => '\\be${number(r)}',
        () => '\\bord${number(r)}',
        () => '\\frz${number(r)}',
        () => '\\fr${number(r)}',
        () => '\\clip(${_clipInner(r)}',
        () => _chars(r, 4),
      ])(),
    );
  }
  return b.toString();
}

String _tag(ParityRng r) {
  final String t = r.pick(<String Function()>[
    () => 'an${r.below(11)}',
    () => 'a${r.below(11)}',
    () => 'pos(${_ws(r)}${number(r)}${_ws(r)},${_ws(r)}${number(r)}${_ws(r)})',
    () =>
        '${r.pick(<String>['i', 'b', 'u', 's'])}${number(r, allowNegative: false)}',
    () => 'fs${number(r)}',
    () =>
        '${r.pick(<String>['', '1', '3', '4', '2'])}c&H${_hex(r)}${r.chance(50) ? '&' : ''}',
    () => 'fn${_chars(r, 6)}',
    () => 'bord${number(r)}',
    () => 'shad${number(r)}',
    () =>
        'p${r.pick(<String>['0', '1', '2', '4', '63', '64', '65', '1', number(r)])}',
    () => 'pbo${number(r)}',
    () => '${r.pick(<String>['blur', 'be'])}${number(r)}',
    () => 'fad(${_ws(r)}${number(r)}${_ws(r)},${_ws(r)}${number(r)})',
    () =>
        'fade(${List<String>.generate(r.pick(<int>[7, 7, 6, 8]), (_) => number(r, allowNegative: r.chance(10))).join(',')})',
    () => r.pick(<String>['r', 'rDefault', 'rStyle Name-2', 'r*', 'R']),
    () =>
        '${r.pick(<String>['frz', 'fr', 'frx', 'fry', 'fax', 'fay', 'fsp'])}${number(r)}',
    () => '${r.pick(<String>['fscx', 'fscy'])}${number(r)}',
    () =>
        'move(${List<String>.generate(r.pick(<int>[4, 4, 6, 5, 3]), (int k) => k < 4 ? number(r) : number(r, allowNegative: false)).join(r.chance(80) ? ',' : ' , ')})',
    () =>
        '${r.pick(<String>['1a', 'alpha', '2a'])}${r.pick(<String>['', '&', '&H', 'H'])}${_hex(r)}${r.chance(50) ? '&' : ''}',
    () => '${r.pick(<String>['clip', 'iclip', 'Clip'])}(${_clipInner(r)})',
    () =>
        '${r.pick(<String>['k', 'K', 'kf', 'ko', 'kt'])}${number(r, allowNegative: false)}',
    () => 't(${_trInner(r)})',
    () => _chars(r, 5, trickyPercent: 30),
  ])();
  return '${_ws(r)}$t${_ws(r)}';
}

/// 单条 cue 原文（ASS 风格 markup）。
String markupText(ParityRng r) {
  final StringBuffer b = StringBuffer();
  final int parts = r.below(9);
  bool drawingOn = false;
  for (int i = 0; i < parts; i++) {
    switch (r.below(10)) {
      case 0:
      case 1:
      case 2:
        b.write(drawingOn ? _drawing(r) : _chars(r, 8));
      case 3:
      case 4:
      case 5:
        b.write('{');
        final int n = r.below(5);
        for (int k = 0; k < n; k++) {
          final String tag = _tag(r);
          if (tag.contains(RegExp(r'^\s*p[1-9]'))) drawingOn = true;
          b.write('\\$tag');
        }
        if (r.chance(15)) b.write(_chars(r, 3));
        b.write('}');
      case 6:
        b.write(r.pick(<String>[r'\N', r'\n', r'\h', r'\N\N', '\\', r'\\N']));
      case 7:
        b.write(r.pick(<String>['{', '}', '{\\i1', '{}', '{\\}']));
      case 8:
        b.write(_html(r));
      default:
        b.write(r.pick(trickyChars));
    }
  }
  return b.toString();
}

String _html(ParityRng r) {
  return r.pick(<String Function()>[
    () => '<ruby>${_chars(r, 3)}<rt>${_chars(r, 3)}</rt></ruby>',
    () => '<ruby>${_chars(r, 3)}<rt>${_chars(r, 3)}</ruby>',
    () =>
        '<${r.pick(<String>['rt', 'RT', 'Rt', 'rp', 'rtc', 'rtx', 'rb', 'r t', 'ʀt', 'rＴ', 'rt'])}${r.pick(<String>['', ' class="a"', '/', ' /', ' a/b', '<', '\n'])}>',
    () =>
        '</${r.pick(<String>['rt', 'RT', 'rp', 'rtc', 'ruby', 'rubyx', 'rt\t', 'rt 　'])}>',
    () => '<${_chars(r, 4)}>',
    () => r.pick(<String>[
      '<',
      '>',
      '<>',
      '</',
      '<rt',
      '<rt/>',
      '<rt >',
      '<i>',
      '</i>',
      '<b>',
      '<font color="red">',
      '<c.yellow>',
      '<00:01.000>',
      '<<i>>',
      '<rp>(</rp>',
      '<rtc><rt>x</rt></rtc>',
    ]),
    () => _chars(r, 4),
  ])();
}

/// `stripHtmlTags` 的输入。
String htmlText(ParityRng r) {
  final StringBuffer b = StringBuffer();
  final int n = r.below(8);
  for (int i = 0; i < n; i++) {
    b.write(r.chance(60) ? _html(r) : _chars(r, 5, trickyPercent: 25));
  }
  return b.toString();
}

String _nl(ParityRng r) =>
    r.pick(<String>['\n', '\n', '\n', '\r\n', '\r', '\r\r\n']);

String _srtTime(ParityRng r) {
  String two() =>
      r.chance(90) ? r.below(70).toString().padLeft(2, '0') : '${r.below(10)}';
  final String h = r.pick(<String Function()>[
    () => r.below(3).toString().padLeft(2, '0'),
    () => '${r.below(200)}',
    () => r.chance(10) ? '9' * (18 + r.below(4)) : '00',
    () => '',
  ])();
  final String sep = r.pick(<String>[',', '.', ',', ':', '']);
  final String ms = '9876543'.substring(0, r.pick(<int>[0, 1, 2, 3, 3, 3, 4]));
  final String base = r.chance(15)
      ? '${two()}:${two()}$sep$ms'
      : '$h:${two()}:${two()}$sep$ms';
  return r.chance(5) ? _chars(r, 6) : base;
}

String _timeLine(ParityRng r, {required bool vtt}) {
  final String arrow = r.pick(<String>[
    ' --> ',
    '-->',
    ' --> ',
    ' -> ',
    ' --> --> ',
    ' ---> ',
  ]);
  final StringBuffer b = StringBuffer()
    ..write(r.chance(5) ? '' : _srtTime(r))
    ..write(arrow)
    ..write(r.chance(4) ? '' : _srtTime(r));
  if (vtt && r.chance(40)) {
    b.write(
      r.pick(<String>[
        ' align:left',
        ' position:10%',
        '\u0085line:0',
        '　size:50%',
        '\tvertical:rl',
      ]),
    );
  }
  return '${_ws(r)}$b${_ws(r)}';
}

/// SRT 全文。
String srtDocument(ParityRng r) {
  final StringBuffer b = StringBuffer();
  if (r.chance(20)) b.write('﻿');
  final int n = r.below(8);
  for (int i = 0; i < n; i++) {
    if (r.chance(85)) b.write('${i + 1}${_nl(r)}');
    b.write(_timeLine(r, vtt: false));
    final int lines = r.below(4);
    for (int k = 0; k < lines; k++) {
      b.write(_nl(r));
      b.write(r.chance(50) ? markupText(r) : htmlText(r));
    }
    b.write(
      r.pick(<String>['\n\n', '\n\n\n', '\r\n\r\n', '\n \n', '\n', '\r\r']),
    );
  }
  return b.toString();
}

/// WebVTT 全文。
String vttDocument(ParityRng r) {
  final StringBuffer b = StringBuffer();
  if (r.chance(20)) b.write('﻿');
  if (r.chance(80)) b.write('WEBVTT${r.chance(30) ? ' - title' : ''}\n\n');
  final int n = r.below(8);
  for (int i = 0; i < n; i++) {
    switch (r.below(8)) {
      case 0:
        b.write('NOTE ${_chars(r, 5)}\n${_chars(r, 5)}\n\n');
      case 1:
        b.write(
          '${r.pick(<String>['STYLE', 'REGION', 'WEBVTT', 'note'])}\n::cue { color: red }\n\n',
        );
      default:
        if (r.chance(50)) b.write('cue-$i${_nl(r)}');
        b.write(_timeLine(r, vtt: true));
        final int lines = r.below(4);
        for (int k = 0; k < lines; k++) {
          b.write(_nl(r));
          b.write(r.chance(50) ? markupText(r) : htmlText(r));
        }
        b.write(r.pick(<String>['\n\n', '\n\n\n', '\r\n\r\n', '\n \n', '\n']));
    }
  }
  return b.toString();
}

const List<String> _styleCols = <String>[
  'Name', 'Fontname', 'Fontsize', 'PrimaryColour', 'SecondaryColour', //
  'OutlineColour', 'BackColour', 'Bold', 'Italic', 'Underline', 'StrikeOut', //
  'ScaleX', 'ScaleY', 'Spacing', 'Angle', 'BorderStyle', 'Outline', 'Shadow', //
  'Alignment', 'MarginL', 'MarginR', 'MarginV', 'Encoding',
];

const List<String> _eventCols = <String>[
  'Layer', 'Start', 'End', 'Style', 'Name', 'MarginL', 'MarginR', 'MarginV', //
  'Effect', 'Text',
];

String _caseMutate(ParityRng r, String s) {
  switch (r.below(8)) {
    case 0:
      return s.toUpperCase();
    case 1:
      return s.toLowerCase();
    case 2:
      return s.replaceAll('i', 'İ');
    default:
      return s;
  }
}

String _styleValue(ParityRng r, String col, List<String> names) {
  final String low = col.toLowerCase();
  if (low == 'name') return r.pick(names);
  if (low.endsWith('colour')) {
    return r.pick(<String Function()>[
      () => '&H${_hex(r)}${r.chance(50) ? '&' : ''}',
      () => '&H00FFFFFF',
      () => 'x&H12&H34',
      () => '&H${_hex(r)}&x',
      () => '${r.below(1 << 24)}',
      () => '',
    ])();
  }
  if (const <String>{
    'bold',
    'italic',
    'underline',
    'strikeout',
    'alignment',
    'encoding',
    'borderstyle',
  }.contains(low)) {
    return r.pick(<String>[
      '-1',
      '0',
      '1',
      '2',
      '7',
      '10',
      '0x1',
      ' 1',
      '+1',
      'x',
      '',
      '99999999999999999999',
    ]);
  }
  return number(r);
}

String _assTime(ParityRng r) {
  return r.pick(<String Function()>[
    () =>
        '${r.below(3)}:${r.below(60).toString().padLeft(2, '0')}:${r.below(60).toString().padLeft(2, '0')}.${r.below(100).toString().padLeft(2, '0')}',
    () => '0:00:0${r.below(10)}.${r.below(1000)}',
    () => '0:00:01.00',
    () => '0:00:01.00',
    () => '0:${r.below(70)}:${r.below(70)}.5',
    () => r.chance(10)
        ? '${'9' * (18 + r.below(4))}:00:00.00'
        : '0:00:0${r.below(10)}.5',
    () => '',
    () => _chars(r, 5),
  ])();
}

/// ASS / SSA 全文。
String assDocument(ParityRng r) {
  final StringBuffer b = StringBuffer();
  if (r.chance(15)) b.write('﻿');
  final List<String> names = <String>[
    'Default',
    'default',
    'Sign',
    'Ｄefault',
    'İtalic',
    'italic',
    ' Op ',
    '',
  ];
  final List<String> order = <String>['info', 'styles', 'events'];
  if (r.chance(15)) order.shuffleWith(r);
  if (r.chance(15))
    order.add(r.pick(<String>['styles', 'info', 'events', 'fonts']));
  for (final String section in order) {
    switch (section) {
      case 'info':
        b.write('${_caseMutate(r, '[Script Info]')}${_nl(r)}');
        if (r.chance(80))
          b.write(
            '${_caseMutate(r, 'PlayResX')}:${_ws(r)}${r.chance(70) ? r.pick(<String>['1920', '1280', '640']) : number(r)}${_nl(r)}',
          );
        if (r.chance(80))
          b.write(
            '${_caseMutate(r, 'PlayResY')}: ${r.chance(70) ? r.pick(<String>['1080', '720', '480']) : number(r)}${_nl(r)}',
          );
        b.write('ScriptType: v4.00+${_nl(r)}${_nl(r)}');
      case 'styles':
        b.write(
          '${r.pick(<String>['[V4+ Styles]', '[v4 styles]', '[V4++ Styles]', '[V4+ STYLES]'])}${_nl(r)}',
        );
        final List<String> cols = <String>[
          for (final String c in _styleCols)
            if (r.chance(85)) c,
        ];
        if (r.chance(20)) cols.shuffleWith(r);
        if (r.chance(10)) cols.add('Name');
        final bool hasFormat = r.chance(92);
        if (hasFormat)
          b.write(
            'Format: ${cols.map((String c) => r.chance(10) ? _caseMutate(r, c) : c).join(', ')}${_nl(r)}',
          );
        final int rows = r.below(5);
        for (int i = 0; i < rows; i++) {
          b.write(
            'Style: ${cols.map((String c) => _styleValue(r, c, names)).join(r.chance(90) ? ',' : ', ')}${_nl(r)}',
          );
        }
        b.write(_nl(r));
      case 'fonts':
        b.write(
          '[Fonts]${_nl(r)}fontname: x.ttf${_nl(r)}PlayResX: 100${_nl(r)}',
        );
      default:
        b.write(
          '${r.pick(<String>['[Events]', '[events]', '[EVENTS]', '[Events] '])}${_nl(r)}',
        );
        final List<String> cols = <String>[
          for (final String c in _eventCols)
            if (c == 'Text' || c == 'Start' || r.chance(85)) c,
        ];
        if (r.chance(15)) cols.shuffleWith(r);
        if (r.chance(5)) cols.remove('Start');
        if (r.chance(92))
          b.write(
            'Format: ${cols.map((String c) => r.chance(10) ? _caseMutate(r, c) : c).join(', ')}${_nl(r)}',
          );
        final int rows = r.below(9);
        for (int i = 0; i < rows; i++) {
          final String kind = r.chance(85)
              ? 'Dialogue:'
              : r.pick(<String>['Comment:', 'dialogue:', 'Dialogue']);
          final List<String> values = <String>[];
          for (final String c in cols) {
            switch (c.toLowerCase()) {
              case 'layer':
                values.add(r.chance(70) ? '${r.below(4)}' : number(r));
              case 'start':
              case 'end':
                values.add(_assTime(r));
              case 'style':
                values.add(r.pick(names));
              case 'marginl':
              case 'marginr':
              case 'marginv':
                values.add(r.chance(50) ? '0' : number(r));
              case 'text':
                values.add(markupText(r));
              default:
                values.add(_chars(r, 3));
            }
          }
          if (r.chance(8) && values.isNotEmpty) values.removeLast();
          b.write('${_ws(r)}$kind${_ws(r)}${values.join(',')}${_nl(r)}');
        }
        b.write(_nl(r));
    }
  }
  return b.toString();
}

extension on List<String> {
  void shuffleWith(ParityRng r) {
    for (int i = length - 1; i > 0; i--) {
      final int j = r.below(i + 1);
      final String t = this[i];
      this[i] = this[j];
      this[j] = t;
    }
  }
}

/// 按码点遍历全部 Unicode 的字素切分探针：每 [chunk] 个码点拼成一条 markup，码点之间穿插
/// 组合记号 / ZWJ / 变体选择符 / 样式切换，span 下标即逐段字素数。
List<String> graphemeSweep({int chunk = 2048}) {
  const List<String> joiners = <String>[
    '',
    '́',
    '‍',
    '️',
    '्',
    '\u{1F3FB}',
    '{\\i1}',
    '{\\i0}',
    r'\N',
  ];
  final List<String> out = <String>[];
  final StringBuffer b = StringBuffer();
  int k = 0;
  for (int cp = 0; cp <= 0x10FFFF; cp++) {
    if (cp == 0x7B || cp == 0x7D || cp == 0x5C) continue; // { } \ 交给 markup 语料
    b.write(String.fromCharCode(cp));
    b.write(joiners[(cp * 7 + k) % joiners.length]);
    if (++k == chunk) {
      out.add(b.toString());
      b.clear();
      k = 0;
    }
  }
  if (b.isNotEmpty) out.add(b.toString());
  return out;
}

// ── 规范化序列化（对 old / new 两套同名类型都适用，故用 dynamic）─────────────

String _bits(double? v) {
  if (v == null) return '-';
  final ByteData d = ByteData(8)..setFloat64(0, v, Endian.little);
  return d.getUint64(0, Endian.little).toRadixString(16);
}

String _str(String? s) =>
    s == null ? '-' : '${s.length}:${s.codeUnits.join('.')}';

String _anchor(dynamic a) =>
    a == null ? '-' : '${a.vertical.index}${a.horizontal.index}';

String _span(dynamic s) =>
    '[${s.startGrapheme},${s.endGrapheme},${s.italic ? 1 : 0}${s.bold ? 1 : 0}'
    '${s.underline ? 1 : 0}${s.strike ? 1 : 0},${s.colorArgb},${_bits(s.fontSizePx)},'
    '${_str(s.fontName)},${s.outlineColorArgb},${s.shadowColorArgb},'
    '${_bits(s.outlineWidthPx)},${_bits(s.shadowDepthPx)},${_bits(s.blur)},'
    '${_bits(s.fillOpacity)},${_bits(s.letterSpacingPx)},${_bits(s.scaleX)},'
    '${_bits(s.scaleY)},${s.kMode},${s.kStartCs},${s.kDurCs}]';

String _segments(dynamic segs) =>
    '${segs.runtimeType}<${(segs as List<dynamic>).map((dynamic s) => '${s.op.index}:${_bits(s.x1)},${_bits(s.y1)},${_bits(s.x2)},${_bits(s.y2)},${_bits(s.x3)},${_bits(s.y3)}').join(';')}>';

String _cueStyle(dynamic c) =>
    '{${_str(c.fontName)},${c.primaryColorArgb},${c.outlineColorArgb},'
    '${c.shadowColorArgb},${_bits(c.fontSizePx)},${_bits(c.outlineWidthPx)},'
    '${_bits(c.shadowDepthPx)},${c.bold},${c.italic},${c.underline},${c.strikeOut},'
    '${_anchor(c.anchor)},${_bits(c.marginV)},${_bits(c.marginL)},${_bits(c.marginR)},'
    '${c.secondaryColorArgb},${_bits(c.spacingPx)},${_bits(c.angleDeg)},'
    '${_bits(c.scaleXPct)},${_bits(c.scaleYPct)}}';

/// 一条 markup 的规范化形式。[styleIds] 记录 cueStyle 对象身份（同一对象 → 同一编号）。
String canonMarkup(dynamic m, [Map<Object, int>? styleIds]) {
  final StringBuffer b = StringBuffer()
    ..write('M(')
    ..write(_str(m.plainText))
    ..write('|')
    ..write(
      '${m.spans.runtimeType}${(m.spans as List<dynamic>).map(_span).join()}',
    )
    ..write('|${_anchor(m.anchor)}');
  // anchor 是否就是 cueStyle 的那个对象（回退）。
  b.write(
    m.cueStyle != null &&
            identical(m.anchor, m.cueStyle.anchor) &&
            m.anchor != null
        ? '=s'
        : '',
  );
  final dynamic pos = m.posFraction;
  b.write(
    '|${pos == null ? '-' : '${_bits(pos.xFraction)},${_bits(pos.yFraction)}'}',
  );
  final dynamic cs = m.cueStyle;
  if (cs == null) {
    b.write('|-');
  } else {
    final int id = styleIds == null
        ? 0
        : styleIds.putIfAbsent(cs as Object, () => styleIds.length);
    b.write('|s$id${_cueStyle(cs)}');
  }
  b.write('|${_bits(m.playResX)},${_bits(m.playResY)}');
  b.write('|${m.lineBreakGraphemes.runtimeType}${m.lineBreakGraphemes}');
  final dynamic f = m.fade;
  if (f == null) {
    b.write('|-');
  } else {
    // 通过公开 API 采样包络（私有字段不可见）：fadeIn/Out + 多点不透明度。
    final List<String> samples = <String>[
      for (final int t in <int>[
        -1,
        0,
        1,
        50,
        100,
        250,
        500,
        999,
        1000,
        2000,
        5000,
        100000,
      ])
        _bits(f.opacityAt(t, 3000) as double),
    ];
    b.write('|F${f.fadeInMs},${f.fadeOutMs},${samples.join(',')}');
  }
  b.write('|${_bits(m.rotationDeg)}');
  final dynamic sc = m.scale;
  b.write(
    sc == null
        ? '|-'
        : '|S${_bits(sc.fromX)},${_bits(sc.fromY)},${_bits(sc.toX)},${_bits(sc.toY)},${sc.t1Ms},${sc.t2Ms}',
  );
  final dynamic mv = m.move;
  b.write(
    mv == null
        ? '|-'
        : '|V${_bits(mv.x1Fraction)},${_bits(mv.y1Fraction)},${_bits(mv.x2Fraction)},${_bits(mv.y2Fraction)},${mv.t1Ms},${mv.t2Ms}',
  );
  b.write('|L${m.layer}');
  final dynamic clip = m.clip;
  b.write(clip == null ? '|-' : '|C${clip.inverse}${_segments(clip.segments)}');
  b.write('|${m.transitions.runtimeType}');
  for (final dynamic t in m.transitions as List<dynamic>) {
    b.write(
      'T${t.t1Ms},${t.t2Ms},${_bits(t.accel)},${_bits(t.alphaTo)},${t.colorToArgb},${_bits(t.blurTo)},${_bits(t.bordTo)},${_bits(t.frzToDeg)};',
    );
  }
  b.write(
    '|${_bits(m.rotationXDeg)},${_bits(m.rotationYDeg)},${_bits(m.shearX)},${_bits(m.shearY)}',
  );
  final dynamic d = m.drawing;
  b.write(
    d == null
        ? '|-'
        : '|D${_segments(d.segments)}${_bits(d.minX)},${_bits(d.minY)},${_bits(d.maxX)},${_bits(d.maxY)},${_bits(d.baselineOffsetFraction)}',
  );
  final dynamic ds = m.drawingStyle;
  b.write(ds == null ? '|-' : '|${_span(ds)}');
  b.write(')');
  return b.toString();
}

/// cue 列表的规范化形式（含异常）。
String canonCues(List<dynamic> Function() parse) {
  final List<dynamic> cues;
  try {
    cues = parse();
  } catch (e) {
    return 'THROW ${e.runtimeType}: $e';
  }
  final Map<Object, int> styleIds = Map<Object, int>.identity();
  final StringBuffer b = StringBuffer('${cues.runtimeType}#${cues.length}\n');
  for (final dynamic c in cues) {
    b
      ..write(
        '${c.sentenceIndex}|${c.startMs}|${c.endMs}|${_str(c.text)}|${c.textFragmentId}|',
      )
      ..write(
        '${c.bookKey}|${c.chapterHref}|${c.audioFileIndex}|${c.id}|${c.tokenTiming}|',
      )
      ..write(c.markup == null ? '-' : canonMarkup(c.markup, styleIds))
      ..write('\n');
  }
  return b.toString();
}

/// 单值（markup / 字符串）的规范化形式（含异常）。
String canonValue(Object? Function() compute) {
  try {
    final Object? v = compute();
    if (v is String) return 'S${_str(v)}';
    return canonMarkup(v);
  } catch (e) {
    return 'THROW ${e.runtimeType}: $e';
  }
}

/// 64 位 FNV-1a 增量摘要（按 UTF-16 码元）。
class ParityDigest {
  int _h = 0xcbf29ce484222325;
  int count = 0;

  void add(String s) {
    count++;
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      _h = (_h ^ (c & 0xff)) * 0x100000001b3;
      _h = (_h ^ (c >> 8)) * 0x100000001b3;
    }
    _h = (_h ^ 0x1f) * 0x100000001b3;
  }

  String get hex =>
      '${((_h >> 32) & 0xffffffff).toRadixString(16).padLeft(8, '0')}'
      '${(_h & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
}

// ── 回归语料（种子 / 条数固定；改动即换向量，见文件头）──────────────────────────

const int kParitySeedBase = 0x5eed0000;

const List<double?> kPlayResChoices = <double?>[
  null,
  384,
  288,
  1920,
  1080,
  0,
  -5,
  double.nan,
  double.infinity,
  640,
];

typedef MarkupCase = ({
  String raw,
  double? playResX,
  double? playResY,
  int layer,
});

List<MarkupCase> markupCases(int n, int seed) {
  final ParityRng r = ParityRng(seed);
  return <MarkupCase>[
    for (int i = 0; i < n; i++)
      (
        raw: markupText(r),
        playResX: r.pick(kPlayResChoices),
        playResY: r.pick(kPlayResChoices),
        layer: r.chance(80) ? 0 : r.below(5) - 1,
      ),
  ];
}

List<String> htmlCases(int n, int seed) {
  final ParityRng r = ParityRng(seed);
  return <String>[for (int i = 0; i < n; i++) htmlText(r)];
}

List<String> srtCases(int n, int seed) {
  final ParityRng r = ParityRng(seed);
  return <String>[for (int i = 0; i < n; i++) srtDocument(r)];
}

List<String> vttCases(int n, int seed) {
  final ParityRng r = ParityRng(seed);
  return <String>[for (int i = 0; i < n; i++) vttDocument(r)];
}

typedef AssCase = ({String doc, bool drawings});

List<AssCase> assCases(int n, int seed) {
  final ParityRng r = ParityRng(seed);
  return <AssCase>[
    for (int i = 0; i < n; i++) (doc: assDocument(r), drawings: r.chance(50)),
  ];
}
