// 弹幕解析对拍语料：确定性生成器 + 观测值摘要。
//
// danmaku_parity_test.dart 用它重建语料、跑原生实现、比对摘要；摘要常量是删 Dart 实现前
// 用旧实现（package:xml 6.6.1 / jsonDecode + 逐条转换 + List.sort，Dart 3.47.6）对同一份
// 语料算出来冻结的。生成器只依赖 dart:core 的确定性运算（自带 xorshift64*，不用
// dart:math Random），改动它等于换语料，必须用旧实现重新生成摘要——旧实现已删除，所以
// **不要改这个文件的生成逻辑**；要加用例就在 danmaku_parity_test.dart 里写带期望值的样例。
//
// 本文件也是一个测试（钉住生成器的确定性与规模），所以文件名以 _test.dart 结尾。
@TestOn('vm')
library;

import 'package:test/test.dart';

/// 一条对拍输入。
enum DanmakuCaseKind {
  /// `parseBilibiliDanmakuXml(input)`。
  xml,

  /// `parseDandanplayDanmakuJson(input, shiftMs: shiftMs)`。
  json,

  /// 在线 `/api/v2/comment` 响应体：`jsonDecode` → 形状校验 →
  /// `dandanplayCommentsToDanmaku(..., shiftMs: (shiftSeconds * 1000).round())`。
  online,
}

final class DanmakuCase {
  const DanmakuCase(
    this.kind,
    this.input, {
    this.shiftMs = 0,
    this.shiftSeconds = 0,
  });

  final DanmakuCaseKind kind;
  final String input;
  final int shiftMs;
  final double shiftSeconds;
}

/// 一条弹幕的观测值：(startMs, text, modeIndex, colorArgb)。
typedef DanmakuObservedItem = (int, String, int, int);

/// 一次解析的观测值。
///
/// [kind]：0 成功 / 1 语法错误（XML 解析或校验异常、JSON FormatException）/
/// 2 JSON 形状不对 / 3 数值非有限（UnsupportedError）。
/// [detail]：JSON 语法错误时为 `message@offset`，否则空串。
final class DanmakuObservation {
  const DanmakuObservation(this.kind, this.detail, this.items);

  final int kind;
  final String detail;
  final List<DanmakuObservedItem> items;

  String describe() {
    final StringBuffer out = StringBuffer(
      'kind=$kind detail=$detail n=${items.length}',
    );
    for (final DanmakuObservedItem item in items) {
      out.write(
        '\n  ${item.$1} m${item.$3} c${item.$4.toRadixString(16)} '
        '${item.$2.codeUnits}',
      );
    }
    return out.toString();
  }
}

/// 64 位 FNV-1a（VM int 回绕乘法）。
final class DanmakuDigest {
  int _hash = 0xcbf29ce484222325;

  void addInt(int value) {
    for (int i = 0; i < 8; i++) {
      _hash ^= (value >>> (i * 8)) & 0xFF;
      _hash *= 0x100000001b3;
    }
  }

  void addString(String value) {
    addInt(value.length);
    for (int i = 0; i < value.length; i++) {
      final int unit = value.codeUnitAt(i);
      _hash ^= unit & 0xFF;
      _hash *= 0x100000001b3;
      _hash ^= unit >>> 8;
      _hash *= 0x100000001b3;
    }
  }

  void addObservation(DanmakuObservation observation) {
    addInt(observation.kind);
    addString(observation.detail);
    addInt(observation.items.length);
    for (final DanmakuObservedItem item in observation.items) {
      addInt(item.$1);
      addString(item.$2);
      addInt(item.$3);
      addInt(item.$4);
    }
  }

  int get value => _hash;

  String get hex =>
      (_hash >>> 32).toRadixString(16).padLeft(8, '0') +
      (_hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}

/// xorshift64*。
final class _Rng {
  _Rng(int seed) : _state = seed == 0 ? 0x2545F4914F6CDD1D : seed;

  int _state;

  int next() {
    int x = _state;
    x ^= x >>> 12;
    x ^= x << 25;
    x ^= x >>> 27;
    _state = x;
    return x * 0x2545F4914F6CDD1D;
  }

  /// 0 ≤ r < n。
  int below(int n) => (next() >>> 1) % n;

  bool chance(int percent) => below(100) < percent;

