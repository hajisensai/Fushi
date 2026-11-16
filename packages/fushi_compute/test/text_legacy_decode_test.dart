// 本地多字节编码探测的原生绑定（ffc_text_legacy_decode）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。判据本身的用例钉在
// native/fushi_compute/src/legacy_text.rs；这里只测绑定（打包、解包、判不出时返回 null）。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 「表紙/ポスター01.jpg」的 Shift_JIS 字节：「表」尾字节 0x5C（`\`）、「ポ」尾字节 0x7C（`|`）。
final Uint8List _sjisPoster = Uint8List.fromList(<int>[
  149, 92, 142, 134, 47, 131, 124, 131, 88, 131, 94, 129, 91, 48, 49, //
  46, 106, 112, 103,
]);

/// 「表紙/ソード02.jpg」的 Shift_JIS 字节。
final Uint8List _sjisSword = Uint8List.fromList(<int>[
  149, 92, 142, 134, 47, 131, 92, 129, 91, 131, 104, 48, 50, 46, 106, //
  112, 103,
]);

void main() {
  setUpAll(() {
    expect(
      () => FushiCompute.require(),
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('Shift_JIS 名字整批解回日文，ASCII 名字原样', () {
    final ({LegacyTextEncoding encoding, List<String> texts})? r =
        LegacyTextDecoder.decodeBatch(<Uint8List>[
          _sjisPoster,
          Uint8List.fromList(ascii.encode('cover.png')),
          _sjisSword,
        ]);
    expect(r, isNotNull);
    expect(r!.encoding, LegacyTextEncoding.shiftJis);
    expect(r.texts, <String>['表紙/ポスター01.jpg', 'cover.png', '表紙/ソード02.jpg']);
  });

  test('全 ASCII / 空批 / 解不开的字节返回 null', () {
    expect(LegacyTextDecoder.decodeBatch(<Uint8List>[]), isNull);
    expect(
      LegacyTextDecoder.decodeBatch(<Uint8List>[
        Uint8List.fromList(ascii.encode('001.jpg')),
        Uint8List(0),
      ]),
      isNull,
    );
    expect(
      LegacyTextDecoder.decodeBatch(<Uint8List>[
        Uint8List.fromList(<int>[0x61, 0xFF, 0xFF, 0xFF]),
      ]),
      isNull,
    );
  });
}
