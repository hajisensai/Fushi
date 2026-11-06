// 确定性 .torrent 输入语料 + 结果的规范化描述：`torrent_metainfo_native_test.dart` 用它对
// 原生实现（ffc_parse_bencode_*）复算摘要，与删除前旧 Dart 实现在同一语料上冻结的摘要比对。
//
// 语料只由本文件的代码与种子决定（自带 xorshift，不依赖 dart:math 的 Random 实现），改了任何
// 一处生成逻辑，冻结摘要就作废——那等于换了一套输入，只能用旧实现重新生成，不能改摘要了事。
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';

/// 一条输入：字节 + 调用时传的 expectedInfoHash（null = 不传）。
typedef TorrentCase = ({String label, Uint8List bytes, String? expected});

final class _Rng {
  _Rng(int seed) : _state = seed == 0 ? 0x9E3779B97F4A7C15 : seed;

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

List<int> _str(List<int> bytes) => <int>[
  ...ascii.encode('${bytes.length}:'),
  ...bytes,
];

List<int> _s(String text) => _str(utf8.encode(text));

List<int> _int(int value) => ascii.encode('i${value}e');

List<int> _dict(List<(List<int>, List<int>)> entries) => <int>[
  0x64,
  for (final (List<int> k, List<int> v) in entries) ...<int>[...k, ...v],
  0x65,
];

List<int> _list(List<List<int>> items) => <int>[
  0x6c,
  for (final List<int> item in items) ...item,
  0x65,
];

/// 名字 / 路径段的原始字节：ASCII、日文、空白、非法 UTF-8、BOM 开头、空。
List<int> _textBytes(_Rng rng) {
  switch (rng.below(10)) {
    case 0:
      return utf8.encode('[字幕組] 無職転生 第${rng.below(30)}話.mkv');
    case 1:
      return utf8.encode('  padded name ${rng.below(99)}  ');
    case 2:
      return <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('bom${rng.below(9)}')];
    case 3:
      return <int>[
        for (int i = 0; i < 1 + rng.below(8); i++)
          rng.pick(<int>[
            0x80,
            0xC0,
            0xE2,
            0x82,
            0xED,
            0xA0,
            0xF0,
            0x9F,
            0xFF,
            0x41,
          ]),
      ];
    case 4:
      return const <int>[];
    case 5:
      return utf8.encode('\u{1F600}\u{20BB7} 𠮷 ${rng.below(5)}');
    case 6:
      return <int>[0xEF, 0xBB, 0xBF];
    case 7:
      return utf8.encode('\t　 \n');
    default:
      return utf8.encode('file_${rng.below(100000)}.bin');
  }
}

List<int> _pathValue(_Rng rng) {
  if (rng.chance(4)) return _s('not-a-list');
  if (rng.chance(3)) return _list(const <List<int>>[]);
  return _list(<List<int>>[
    for (int i = 0; i < 1 + rng.below(4); i++)
      rng.chance(3) ? _int(rng.below(9)) : _str(_textBytes(rng)),
  ]);
}

List<int> _fileEntry(_Rng rng) {
  if (rng.chance(2)) return _int(1);
  final List<(List<int>, List<int>)> entries = <(List<int>, List<int>)>[
    if (!rng.chance(3))
      (
        _s('length'),
        rng.chance(4) ? _int(-1 - rng.below(5)) : _int(rng.below(1 << 40)),
      ),
    if (!rng.chance(3)) (_s('path'), _pathValue(rng)),
    if (rng.chance(20)) (_s('path.utf-8'), _pathValue(rng)),
    if (rng.chance(10)) (_s('attr'), _s('p')),
  ];
  return _dict(entries);
}