  T pick<T>(List<T> values) => values[below(values.length)];
}

const List<String> _timeTokens = <String>[
  '1',
  '1.0',
  '1.000',
  '0.9995',
  '1.0005',
  '1.0004999',
  '2.5',
  '  3 ',
  '+4',
  '.5',
  '5.',
  '1e1',
  '1E-1',
  '1.e1',
  '-1',
  '-0',
  '0',
  '00012.50',
  'Infinity',
  '-Infinity',
  '+Infinity',
  'NaN',
  '-NaN',
  '1e400',
  '1e-400',
  '0x10',
  'abc',
  '',
  ' ',
  '1_0',
  '１',
  '1073741.824',
  '1073741.8235',
  '1073741.8245',
  '1e6',
  '9007199254740993',
  '123456789012345678901234567890',
  '1e+308',
  '1.7976931348623159e308',
  ' 2.25　',
  '﻿7',
  '2.5\u0085',
  'infinity',
  'nan',
  '1e',
  '.e1',
  '1.5.5',
  '0.0005',
  '0.0015',
  '0.0025',
  '-0.0005',
  '-0.0015',
  '4.9e-324',
  '1e-7',
  '922337203685477.5807',
  '9.3e15',
  '-9.3e15',
];

const List<String> _modeTokens = <String>[
  '1',
  '1',
  '1',
  '1',
  '4',
  '4',
  '5',
  '5',
  '2',
  '3',
  '6',
  '7',
  '0',
  '-1',
  ' 4 ',
  '+5',
  '0x4',
  '0X5',
  '04',
  '4.0',
  '',
  'x',
  '9223372036854775808',
  '-0',
  '0x0000000000000001',
  ' 5',
  '5﻿',
  '1e0',
  '４',
];

const List<String> _colorTokens = <String>[
  '16777215',
  '16777215',
  '255',
  '0',
  '-1',
  '0xFF0000',
  '0X00ff00',
  ' 255 ',
  '+255',
  '4294967295',
  '9223372036854775807',
  '-9223372036854775808',
  '9223372036854775808',
  'abc',
  '',
  '1e3',
  '0xFFFFFFFFFFFFFFFF',
  '0x10000000000000000',
  '-0x8000000000000000',
  '16711680',
  '65280',
  '-16777216',
];

const List<String> _textPieces = <String>[
  'こんにちは',
  'テスト',
  '草',
  'wwww',
  '8888',
  'hello world',
  ' ',
  '  ',
  '\t',
  '\r\n',
  '\n',
  '　',
  '﻿',
  '\u0085',
  ' ',
  ' ',
  '​',
  '\u{1F600}',
  '前方高能',
  'abc',
  'ABC',
  '&',
  '>',
  '"',
  "'",
  ']]',
  '//',
  '\u0001',
  '\u001F',
  '\u007F',
  'İ',
  'ſ',
  '\u0000',
];

const List<String> _xmlEntityPieces = <String>[
  '&amp;',
  '&lt;',
  '&gt;',
  '&quot;',
  '&apos;',
  '&#65;',
  '&#x3042;',
  '&#X3042;',
  '&#x1F600;',
  '&#xD800;',
  '&#0;',
  '&#x110000;',
  '&#1114111;',
  '&#1114112;',
  '&# 65;',
  '&#+65;',
  '&#-65;',
  '&#x 41;',
  '&#x+41;',
  '&bogus;',
  '&amp',
  '&;',
  '&&amp;',
  '&#;',
  '&#x;',
  '&#xg;',
  '&AMP;',
  '&#00000065;',
  '&#x0041 ;',
  '&#99999999999999999999;',
  '&nbsp;',
  '&a b;',
];

String _joinFields(_Rng rng, List<String> fields) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < fields.length; i++) {
    if (i > 0) out.write(',');
    out.write(fields[i]);
  }
  return out.toString();
}

/// p 属性（colorIndex 3 = Bilibili，2 = 弹弹play）。
String _pValue(_Rng rng, int colorIndex, {required int distinctTimes}) {
  final String time = rng.chance(70)
      ? (distinctTimes <= 0
            ? '${rng.below(200)}.${rng.below(1000).toString().padLeft(3, '0')}'
            : '${rng.below(distinctTimes)}')
      : rng.pick(_timeTokens);
  final String mode = rng.chance(75)
      ? rng.pick(<String>['1', '1', '4', '5'])
      : rng.pick(_modeTokens);
  final String color = rng.chance(70)
      ? '${rng.pick(<int>[16777215, 16777215, 16711680, 255, 65280, rng.below(1 << 24)])}'
      : rng.pick(_colorTokens);
  final List<String> fields = <String>[time, mode];
  if (colorIndex == 3) fields.add('25');
  fields.add(color);
  final int extra = rng.below(6);
  for (int i = 0; i < extra; i++) {
    fields.add(
      rng.pick(<String>[
        '0',
        '1632868828',
        'abc',
        '',
        '[BiliBili]0afc7011',
        '10',
        ' ',
      ]),
    );
  }
  if (rng.chance(4)) {
    // 截掉一段：段数不足 / 空 p。
    return _joinFields(rng, fields.sublist(0, rng.below(fields.length)));
  }
  return _joinFields(rng, fields);
}

String _xmlText(_Rng rng, {int maxPieces = 5}) {
  final StringBuffer out = StringBuffer();
  final int pieces = 1 + rng.below(maxPieces);
  for (int i = 0; i < pieces; i++) {
    final int roll = rng.below(100);
    if (roll < 55) {
      out.write(rng.pick(_textPieces).replaceAll('&', '&amp;'));
    } else if (roll < 75) {
      out.write(rng.pick(_xmlEntityPieces));
    } else if (roll < 80) {
      out.write(
        '<![CDATA[${rng.pick(<String>['x', '&amp;', '<b>', ']]', ' ', ''])}]]>',
      );
    } else if (roll < 84) {
      out.write('<!--${rng.pick(<String>['c', '-', '<d>', ''])}-->');
    } else if (roll < 87) {
      out.write(
        rng.pick(<String>[
          '<?pi x?>',
          '<?pi?>',
          '<?xml-stylesheet a?>',
          '<?XML x?>',
        ]),
      );
    } else if (roll < 91) {
      out.write('<b>${rng.pick(_textPieces).replaceAll('&', '&amp;')}</b>');
    } else if (roll < 93) {
      out.write(rng.pick(<String>['<br/>', '<br />', '<x:b/>', '<d/>']));
    } else if (roll < 95) {
      out.write(
        '<d p="${_pValue(rng, 3, distinctTimes: 5)}">inner${rng.below(9)}</d>',
      );
    } else if (roll < 96) {
      out.write(String.fromCharCode(0xD800 + rng.below(0x800)));
    } else if (roll < 97) {
      out.write(
        rng.pick(<String>['<', '&', '<<', '< d', '<!x>', '<?>', '<!--']),
      );
    } else {
      out.write(
        String.fromCharCode(
          1 + rng.below(0x7F),
        ).replaceAll('&', '&amp;').replaceAll('<', '&lt;'),
      );
    }
  }
  return out.toString();
}

String _xmlAttrQuote(_Rng rng, String name, String value) {
  final int roll = rng.below(100);
  final String spaceA = rng.chance(10)
      ? rng.pick(<String>[' ', '\t', '\r\n', '　', '﻿'])
      : '';
  final String spaceB = rng.chance(10) ? rng.pick(<String>[' ', '\n']) : '';
  if (roll < 80) {
    return '$name$spaceA=$spaceB"${value.replaceAll('&', rng.chance(90) ? '&amp;' : '&').replaceAll('"', '&quot;').replaceAll('<', '&lt;')}"';
  } else if (roll < 95) {
    return "$name$spaceA=$spaceB'${value.replaceAll('&', '&amp;').replaceAll("'", '&apos;').replaceAll('<', '&lt;')}'";
  } else {
    // 不带引号：只有名字字符才成立；逗号、空格会让解析失败或截断。
    return '$name=$value';
  }
}

