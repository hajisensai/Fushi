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

  group('decodeDocument（ffc_text_legacy_decode_document）', () {
    /// 重复 [repeat] 遍「<ASCII 时间轴>\n<一行 Shift_JIS 文件名>\n」：一份整文档。
    Uint8List sjisDocument(int repeat) {
      final BytesBuilder b = BytesBuilder();
      for (int i = 0; i < repeat; i++) {
        b.add(ascii.encode('${i + 1}\n00:00:01,000 --> 00:00:02,000\n'));
        b.add(_sjisPoster);
        b.addByte(0x0A);
      }
      return b.toBytes();
    }

    String expectedDocument(int repeat) => <String>[
      for (int i = 0; i < repeat; i++)
        '${i + 1}\n00:00:01,000 --> 00:00:02,000\n表紙/ポスター01.jpg\n',
    ].join();

    test('整份 Shift_JIS 文档解回日文', () {
      final ({LegacyTextEncoding encoding, String text})? r =
          LegacyTextDecoder.decodeDocument(sjisDocument(3));
      expect(r, isNotNull);
      expect(r!.encoding, LegacyTextEncoding.shiftJis);
      expect(r.text, expectedDocument(3));
    });

    test('整文档容错：混进一个坏字节仍判得出，短批口径判不出', () {
      final Uint8List clean = sjisDocument(40);
      final Uint8List damaged = Uint8List.fromList(<int>[
        ...clean.sublist(0, clean.length - 1),
        0xFF,
        0x0A,
      ]);
      expect(LegacyTextDecoder.decodeBatch(<Uint8List>[damaged]), isNull);
      final ({LegacyTextEncoding encoding, String text})? r =
          LegacyTextDecoder.decodeDocument(damaged);
      expect(r, isNotNull);
      expect(r!.encoding, LegacyTextEncoding.shiftJis);
      expect(r.text, '${expectedDocument(40).trimRight()}\u{FFFD}\n');
    });

    test('空 / 全 ASCII / UTF-8 / 解不开的字节返回 null', () {
      expect(LegacyTextDecoder.decodeDocument(Uint8List(0)), isNull);
      expect(
        LegacyTextDecoder.decodeDocument(
          Uint8List.fromList(ascii.encode('WEBVTT\n\nhi\n')),
        ),
        isNull,
      );
      expect(
        LegacyTextDecoder.decodeDocument(
          Uint8List.fromList(utf8.encode(expectedDocument(3))),
        ),
        isNull,
      );
      expect(
        LegacyTextDecoder.decodeDocument(
          Uint8List.fromList(<int>[0x61, 0xFF, 0xFF, 0xFF]),
        ),
        isNull,
      );
    });
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