List<int> _info(_Rng rng) {
  final int shape = rng.below(6);
  final List<(List<int>, List<int>)> entries = <(List<int>, List<int>)>[];
  if (shape != 3) {
    entries.add((
      _s('pieces'),
      rng.chance(5)
          ? _int(0)
          : _str(
              List<int>.filled(20 * (1 + rng.below(3)), 0x61 + rng.below(20)),
            ),
    ));
  }
  if (shape >= 3) {
    entries.add((_s('meta version'), _int(rng.chance(85) ? 2 : 1)));
  }
  if (shape >= 3) {
    entries.add((
      _s('file tree'),
      _dict(<(List<int>, List<int>)>[
        (_s('a'), _dict(const <(List<int>, List<int>)>[])),
      ]),
    ));
  }
  if (!rng.chance(10)) {
    entries.add((_s('name'), rng.chance(5) ? _int(3) : _str(_textBytes(rng))));
  }
  if (rng.chance(25)) {
    entries.add((
      _s('name.utf-8'),
      rng.chance(10) ? _int(4) : _str(_textBytes(rng)),
    ));
  }
  entries.add((_s('piece length'), _int(16384 << rng.below(6))));
  if (shape == 0 || shape == 4 || rng.chance(10)) {
    entries.add((
      _s('files'),
      rng.chance(5)
          ? _s('nope')
          : _list(<List<int>>[
              for (int i = 0; i < 1 + rng.below(12); i++) _fileEntry(rng),
            ]),
    ));
  } else {
    entries.add((
      _s('length'),
      rng.chance(8) ? _int(-3) : _int(rng.below(1 << 33)),
    ));
  }
  if (rng.chance(10)) entries.add((_s('private'), _int(1)));
  // 键序打乱：解析器不校验键序，结果也不该依赖它。
  for (int i = entries.length - 1; i > 0; i--) {
    final int j = rng.below(i + 1);
    final (List<int>, List<int>) t = entries[i];
    entries[i] = entries[j];
    entries[j] = t;
  }
  return _dict(entries);
}

Uint8List _torrent(_Rng rng) {
  final List<(List<int>, List<int>)> entries = <(List<int>, List<int>)>[
    (_s('announce'), _s('http://tracker.example/announce')),
    if (!rng.chance(4)) (_s('info'), _info(rng)),
    if (rng.chance(20))
      (_s('creation date'), _int(1700000000 + rng.below(1 << 20))),
    if (rng.chance(10))
      (_s('url-list'), _list(<List<int>>[_s('http://seed.example/')])),
  ];
  return Uint8List.fromList(_dict(entries));
}

Uint8List _mutate(_Rng rng, Uint8List source) {
  final List<int> bytes = source.toList();
  switch (rng.below(5)) {
    case 0:
      return Uint8List.fromList(bytes.sublist(0, rng.below(bytes.length)));
    case 1:
      for (int i = 0; i < 1 + rng.below(3); i++) {
        bytes[rng.below(bytes.length)] = rng.below(256);
      }
    case 2:
      bytes.insert(
        rng.below(bytes.length + 1),
        rng.pick(<int>[0x30, 0x2d, 0x65, 0x64, 0x6c, 0x69, 0x3a, 0x39]),
      );
    case 3:
      bytes.removeAt(rng.below(bytes.length));
    default:
      bytes.addAll(<int>[0x65]);
  }
  return Uint8List.fromList(bytes);
}