String _xmlD(_Rng rng, {required int distinctTimes}) {
  final StringBuffer attrs = StringBuffer();
  final int roll = rng.below(100);
  final String p = _pValue(rng, 3, distinctTimes: distinctTimes);
  if (roll < 85) {
    attrs.write(' ${_xmlAttrQuote(rng, 'p', p)}');
  } else if (roll < 88) {
    attrs.write(
      ' ${_xmlAttrQuote(rng, 'p', p)} ${_xmlAttrQuote(rng, 'p', '9,1,25,255')}',
    );
  } else if (roll < 90) {
    attrs.write(' ${_xmlAttrQuote(rng, 'P', p)}');
  } else if (roll < 92) {
    attrs.write(' ${_xmlAttrQuote(rng, 'x:p', p)}');
  } else if (roll < 94) {
    attrs.write(' p');
  } else if (roll < 96) {
    attrs.write(' p="${p.replaceAll(',', '&#44;')}"');
  }
  // 否则：没有 p。
  if (rng.chance(20)) attrs.write(' id="${rng.below(1000)}"');
  final String name = rng.chance(97)
      ? 'd'
      : rng.pick(<String>['D', 'x:d', 'dd']);
  final String trailing = rng.chance(5) ? ' ' : '';
  if (rng.chance(3)) return '<$name$attrs$trailing/>';
  return '<$name$attrs$trailing>${_xmlText(rng)}</$name${rng.chance(5) ? ' ' : ''}>';
}

String _xmlDocument(
  _Rng rng, {
  required int items,
  required int distinctTimes,
}) {
  final StringBuffer out = StringBuffer();
  if (rng.chance(10)) out.write('﻿');
  if (rng.chance(5))
    out.write(rng.pick(<String>['<!--lead-->', 'lead text', ' ', '\n']));
  if (rng.chance(60)) {
    out.write(
      rng.pick(<String>[
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<?xml version='1.0'?>",
        '<?xml?>',
        '<?xml version="1.0" standalone=yes?>',
        '<?xml version="1.0"?><?xml version="1.0"?>',
      ]),
    );
  }
  if (rng.chance(10)) {
    out.write(
      rng.pick(<String>[
        '<!DOCTYPE i>',
        '<!DOCTYPE i SYSTEM "x.dtd">',
        '<!DOCTYPE i PUBLIC "-//x" \'y\'>',
        '<!DOCTYPE i [ <!ENTITY a "]>"> <!ELEMENT d ANY> %pe; <!-- ] --> ]>',
        '<!DOCTYPE i [ <d p="1,1,25,255">hidden</d> ]>',
        '<!DOCTYPE i [ unterminated',
        '<!DOCTYPEi>',
      ]),
    );
  }
  if (rng.chance(5)) out.write('<?pi before?>\r\n');
  final String root = rng.chance(90)
      ? 'i'
      : rng.pick(<String>['d', 'x:i', 'danmaku']);
  final String rootAttrs = rng.chance(10) ? ' xmlns:x="urn:x"' : '';
  out.write('<$root$rootAttrs>');
  if (rng.chance(30)) {
    out.write(
      '<chatserver>chat.bilibili.com</chatserver><chatid>${rng.below(1 << 30)}</chatid>',
    );
  }
  for (int i = 0; i < items; i++) {
    out.write(rng.pick(<String>['\n', '\r\n', '', ' ', '\n  ']));
    out.write(_xmlD(rng, distinctTimes: distinctTimes));
    if (rng.chance(2)) out.write(_xmlText(rng, maxPieces: 2));
  }
  out.write('\n</$root>');
  if (rng.chance(5)) {
    out.write(
      rng.pick(<String>[
        '\n',
        'trailing',
        '<!--t-->',
        '<j/>',
        '<?xml version="1.0"?>',
        '<!DOCTYPE j>',
        '</i>',
      ]),
    );
  }
  String doc = out.toString();
  final int mutate = rng.below(100);
  if (mutate < 4 && doc.isNotEmpty) {
    doc = doc.substring(0, rng.below(doc.length));
  } else if (mutate < 7 && doc.isNotEmpty) {
    final int at = rng.below(doc.length);
    doc =
        doc.substring(0, at) +
        rng.pick(<String>['<', '&', '>', '"', "'", '/', ']]>', '\u0000']) +
        doc.substring(at);
  }
  return doc;
}

const List<String> _xmlSoupTokens = <String>[
  '<',
  '>',
  '/',
  '?',
  '!',
  '-',
  '--',
  '[',
  ']',
  'CDATA',
  'DOCTYPE',
  'xml',
  'd',
  'i',
  'p',
  '=',
  '"',
  "'",
  ' ',
  '\n',
  '&',
  ';',
  '#',
  'x',
  'a',
  '1',
  ',',
  'ELEMENT',
  '%',
  '﻿',
  '　',
  ':',
  '.',
  '·',
  '̀',
  '\u{10000}',
  '\uD800',
];

String _xmlSoup(_Rng rng) {
  final StringBuffer out = StringBuffer('<i><d p="1,1,25,255">');
  final int n = 1 + rng.below(12);
  for (int i = 0; i < n; i++) {
    out.write(rng.pick(_xmlSoupTokens));
  }
  out.write('</d></i>');
  return out.toString();
}

// ---------------------------------------------------------------- JSON

String _jsonString(String value, _Rng rng) {
  final StringBuffer out = StringBuffer('"');
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (unit == 0x22) {
      out.write(r'\"');
    } else if (unit == 0x5C) {
      out.write(r'\\');
    } else if (unit < 0x20) {
      out.write(switch (unit) {
        0x0A => r'\n',
        0x09 => r'\t',
        0x0D => r'\r',
        0x08 => r'\b',
        0x0C => r'\f',
        _ => r'\u00' + unit.toRadixString(16).padLeft(2, '0'),
      });
    } else if (rng.chance(3)) {
      out.write(r'\u' + unit.toRadixString(16).padLeft(4, '0'));
    } else if (unit == 0x2F && rng.chance(50)) {
      out.write(r'\/');
    } else {
      out.writeCharCode(unit);
    }
  }
  out.write('"');
  return out.toString();
}

