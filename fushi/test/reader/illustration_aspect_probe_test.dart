import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/illustration_aspect_probe.dart';
import 'package:image/image.dart' as img;

/// BUG-2589：插图册横版图占两列，宽高比只读文件头拿。这里用合成头验五种格式
/// 的解析位置，再用真 PNG / JPEG 文件验 isolate 入口（含「头部不够、整文件回读」）。
void main() {
  Uint8List be32(int v) => Uint8List.fromList(<int>[
    v >> 24 & 0xFF,
    v >> 16 & 0xFF,
    v >> 8 & 0xFF,
    v & 0xFF,
  ]);
  Uint8List le16(int v) => Uint8List.fromList(<int>[v & 0xFF, v >> 8 & 0xFF]);
  Uint8List le32(int v) => Uint8List.fromList(<int>[
    v & 0xFF,
    v >> 8 & 0xFF,
    v >> 16 & 0xFF,
    v >> 24 & 0xFF,
  ]);
  Uint8List cat(List<List<int>> parts) =>
      Uint8List.fromList(parts.expand((List<int> p) => p).toList());

  group('imageSizeFromHeader', () {
    test('PNG：IHDR 大端宽高', () {
      final Uint8List bytes = cat(<List<int>>[
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        be32(13),
        'IHDR'.codeUnits,
        be32(1600),
        be32(900),
      ]);
      expect(imageSizeFromHeader(bytes), (width: 1600, height: 900));
      expect(imageAspectRatioFromHeader(bytes), closeTo(1600 / 900, 1e-9));
    });

    test('GIF：逻辑屏幕小端宽高', () {
      final Uint8List bytes = cat(<List<int>>[
        'GIF89a'.codeUnits,
        le16(320),
        le16(240),
      ]);
      expect(imageSizeFromHeader(bytes), (width: 320, height: 240));
    });

    test('BMP：BITMAPINFOHEADER 小端宽高，负高取绝对值', () {
      final Uint8List bytes = cat(<List<int>>[
        'BM'.codeUnits,
        List<int>.filled(16, 0),
        le32(640),
        le32(-480),
      ]);
      expect(imageSizeFromHeader(bytes), (width: 640, height: 480));
    });

    test('WebP：VP8 / VP8L / VP8X 三种块', () {
      Uint8List riff(String chunk, List<int> payload) => cat(<List<int>>[
        'RIFF'.codeUnits,
        le32(4 + 8 + payload.length),
        'WEBP'.codeUnits,
        chunk.codeUnits,
        le32(payload.length),
        payload,
      ]);
      // VP8：3 字节帧标签 + 起始码 + 14 位宽高。
      expect(
        imageSizeFromHeader(
          riff(
            'VP8 ',
            cat(<List<int>>[
              <int>[0, 0, 0, 0x9D, 0x01, 0x2A],
              le16(800),
              le16(600),
              <int>[0, 0],
            ]),
          ),
        ),
        (width: 800, height: 600),
      );
      // VP8L：签名 2F + 28 位打包 (宽-1, 高-1)。
      const int w = 1024, h = 768;
      const int packed = (w - 1) | ((h - 1) << 14);
      expect(
        imageSizeFromHeader(
          riff(
            'VP8L',
            cat(<List<int>>[
              <int>[0x2F],
              le32(packed),
              <int>[0, 0, 0, 0, 0],
            ]),
          ),
        ),
        (width: w, height: h),
      );
      // VP8X：24 位画布宽高存「-1」。
      expect(
        imageSizeFromHeader(
          riff(
            'VP8X',
            cat(<List<int>>[
              <int>[0, 0, 0, 0],
              <int>[(1919) & 0xFF, (1919) >> 8 & 0xFF, 0],
              <int>[(1079) & 0xFF, (1079) >> 8 & 0xFF, 0],
              <int>[0, 0, 0, 0],
            ]),
          ),
        ),
        (width: 1920, height: 1080),
      );
    });

    test('JPEG：跳过 APP 段走到 SOFn，高在前宽在后', () {
      final List<int> app1 = List<int>.filled(100, 0);
      final Uint8List bytes = cat(<List<int>>[
        <int>[0xFF, 0xD8],
        <int>[0xFF, 0xE1],
        <int>[0x00, 102], // 段长含长度字节。
        app1,
        <int>[0xFF, 0xC2], // SOF2（渐进式）。
        <int>[0x00, 0x11, 0x08],
        <int>[0x03, 0x84], // 高 900
        <int>[0x06, 0x40], // 宽 1600
      ]);
      expect(imageSizeFromHeader(bytes), (width: 1600, height: 900));
    });

    test('JPEG：字节在走到 SOF 前用完 → null（交调用方整文件重读）', () {
      final Uint8List bytes = cat(<List<int>>[
        <int>[0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x00],
        List<int>.filled(40, 0),
      ]);
      expect(imageSizeFromHeader(bytes), isNull);
    });

    test('认不出的格式 / 字节不够 → null', () {
      expect(
        imageSizeFromHeader(Uint8List.fromList('<svg/>'.codeUnits)),
        isNull,
      );
      expect(
        imageSizeFromHeader(Uint8List.fromList(<int>[0x89, 0x50, 0x4E])),
        isNull,
      );
      expect(imageSizeFromHeader(Uint8List(0)), isNull);
    });
  });

  group('probeIllustrationAspectRatios', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('fushi_aspect_probe_');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('真 PNG / JPEG 文件按路径给出宽/高；坏文件与不存在的路径不进结果', () {
      final File wide = File('${dir.path}/wide.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 2)));
      final File tall = File('${dir.path}/tall.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 2, height: 4)));
      final File bad = File('${dir.path}/bad.png')..writeAsStringSync('nope');

      final Map<String, double> result = probeIllustrationAspectRatios(<String>[
        wide.path,
        tall.path,
        bad.path,
        '${dir.path}/missing.png',
      ]);
      expect(result.keys, unorderedEquals(<String>[wide.path, tall.path]));
      expect(result[wide.path], closeTo(2, 1e-9));
      expect(result[tall.path], closeTo(0.5, 1e-9));
    });

    test('JPEG 的 SOF 在 64 KiB 之后：头部读不到就整文件回读', () {
      // 两个 40 KiB 的 APP 段（大 EXIF / 分块 ICC 的形状；单段最长 64 KiB）把
      // SOF 推到 80 KiB 处。
      const int appLength = 40 * 1024;
      final List<int> app = <int>[
        0xFF, 0xE2, (appLength + 2) >> 8 & 0xFF, (appLength + 2) & 0xFF, //
        ...List<int>.filled(appLength, 0),
      ];
      final List<int> bytes = <int>[
        0xFF, 0xD8, //
        ...app,
        ...app,
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, //
      ];
      final File file = File('${dir.path}/bigexif.jpg')
        ..writeAsBytesSync(bytes);
      expect(file.lengthSync(), greaterThan(kIllustrationProbeHeadBytes));

      final Map<String, double> result = probeIllustrationAspectRatios(<String>[
        file.path,
      ]);
      expect(result[file.path], closeTo(512 / 256, 1e-9));
    });
  });
}