/// 手写的边界输入（bencode 文本，`\xNN` 写法用 latin1 编码进字节）。
const List<String> kHandWrittenTorrents = <String>[
  'le',
  'i1e',
  '4:spam',
  'd',
  'de',
  'dex',
  'd4:infod6:pieces0:ee',
  'd4:infod6:pieces0:4:name0:ee',
  'd4:infod6:pieces0:6:lengthi5e4:name1:aee',
  'd4:infod6:pieces0:6:lengthi-1e4:name1:aee',
  'd4:infod12:meta versioni2eee',
  'd4:infod12:meta versioni3eee',
  'd4:infod12:meta version1:2ee',
  'd4:infoi1ee',
  'd4:info4:spame',
  'd4:infodee',
  'd4:infod6:piecesi1eee',
  'd1:ai-0ee',
  'd1:ai03ee',
  'd1:ai-03ee',
  'd1:aiee',
  'd1:ai-ee',
  'd1:ai--1ee',
  'd1:ai1-2ee',
  'd1:ai+1ee',
  'd1:ai 1ee',
  'd1:ai9223372036854775807ee',
  'd1:ai-9223372036854775808ee',
  'd1:ai9223372036854775808ee',
  'd1:ai-9223372036854775809ee',
  'd1:ai0ee',
  'd1:ai1',
  'd1:ai',
  'd1:a01:be',
  'd1:a00:e',
  'd1:a0:e',
  'd:e',
  'd1:a5:abe',
  'd1:a99999999999999999999:e',
  'd1:a9223372036854775807:e',
  'd1:a9223372036854775790:e',
  'd1:a1x:ae',
  'd1:a-1:ae',
  'dxe',
  'd1:ax',
  'd1:a',
  'd1:',
  'd1',
  'd1:ai1e1:ai2ee',
  'd1:ad1:bi1e1:bi2eee',
  'd1:ad1:bi1e1:ci2eee',
  'd1:al1:bd1:ci1e1:ci1eeee',
  'd1:\xffi1e1:\xfei2ee',
  'd1:\xffi1e2:\xff\xffi2ee',
  'd4:infod6:pieces0:e7:\xef\xbb\xbfinfod6:pieces0:ee',
  'd7:\xef\xbb\xbfinfod6:pieces0:6:lengthi1e4:name1:xee',
  'd4:infod6:pieces0:ee4:infod6:pieces0:ee',
  'd4:infod6:pieces0:ee1:ai1eex',
  'd4:infod6:pieces0:eee',
  'd4:infod5:filesld6:lengthi1e4:pathl1:aeed6:lengthi2e4:pathl1:b1:ceeee6:pieces0:ee',
  'd4:infod5:filesli1ee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1eee6:pieces0:ee',
  'd4:infod5:filesld4:pathl1:aeee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi-1e4:pathl1:aeee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e4:pathleee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e4:pathl0:eee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e4:pathli1eeee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e4:path1:aee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e10:path.utf-81:a4:pathl1:beee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e10:path.utf-8l1:\xe6\x97\xa5e4:pathl1:beee6:pieces0:ee',
  'd4:infod5:filesld6:lengthi1e4:pathl2:\xc3\x28eee6:pieces0:ee',
  'd4:infod5:files4:nope6:lengthi9e4:name1:z6:pieces0:ee',
  'd4:infod5:filesle6:pieces0:ee',
  'd4:infod10:name.utf-8i1e4:name1:a6:pieces0:ee',
  'd4:infod10:name.utf-80:4:name1:a6:pieces0:ee',
  'd4:infod10:name.utf-83:\xef\xbb\xbf4:name1:a6:lengthi1e6:pieces0:ee',
  'd4:infod4:name3:   6:lengthi1e6:pieces0:ee',
  'd4:infod4:name4:\xef\xbb\xbf a6:lengthi1e6:pieces0:ee',
  'd4:infod4:name5:\xef\xbb\xbf\xef\xbb\xbf6:lengthi1e6:pieces0:ee',
  'd4:infod4:name2:\xe2\x826:lengthi1e6:pieces0:ee',
  'd4:infod4:name3:\xed\xa0\x806:lengthi1e6:pieces0:ee',
  'd4:infod4:name4:\xf4\x90\x80\x806:lengthi1e6:pieces0:ee',
  'd4:infod4:name2:\xc0\x806:lengthi1e6:pieces0:ee',
  'd4:infod4:name1:\x006:lengthi1e6:pieces0:ee',
  'd4:infod9:file treede12:meta versioni2e4:name4:testee',
  'd4:infod9:file treede12:meta versioni2e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaa6:lengthi3eee',
  'd4:infod9:file treede12:meta versioni2e4:name4:test6:lengthi3eee',
];

Uint8List _latin1(String text) => Uint8List.fromList(<int>[
  for (final int unit in text.codeUnits) unit & 0xFF,
]);

Uint8List _nested(String open, int depth) {
  final StringBuffer out = StringBuffer('d1:a');
  for (int i = 0; i < depth; i++) {
    out.write(open);
  }
  for (int i = 0; i < depth; i++) {
    out.write(open == 'd' ? '1:ble' : 'e');
  }
  out.write('e');
  return _latin1(out.toString());
}

Uint8List _manyValues(int count) {
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(ascii.encode('d1:al'));
  final Uint8List one = ascii.encode('i1e');
  for (int i = 0; i < count; i++) {
    out.add(one);
  }
  out.add(ascii.encode('ee'));
  return out.takeBytes();
}

/// 多文件大种子（[files] 个文件，路径含日文与少量非法字节）。
Uint8List largeMultiFileTorrent(int files, {int seed = 7}) {
  final _Rng rng = _Rng(seed);
  final BytesBuilder list = BytesBuilder(copy: false)..addByte(0x6c);
  for (int i = 0; i < files; i++) {
    final List<int> component = i % 97 == 0
        ? <int>[...utf8.encode('壊れ'), 0xFF, ...utf8.encode('$i')]
        : utf8.encode('第${i ~/ 100}巻 ${rng.below(1 << 20)}.flac');
    list.add(
      _dict(<(List<int>, List<int>)>[
        (_s('length'), _int(rng.below(1 << 31))),
        (_s('path'), _list(<List<int>>[_s('ディスク${i % 7}'), _str(component)])),
      ]),
    );
  }
  list.addByte(0x65);
  final Uint8List info = Uint8List.fromList(
    _dict(<(List<int>, List<int>)>[
      (_s('files'), list.takeBytes()),
      (_s('name'), _s('大きい種 $files件')),
      (_s('piece length'), _int(1 << 22)),
      (_s('pieces'), _str(List<int>.generate(20 * 256, (int i) => i & 0xFF))),
    ]),
  );
  return Uint8List.fromList(
    _dict(<(List<int>, List<int>)>[
      (_s('announce'), _s('udp://t/')),
      (_s('info'), info),
    ]),
  );
}