const List<String> _jsonNumberTokens = <String>[
  '0',
  '-0',
  '1',
  '-1',
  '1.0',
  '-0.0',
  '0.5',
  '1e2',
  '1E+2',
  '1e-2',
  '1.5e-3',
  '0.0001',
  '123456789012345678901',
  '-9223372036854775808',
  '9223372036854775807',
  '9223372036854775808',
  '-9223372036854775809',
  '1e400',
  '-1e400',
  '1e-400',
  '0.00000000000000000000000000000000000000001e401',
  '1000000000000000000000e-401',
  '0e999',
  '-0e999',
  '4.9e-324',
  '1.7976931348623159e308',
  '3.25',
  '4.5',
  '255',
  '16777215',
  '4294967295',
  '1e21',
  '1e-7',
  '100.0',
  '2.5',
  '0.1',
  '1e0',
  '5e-1',
  '12345678901234567890.5',
  '1.00000000000000011102230246251565404236316680908203125',
  '0.30000000000000004',
  '9007199254740993',
  '1e22',
  '1e23',
  '1.5e300',
];

String _jsonNumber(_Rng rng) {
  final int roll = rng.below(100);
  if (roll < 50) return rng.pick(_jsonNumberTokens);
  if (roll < 70) return '${rng.below(2000) - 100}';
  if (roll < 85) {
    final double d = (rng.below(1 << 20) - (1 << 19)) / (1 + rng.below(997));
    return d.toString();
  }
  // 随机位型的有限 double（toString 的最短表示是合法 JSON 数字，回读得到同一个值）。
  while (true) {
    final int bits = rng.next();
    final double d = _doubleFromBits(bits);
    if (d.isFinite) return d.toString();
  }
}

double _doubleFromBits(int bits) {
  // 不引入 dart:typed_data：用指数/尾数手工拼。
  final int exponentBits = (bits >>> 52) & 0x7FF;
  final int mantissa = bits & 0xFFFFFFFFFFFFF;
  final bool negative = bits < 0;
  if (exponentBits == 0x7FF) return double.nan;
  double value;
  if (exponentBits == 0) {
    value = mantissa * _pow2(-1074);
  } else {
    value = (mantissa + 0x10000000000000) * _pow2(exponentBits - 1075);
  }
  return negative ? -value : value;
}

double _pow2(int e) {
  double result = 1.0;
  if (e >= 0) {
    for (int i = 0; i < e; i++) {
      result *= 2;
    }
  } else {
    for (int i = 0; i < -e; i++) {
      result /= 2;
    }
  }
  return result;
}

String _jsonScalarOrNested(_Rng rng, int depth) {
  final int roll = rng.below(100);
  if (roll < 30) return _jsonString(_textValue(rng), rng);
  if (roll < 55) return _jsonNumber(rng);
  if (roll < 62) return rng.pick(<String>['true', 'false', 'null']);
  if (depth >= 3) return _jsonNumber(rng);
  if (roll < 82) {
    final int n = rng.below(4);
    return '[${List<String>.generate(n, (_) => _jsonScalarOrNested(rng, depth + 1)).join(rng.chance(80) ? ',' : ', ')}]';
  }
  final int n = rng.below(4);
  return '{${List<String>.generate(n, (_) => '${_jsonString(rng.pick(<String>['a', 'b', 'm', '', 'a']), rng)}:${_jsonScalarOrNested(rng, depth + 1)}').join(',')}}';
}

String _textValue(_Rng rng) {
  final StringBuffer out = StringBuffer();
  final int pieces = rng.below(4);
  for (int i = 0; i < pieces; i++) {
    out.write(rng.pick(_textPieces));
  }
  if (rng.chance(3)) out.writeCharCode(0xDC00 + rng.below(0x400));
  return out.toString();
}

String _jsonTimeValue(_Rng rng, int distinctTimes) {
  final int roll = rng.below(100);
  if (roll < 40) {
    return distinctTimes > 0
        ? '${rng.below(distinctTimes)}'
        : '${rng.below(300)}.${rng.below(100)}';
  }
  if (roll < 60) return _jsonNumber(rng);
  if (roll < 85) return _jsonString(rng.pick(_timeTokens), rng);
  return rng.pick(<String>['null', 'true', '[]', '{}', '[1]']);
}

String _jsonModeValue(_Rng rng) {
  final int roll = rng.below(100);
  if (roll < 40)
    return rng.pick(<String>['1', '4', '5', '1', '2', '3', '6', '0']);
  if (roll < 55)
    return rng.pick(<String>[
      '4.0',
      '4.9',
      '5.5',
      '-0.0',
      '1e400',
      '-1e400',
      '1e1',
      '9223372036854775808',
      '1e19',
    ]);
  if (roll < 90) {
    return _jsonString(
      rng.pick(<String>[
        'scroll',
        'Scroll',
        'SCROLL',
        'rolling',
        'right',
        'RİGHT',
        'top',
        'Top',
        'TOP',
        'bottom',
        'Bottom',
        'right ',
        ' top',
        'top\u0000',
        'kelvin',
        '',
        'ſcroll',
        'tOp',
        'BOTTOM',
        'roLLing',
        '4',
        'İ',
      ]),
      rng,
    );
  }
  return rng.pick(<String>['null', 'true', 'false', '[]', '{}']);
}

String _jsonColorValue(_Rng rng) {
  final int roll = rng.below(100);
  if (roll < 50)
    return '${rng.pick(<int>[16777215, 255, 16711680, 0, rng.below(1 << 24)])}';
  if (roll < 70)
    return rng.pick(<String>[
      '-1',
      '4294967295',
      '9223372036854775807',
      '-9223372036854775808',
      '1e30',
      '255.9',
      '-1.5',
      '1e400',
      '-0.0',
      '1e19',
    ]);
  if (roll < 85) return _jsonString(rng.pick(_colorTokens), rng);
  return rng.pick(<String>['null', 'true', '[]']);
}

String _jsonRow(_Rng rng, {required int distinctTimes}) {
  final int shape = rng.below(100);
  if (shape < 3)
    return rng.pick(<String>[
      '1',
      '"x"',
      'null',
      '[]',
      'true',
      '[{"m":"x","p":"1,1,255"}]',
    ]);
  final List<String> entries = <String>[];
  void add(String key, String value) =>
      entries.add('${_jsonString(key, rng)}:$value');
  final bool useP = rng.chance(60);
  if (rng.chance(4)) add('cid', '${rng.below(1 << 30)}');
  if (useP) {
    final int pr = rng.below(100);
    if (pr < 90) {
      add('p', _jsonString(_pValue(rng, 2, distinctTimes: distinctTimes), rng));
    } else {
      add('p', rng.pick(<String>['1', 'null', '[]', '{"a":1}', 'true']));
    }
  }
  // 时间 / 模式 / 颜色：p 不是字符串时才用得上，但两种都混着出。
  if (!useP || rng.chance(20)) {
    if (rng.chance(85))
      add(
        rng.pick(<String>['time', 'time', 't', 'start']),
        _jsonTimeValue(rng, distinctTimes),
      );
    if (rng.chance(15))
      add(rng.pick(<String>['t', 'start']), _jsonTimeValue(rng, distinctTimes));
    if (rng.chance(70))
      add(rng.pick(<String>['mode', 'mode', 'type']), _jsonModeValue(rng));
    if (rng.chance(15)) add('type', _jsonModeValue(rng));
    if (rng.chance(60)) add('color', _jsonColorValue(rng));
  }
  final int textRoll = rng.below(100);
  if (textRoll < 75) {
    add(
      rng.chance(85) ? 'm' : 'text',
      _jsonString(
        _textValue(rng).isEmpty && rng.chance(50) ? 'w' : _textValue(rng),
        rng,
      ),
    );
  } else if (textRoll < 85) {
    add('m', _jsonScalarOrNested(rng, 0));
  } else if (textRoll < 90) {
    add('m', 'null');
    add('text', _jsonString(_textValue(rng), rng));
  } else if (textRoll < 93) {
    add('m', '""');
    add('text', '"fallback"');
  } else if (textRoll < 96) {
    add('m', _jsonString('first', rng));
    add('m', _jsonString('second', rng));
  }
  // 否则无文本。
  if (rng.chance(5))
    add(
      rng.pick(<String>['M', 'Text', 'P', 'Time', 'x']),
      _jsonScalarOrNested(rng, 1),
    );
  // 随机打乱顺序（重复键后者胜，顺序有意义）。
  for (int i = entries.length - 1; i > 0; i--) {
    final int j = rng.below(i + 1);
    final String t = entries[i];
    entries[i] = entries[j];
    entries[j] = t;
  }
  final String ws = rng.chance(10)
      ? rng.pick(<String>[' ', '\n', '\t', '\r\n  '])
      : '';
  return '{$ws${entries.join(',$ws')}$ws}';
}

String _jsonDocument(
  _Rng rng, {
  required int items,
  required int distinctTimes,
}) {
  final StringBuffer rows = StringBuffer();
  for (int i = 0; i < items; i++) {
    if (i > 0) rows.write(rng.chance(90) ? ',' : ', \n');
    rows.write(_jsonRow(rng, distinctTimes: distinctTimes));
  }
  final int shape = rng.below(100);
  String doc;
  if (shape < 85) {
    final String count = rng.chance(50) ? '"count":$items,' : '';
    doc = '{$count"comments":[$rows]}';
  } else if (shape < 88) {
    doc = '{"comments":[$rows],"comments":[]}';
  } else if (shape < 90) {
    doc = '{"comments":[],"comments":[$rows]}';
  } else if (shape < 92) {
    doc = '[$rows]';
  } else if (shape < 94) {
    doc = '{"comments":{"0":1}}';
  } else if (shape < 95) {
    doc = '{"Comments":[$rows]}';
  } else if (shape < 96) {
    doc = rng.pick(<String>[
      '"comments"',
      '1',
      'null',
      '-',
      '[1',
      '{"comments":null}',
      '',
    ]);
  } else if (shape < 98) {
    doc =
        '${rng.pick(<String>[' ', '\n', '\r\n\t', ' ', '﻿'])}{"comments":[$rows]}${rng.pick(<String>[' ', '\n', '', 'x', ' ,'])}';
  } else {
    doc = '{"comments":[$rows]';
  }
  final int mutate = rng.below(100);
  if (mutate < 4 && doc.isNotEmpty) {
    doc = doc.substring(0, rng.below(doc.length));
  } else if (mutate < 8 && doc.isNotEmpty) {
    final int at = rng.below(doc.length);
    doc =
        doc.substring(0, at) +
        rng.pick(<String>[
          ',',
          '}',
          ']',
          'x',
          '\u0001',
          '"',
          '\\',
          '0',
          '-',
          '.',
          'e',
          ' ',
          ' ',
          'tru',
          '\\u12',
        ]) +
        doc.substring(at);
  } else if (mutate < 10 && doc.isNotEmpty) {
    final int at = rng.below(doc.length);
    doc = doc.substring(0, at) + doc.substring(at + 1);
  }
  return doc;
}