/// 完整语料（确定性）。
List<TorrentCase> buildTorrentCorpus() {
  final List<TorrentCase> cases = <TorrentCase>[];
  for (int i = 0; i < kHandWrittenTorrents.length; i++) {
    cases.add((
      label: 'hand#$i',
      bytes: _latin1(kHandWrittenTorrents[i]),
      expected: null,
    ));
  }
  for (final int depth in <int>[98, 99, 100, 101, 150]) {
    cases.add((
      label: 'list-depth$depth',
      bytes: _nested('l', depth),
      expected: null,
    ));
    cases.add((
      label: 'dict-depth$depth',
      bytes: _nested('d', depth),
      expected: null,
    ));
  }
  cases.add((
    label: 'values-999999',
    bytes: _manyValues(999999),
    expected: null,
  ));
  cases.add((
    label: 'values-1000000',
    bytes: _manyValues(1000000),
    expected: null,
  ));
  cases.add((
    label: 'large-2000',
    bytes: largeMultiFileTorrent(2000),
    expected: null,
  ));

  final _Rng rng = _Rng(20261018);
  for (int i = 0; i < 600; i++) {
    final Uint8List torrent = _torrent(rng);
    final String? expected = switch (rng.below(8)) {
      0 => '0' * 40,
      1 => 'urn:btih:${'A' * 40}',
      2 => 'not-a-hash',
      3 => '  URN:BTMH:1220${'b' * 64}  ',
      _ => null,
    };
    cases.add((label: 'gen#$i', bytes: torrent, expected: expected));
    for (int m = 0; m < 3; m++) {
      cases.add((
        label: 'gen#$i/mut$m',
        bytes: _mutate(rng, torrent),
        expected: null,
      ));
    }
  }
  return cases;
}

/// 被比对的实现：新实现就是 [inspectTorrentMetainfo]；对拍时传旧实现（类型不同，按
/// 动态成员读取：两者的异常都是带 `code` 的 [FormatException]）。
typedef TorrentInspector = Object Function(Uint8List bytes, String? expected);

Object nativeTorrentInspector(Uint8List bytes, String? expected) =>
    inspectTorrentMetainfo(bytes, expectedInfoHash: expected);

/// 结果的规范化描述（异常类型 + 码 + 消息，或全部字段）。
String describeTorrentOutcome(
  TorrentCase input, [
  TorrentInspector inspect = nativeTorrentInspector,
]) {
  final dynamic r;
  try {
    r = inspect(input.bytes, input.expected);
  } on FormatException catch (e) {
    // `Enum.name` 是扩展 getter，动态调用拿不到；`toString()` 是 `类型名.值名`。
    final String code = '${(e as dynamic).code}'.split('.').last;
    return 'TME $code ${e.message}';
  } on Object catch (e) {
    return 'other ${e.runtimeType} $e';
  }
  final String? name = r.suggestedName as String?;
  final StringBuffer out = StringBuffer()
    ..write('ok id=${r.torrentId} v1=${r.v1InfoHash} v2=${r.v2InfoHash}')
    ..write(' name=${name == null ? 'null' : jsonEncode(name)}')
    ..write(' bytes=${_sameBytes(r.bytes as Uint8List, input.bytes)}')
    ..write(' files=${(r.files as List<Object?>).length}');
  for (final dynamic f in r.files as List<Object?>) {
    out.write(' [${f.index} ${f.length} ${jsonEncode(f.path)}]');
  }
  return out.toString();
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 64 位 FNV-1a（对每条描述的 UTF-8 + 换行）。
int digestOutcomes(Iterable<String> outcomes) {
  int hash = 0xcbf29ce484222325;
  for (final String outcome in outcomes) {
    for (final int byte in utf8.encode('$outcome\n')) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
  }
  return hash;
}