const List<String> _jsonSoupTokens = <String>[
  '{',
  '}',
  '[',
  ']',
  ',',
  ':',
  '"',
  '\\',
  'u',
  '0',
  '1',
  '-',
  '+',
  '.',
  'e',
  'E',
  't',
  'r',
  'u',
  'e',
  'n',
  'l',
  'f',
  'a',
  's',
  ' ',
  '\n',
  '\u0001',
  ' ',
  'x',
  '"m"',
  '"p"',
  '"1,1,255"',
  '\\u0041',
  '\\ud800',
  '1e400',
  'true',
  'null',
];

String _jsonSoup(_Rng rng) {
  final StringBuffer out = StringBuffer('{"comments":[{"p":"1,1,255","m":');
  final int n = 1 + rng.below(10);
  for (int i = 0; i < n; i++) {
    out.write(rng.pick(_jsonSoupTokens));
  }
  out.write('}]}');
  return out.toString();
}

const List<int> _shiftMsTokens = <int>[
  0,
  0,
  0,
  500,
  -500,
  -1000000,
  1 << 40,
  -(1 << 62),
  9223372036854775807,
  -9223372036854775808,
  1073741824,
  -1073741824,
  1,
];

const List<double> _shiftSecondsTokens = <double>[
  0.0,
  0.0,
  1.5,
  -0.25,
  1e300,
  -1e300,
  double.infinity,
  double.negativeInfinity,
  double.nan,
  1e-300,
  9.3e15,
  -2.5,
  0.0005,
  1073741.824,
];

/// 手写边界用例（与随机语料一起进摘要）。
const List<String> _handwrittenXml = <String>[
  // 现有测试里的样例。
  '<i>\n  <d p="1.25,1,25,16777215,0,0,abc,1">こんにちは &amp; テスト</d>\n  <d p="2.5,5,25,16711680,0,0,abc,2">上固定</d>\n</i>\n',
  '<i>\n  <d>missing p</d>\n  <d p="bad,1,25,16777215">bad time</d>\n  <d p="3,7,25,16777215">advanced positioned comment</d>\n  <d p="4,4,25,255">bottom</d>\n</i>\n',
  '<i><d p="1.5,1,25,16777215,0,0,0,0">hello</d><d p="3,5,25,16711680,0,0,0,0">pinned top</d><d p="2,4,25,255,0,0,0,0">pinned bottom</d></i>',
  '<i/>',
  '<i></i>',
  '',
  ' ',
  'x',
  '<',
  '<i>',
  '</i>',
  '<i/><i/>',
  '<i/>tail',
  'lead<i/>',
  '﻿<i><d p="1,1,25,255">bom</d></i>',
  '<?xml version="1.0"?><i><d p="1,1,25,255">x</d></i>',
  ' <?xml version="1.0"?><i/>', '<!--c--><?xml version="1.0"?><i/>',
  '<?xml version="1.0"?><?xml version="1.0"?><i/>',
  '<!DOCTYPE i><?xml version="1.0"?><i/>',
  '<i/><?xml version="1.0"?>',
  '<i><?xml version="1.0"?></i>',
  '<i><!DOCTYPE i></i>',
  '<!DOCTYPE i><!DOCTYPE i><i/>', '<i/><!DOCTYPE i>',
  '<i><d p="1,1,25,255">a<d p="2,1,25,255">b</d>c</d></i>',
  '<i><d p="1,1,25,255"><![CDATA[ cdata &amp; <tag> ]]></d></i>',
  '<i><d p="1,1,25,255"><!-- only comment --></d></i>',
  '<i><d p="1,1,25,255">\u0001\u0002ctl\u001F</d></i>',
  '<i><d p="1,1,25,255">&#x1F600;&#xD83D;&#xDE00;&#xD800;x</d></i>',
  '<i><d p="1,1,25,255">a < b</d></i>', '<i><d p="1,1,25,255">a > b</d></i>',
  '<i><d p="1,1,25,255">x</D></i>',
  '<i><d p="1,1,25,255">x</d ></i>',
  '<i><d p="1,1,25,255">x</ d></i>',
  '<i><d p="1,1,25,255" p="9,4,25,255">dup</d></i>',
  "<i><d p='1,4,25,255'>single</d></i>",
  '<i><d p=a>unquoted</d></i>',
  '<i><d p=1,1,25,255>bad unquoted</d></i>',
  '<i><d p>novalue</d></i>',
  '<i><d p="1,1,25,255"q="x">noSpace</d></i>',
  '<i><d\tp\r\n=\n"1,1,25,255"　>ws</d></i>',
  '<i><d p="1,1,25,255"﻿>bomspace</d></i>',
  '<i><x:d p="1,1,25,255">ns</x:d></i>',
  '<i xmlns="urn:a"><d p="1,1,25,255">defaultns</d></i>',
  '<i><d x:p="1,1,25,255" p="2,1,25,255">nsattr</d></i>',
  '<i><d p="1,1,25,255">\r\ncrlf\r\n</d></i>',
  '<i><d p="1,1,25,255">  　﻿\u0085  </d></i>',
  '<i><d p="Infinity,1,25,255">inf</d></i>',
  '<i><d p="NaN,7,25,255">nan bad mode</d></i>',
  '<i><d p="1e400,4,25,255">overflow</d><d p="1,1,25,255">ok</d></i>',
  '<i><d p="1073741.824,1,25,255">max</d><d p="1073741.825,1,25,255">over</d><d p="-5,1,25,255">neg</d></i>',
  '<i><d p="1,0x5,25,0xFF00FF">hex</d><d p="1,+4,25,-1">signs</d></i>',
  '<i><d p="1,1,25">short</d><d p="1,1">shorter</d><d p="">empty</d></i>',
  '<i><d p="&#49;&#44;4&#44;25&#44;255">entity commas</d></i>',
  '<!DOCTYPE i [ <!ENTITY a "]>"> ]><i><d p="1,1,25,255">x</d></i>',
  '<!DOCTYPE i [ <d p="1,1,25,255">hidden</d> ]><i/>',
  '<!DOCTYPE i [ <!ELEMENT x> ]junk><i/>',
  '<i><?pi x?><d p="1,1,25,255">x<?pi y?>y</d></i>',
  '<i><d p="1,1,25,255">&amp</d></i>',
  '<i><d p="1,1,25,255">&#x0041;&#X0041;&#0065;&#x;&#;&# ;</d></i>',
  '<i><d p="1,1,25,255">\uD800</d><d p="1,1,25,255">\uDC00x</d></i>',
  '<\u{10000}><d p="1,1,25,255">astral name</d></\u{10000}>', '<\uD800/>',
  '<i><d p="1,1,25,255">unclosed</i>',
  '<i><d p="1,1,25,255">x</d>',
  '<i><d p="1,1,25,255>x</d></i>',
  '<i><![CDATA[x]]><d p="1,1,25,255">ok</d></i>',
  '<![CDATA[root]]><i/>',
  '<i><![CDATA[unterminated</i>',
  '<i><!-- unterminated</i>',
  '<i><?pi unterminated</i>',
  '<i><!x></i>',
  '<i></i ><d/>',
];

const List<String> _handwrittenJson = <String>[
  '{\n  "comments": [\n    {"p": "1.5,1,16777215,0", "m": "流れる"},\n    {"p": "2.25,5,16711935,0", "m": "上"},\n    {"p": "bad", "m": "bad"}\n  ]\n}\n',
  '{\n  "comments": [\n    {"time": 3.25, "mode": 4, "color": 255, "text": "底"},\n    {"time": "4.5", "type": "scroll", "text": "文字列時間"},\n    {"time": null, "text": "bad"},\n    {"time": 6, "mode": 7, "text": "positioned"}\n  ]\n}\n',
  '{"comments":[{"p":"2.5,1,16777215","m":"first"},{"p":"1.0,1,16777215","m":"second"}]}',
  '{"comments": []}',
  '{"comments":[{"p":"1.00,5,255,100","m":"top"}]}',
  '',
  ' ',
  '{}',
  '[]',
  'null',
  '1',
  '-0',
  '"x"',
  '{"comments":null}',
  '{"comments":{}}',
  '{"comments":[]} ',
  ' \n\t\r{"comments":[]}',
  ' {"comments":[]}',
  '﻿{"comments":[]}',
  '{"comments":[]}x',
  '{"comments":[],}',
  '{"comments":[,]}',
  '{"comments":[1,]}',
  '{"comments" []}',
  "{'comments':[]}",
  '{"comments":[{"m":"x","time":01}]}',
  '{"comments":[{"m":"x","time":1.}]}',
  '{"comments":[{"m":"x","time":.5}]}',
  '{"comments":[{"m":"x","time":+1}]}',
  '{"comments":[{"m":"x","time":1e}]}',
  '{"comments":[{"m":"x","time":1e+}]}',
  '{"comments":[{"m":"x","time":-}]}',
  '{"comments":[{"m":"x","time":-a}]}',
  '{"comments":[{"m":"x","time":NaN}]}',
  '{"comments":[{"m":"x","time":Infinity}]}',
  '{"comments":[{"m":"x","time":tru}]}',
  '{"comments":[{"m":"x","time":nul}]}',
  '{"comments":[{"m":"\u0001"}]}',
  '{"comments":[{"m":"\\x"}]}',
  '{"comments":[{"m":"\\u12G4"}]}',
  '{"comments":[{"m":"\\u12"}]}',
  '{"comments":[{"m":"abc',
  '{"comments":[{"m":"abc\\',
  '{"comments":[{"m":"a\\nb\\u0000c\\ud800\\udc00\\/"}]}',
  '{"comments":[{"m":"\\u00e9\\u00E9"}]}',
  '{"comments":[{"time":1,"m":1.0},{"time":2,"m":-0.0},{"time":3,"m":1e21},{"time":4,"m":1e-7},{"time":5,"m":100},{"time":6,"m":[1,"a",null,true,{"k":[]}]},{"time":7,"m":{}},{"time":8,"m":false}]}',
  '{"comments":[{"time":1,"m":123456789012345678901},{"time":2,"m":-9223372036854775808},{"time":3,"m":9223372036854775808},{"time":4,"m":1e400}]}',
  '{"comments":[{"time":1,"m":0.00000000000000000000000000000000000000001e401},{"time":2,"m":1000000000000000000000e-401},{"time":3,"m":-0e999}]}',
  '{"comments":[{"time":1,"m":"x","mode":1e400}]}',
  '{"comments":[{"time":1,"m":"x","color":1e400}]}',
  '{"comments":[{"time":1e400,"m":"x"}]}',
  '{"comments":[{"time":"Infinity","m":"x"}]}',
  '{"comments":[{"time":"NaN","m":"x","mode":7}]}',
  '{"comments":[{"time":1e400,"m":"x","mode":7}]}',
  '{"comments":[{"p":"Infinity,1,255","m":"x"}]}',
  '{"comments":[{"time":1,"mode":"RİGHT","m":"turkish"},{"time":1,"mode":"Kelvin","m":"k"},{"time":1,"mode":"ſcroll","m":"s"}]}',
  '{"comments":[{"time":1,"mode":4.9,"m":"trunc"},{"time":1,"mode":-0.0,"m":"zero"},{"time":1,"mode":9223372036854775808,"m":"sat"}]}',
  '{"comments":[{"time":1,"color":255.9,"m":"c"},{"time":1,"color":-1.5,"m":"c2"},{"time":1,"color":"255","m":"c3"},{"time":1,"color":1e19,"m":"c4"}]}',
  '{"comments":[{"m":"","text":"fallback"},{"m":null,"text":"fb2","t":2},{"text":null,"m":null,"time":1},{"m":"  ","time":1}]}',
  '{"comments":[{"m":"a","m":"b","time":1},{"time":1,"time":null,"m":"dup time"},{"p":"1,1,255","p":1,"m":"p dup","time":5}]}',
  '{"comments":[{"m":"x","t":"  1.5  "},{"m":"y","start":" 2"},{"m":"z","time":"0x10"}]}',
  '{"comments":[1,"x",null,[],true,{"m":"ok","time":1}]}',
  '{"comments":[{"m":"x","time":true},{"m":"y","time":[1]},{"m":"z","time":{}}]}',
  '{"comments":[{"m":"x","time":1,"mode":null,"type":"top"},{"m":"y","time":1,"mode":true},{"m":"z","time":1,"type":[4]}]}',
  '{"count":2,"comments":[{"cid":1,"p":"6.77,1,16777215,[BiliBili]0afc7011","m":"ルディが飲ませて"}],"comments":[{"p":"1,4,255","m":"last wins"}]}',
  '[{"comments":[]}]',
  '{"comments":[]',
  '{"comments":[{}]}',
  '{"comments":[{"m":"\uD800"}]}',
];

/// 冻结语料的随机种子。
const int kDanmakuCorpusSeed = 0x5EEDDA2A4B1C0001;

/// 构造全部对拍用例（确定性）。[seed] 只给离线对拍换种子扩大覆盖用；冻结摘要只对
/// [kDanmakuCorpusSeed] 成立。
List<DanmakuCase> buildDanmakuCorpus({int seed = kDanmakuCorpusSeed}) {
  final _Rng rng = _Rng(seed);
  final List<DanmakuCase> cases = <DanmakuCase>[];
  for (final String xml in _handwrittenXml) {
    cases.add(DanmakuCase(DanmakuCaseKind.xml, xml));
  }
  for (final String json in _handwrittenJson) {
    cases.add(DanmakuCase(DanmakuCaseKind.json, json));
    cases.add(DanmakuCase(DanmakuCaseKind.json, json, shiftMs: -500));
    for (final double seconds in _shiftSecondsTokens) {
      cases.add(
        DanmakuCase(DanmakuCaseKind.online, json, shiftSeconds: seconds),
      );
    }
  }
  // 随机 XML：多数小文档（插入排序路径），一部分大文档（双枢轴快排、大量同毫秒）。
  for (int i = 0; i < 2500; i++) {
    final int size = i % 25 == 0 ? 33 + rng.below(400) : rng.below(40);
    final int distinct = rng.pick(<int>[0, 0, 1, 2, 3, 5, 8, 50]);
    cases.add(
      DanmakuCase(
        DanmakuCaseKind.xml,
        _xmlDocument(rng, items: size, distinctTimes: distinct),
      ),
    );
  }
  for (int i = 0; i < 1500; i++) {
    cases.add(DanmakuCase(DanmakuCaseKind.xml, _xmlSoup(rng)));
  }
  for (int i = 0; i < 6; i++) {
    cases.add(
      DanmakuCase(
        DanmakuCaseKind.xml,
        _xmlDocument(
          rng,
          items: 1500 + rng.below(2500),
          distinctTimes: <int>[1, 3, 17, 0, 400, 2][i],
        ),
      ),
    );
  }
  // 随机 JSON：本地（shiftMs）与在线（shiftSeconds）两种入口。
  for (int i = 0; i < 2500; i++) {
    final int size = i % 25 == 0 ? 33 + rng.below(400) : rng.below(40);
    final int distinct = rng.pick(<int>[0, 0, 1, 2, 3, 5, 8, 50]);
    final String doc = _jsonDocument(rng, items: size, distinctTimes: distinct);
    if (rng.chance(50)) {
      cases.add(
        DanmakuCase(
          DanmakuCaseKind.json,
          doc,
          shiftMs: rng.chance(70) ? 0 : rng.pick(_shiftMsTokens),
        ),
      );
    } else {
      cases.add(
        DanmakuCase(
          DanmakuCaseKind.online,
          doc,
          shiftSeconds: rng.chance(60) ? 0.0 : rng.pick(_shiftSecondsTokens),
        ),
      );
    }
  }
  for (int i = 0; i < 1500; i++) {
    cases.add(DanmakuCase(DanmakuCaseKind.json, _jsonSoup(rng)));
  }
  for (int i = 0; i < 6; i++) {
    final String doc = _jsonDocument(
      rng,
      items: 1500 + rng.below(2500),
      distinctTimes: <int>[1, 3, 17, 0, 400, 2][i],
    );
    cases.add(
      DanmakuCase(
        DanmakuCaseKind.json,
        doc,
        shiftMs: <int>[0, -500, 0, 250, 0, -1000000][i],
      ),
    );
    cases.add(
      DanmakuCase(
        DanmakuCaseKind.online,
        doc,
        shiftSeconds: <double>[0, 1.5, -0.25, 0, 2.0, 0.0005][i],
      ),
    );
  }
  return cases;
}

void main() {
  test('corpus generator is deterministic and keeps its size', () {
    final List<DanmakuCase> a = buildDanmakuCorpus();
    final List<DanmakuCase> b = buildDanmakuCorpus();
    expect(a.length, b.length);
    final DanmakuDigest da = DanmakuDigest();
    final DanmakuDigest db = DanmakuDigest();
    for (int i = 0; i < a.length; i++) {
      da
        ..addInt(a[i].kind.index)
        ..addString(a[i].input)
        ..addInt(a[i].shiftMs)
        ..addString(a[i].shiftSeconds.toString());
      db
        ..addInt(b[i].kind.index)
        ..addString(b[i].input)
        ..addInt(b[i].shiftMs)
        ..addString(b[i].shiftSeconds.toString());
    }
    expect(da.value, db.value);
    expect(a.length, kDanmakuCorpusSize);
    expect(da.hex, kDanmakuCorpusInputDigest);
  });
}

/// 语料规模与输入摘要（生成器被改动时这里先红）。
const int kDanmakuCorpusSize = 9196;
const String kDanmakuCorpusInputDigest = '2048d03a95039ef9';
