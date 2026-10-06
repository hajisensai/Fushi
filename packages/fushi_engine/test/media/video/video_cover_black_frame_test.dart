// BUG-3044：视频自动抽帧封面落在黑场（片头 logo 淡出 / 场间黑场），首页「继续」卡
// 显示纯黑块。抽帧改为按候选时刻依次尝试、取第一张非黑帧。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _solidJpeg(int r, int g, int b, {int width = 320, int height = 180}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

/// 近黑：底色 4，叠一点 ±3 的确定性噪声（模拟压缩噪点 / 淡出末段）。
Uint8List _nearBlackJpeg() {
  final img.Image image = img.Image(width: 320, height: 180);
  for (final img.Pixel pixel in image) {
    final int v = 4 + ((pixel.x * 7 + pixel.y * 13) % 7) - 3;
    pixel.setRgb(v, v, v);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

/// 正常画面：横向亮度渐变 + 彩色块。
Uint8List _normalJpeg() {
  final img.Image image = img.Image(width: 320, height: 180);
  for (final img.Pixel pixel in image) {
    final int v = (pixel.x * 255) ~/ 319;
    pixel.setRgb(v, (v + 80) % 256, 255 - v);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// 黑底上一块亮 logo：均值低但对比强，有可辨认内容，不算黑帧。
Uint8List _logoOnBlackJpeg() {
  final img.Image image = img.Image(width: 320, height: 180);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  img.fillRect(
    image,
    x1: 130,
    y1: 70,
    x2: 190,
    y2: 110,
    color: img.ColorRgb8(240, 240, 240),
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

void main() {
  group('isNearlyBlackFrame', () {
    test('全黑帧判黑', () {
      expect(isNearlyBlackFrame(_solidJpeg(0, 0, 0)), isTrue);
    });

    test('近黑（低均值 + 轻噪声）判黑', () {
      expect(isNearlyBlackFrame(_nearBlackJpeg()), isTrue);
      expect(isNearlyBlackFrame(_solidJpeg(10, 10, 10)), isTrue);
    });

    test('正常画面不判黑', () {
      expect(isNearlyBlackFrame(_normalJpeg()), isFalse);
    });

    test('暗但非黑场（均值 40）不判黑——阈值保守', () {
      expect(isNearlyBlackFrame(_solidJpeg(40, 40, 40)), isFalse);
    });

    test('黑底亮 logo 不判黑（有内容）', () {
      expect(isNearlyBlackFrame(_logoOnBlackJpeg()), isFalse);
    });

    test('解码不出的字节不判黑（交给发布校验拦）', () {
      expect(
        isNearlyBlackFrame(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isFalse,
      );
    });

    test('小于采样宽度的图直接统计', () {
      expect(
        isNearlyBlackFrame(_solidJpeg(0, 0, 0, width: 16, height: 9)),
        isTrue,
      );
    });
  });

  group('coverFrameCandidateSeconds', () {
    test('默认 10s：先 10s 再 30 / 90 / 240', () {
      expect(coverFrameCandidateSeconds(10), <double>[10, 30, 90, 240]);
    });

    test('只追加严格更晚的时刻，候选有界', () {
      expect(coverFrameCandidateSeconds(90), <double>[90, 240]);
      expect(coverFrameCandidateSeconds(300), <double>[300]);
    });
  });

  group('grabFirstNonBlackCoverFrame', () {
    late Directory dir;
    late String outputPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('bug2965_cover_');
      outputPath = p.join(dir.path, 'video_book.jpg');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// 按「时刻 → 帧字节」表抽帧的替身；表里没有的时刻 = seek 越界拿不到帧。
    ({CoverFrameGrabber grab, List<double> calls, List<bool> diagnostics})
    fakeGrabber(Map<double, Uint8List> frames) {
      final List<double> calls = <double>[];
      final List<bool> diagnostics = <bool>[];
      Future<String?> grab({
        required String outputPath,
        required double atSeconds,
        required bool diagnosticOnly,
      }) async {
        calls.add(atSeconds);
        diagnostics.add(diagnosticOnly);
        final Uint8List? bytes = frames[atSeconds];
        if (bytes == null) return null;
        File(outputPath).writeAsBytesSync(bytes);
        return outputPath;
      }

      return (grab: grab, calls: calls, diagnostics: diagnostics);
    }

    List<String> leftovers() => dir
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .where((String name) => name != 'video_book.jpg')
        .toList();

    test('首帧黑 → 取第二个候选', () async {
      final Uint8List black = _solidJpeg(0, 0, 0);
      final Uint8List good = _normalJpeg();
      final fake = fakeGrabber(<double, Uint8List>{
        10: black,
        30: good,
        90: _normalJpeg(),
      });

      final String? result = await grabFirstNonBlackCoverFrame(
        outputPath: outputPath,
        candidateSeconds: coverFrameCandidateSeconds(10),
        diagnosticOnly: false,
        grab: fake.grab,
      );

      expect(result, outputPath);
      expect(File(outputPath).readAsBytesSync(), good);
      expect(fake.calls, <double>[10, 30], reason: '拿到非黑帧就停');
      expect(fake.diagnostics, <bool>[
        false,
        true,
      ], reason: '首个候选沿用调用方开关，补救候选恒为诊断级');
      expect(leftovers(), isEmpty, reason: '未选中的黑帧候选必须清掉');
    });

    test('全黑 → 保留第一张', () async {
      final Uint8List firstBlack = _solidJpeg(0, 0, 0);
      final fake = fakeGrabber(<double, Uint8List>{
        10: firstBlack,
        30: _nearBlackJpeg(),
        90: _solidJpeg(2, 2, 2),
        240: _solidJpeg(1, 1, 1),
      });

      final String? result = await grabFirstNonBlackCoverFrame(
        outputPath: outputPath,
        candidateSeconds: coverFrameCandidateSeconds(10),
        diagnosticOnly: true,
        grab: fake.grab,
      );

      expect(result, outputPath);
      expect(File(outputPath).readAsBytesSync(), firstBlack);
      expect(fake.calls, <double>[10, 30, 90, 240], reason: '候选次数有界');
      expect(leftovers(), isEmpty);
    });

    test('seek 越界拿不到帧 → 停止，不再试更晚时刻，回落第一张', () async {
      final Uint8List firstBlack = _solidJpeg(0, 0, 0);
      final fake = fakeGrabber(<double, Uint8List>{10: firstBlack});

      final String? result = await grabFirstNonBlackCoverFrame(
        outputPath: outputPath,
        candidateSeconds: coverFrameCandidateSeconds(10),
        diagnosticOnly: false,
        grab: fake.grab,
      );

      expect(result, outputPath);
      expect(File(outputPath).readAsBytesSync(), firstBlack);
      expect(fake.calls, <double>[10, 30], reason: '30s 越界后不再试 90 / 240');
      expect(leftovers(), isEmpty);
    });

    test('首个候选就拿不到帧 → null，已有封面原样保留', () async {
      final Uint8List existing = _normalJpeg();
      File(outputPath).writeAsBytesSync(existing);
      final fake = fakeGrabber(<double, Uint8List>{});

      final String? result = await grabFirstNonBlackCoverFrame(
        outputPath: outputPath,
        candidateSeconds: coverFrameCandidateSeconds(10),
        diagnosticOnly: false,
        grab: fake.grab,
      );

      expect(result, isNull);
      expect(fake.calls, <double>[10]);
      expect(File(outputPath).readAsBytesSync(), existing);
      expect(leftovers(), isEmpty);
    });

    test('中间黑帧不落到目标路径（替身期间目标始终是旧封面）', () async {
      final Uint8List existing = _logoOnBlackJpeg();
      File(outputPath).writeAsBytesSync(existing);
      final Uint8List good = _normalJpeg();
      final List<Uint8List> seenAtDest = <Uint8List>[];
      Future<String?> grab({
        required String outputPath,
        required double atSeconds,
        required bool diagnosticOnly,
      }) async {
        seenAtDest.add(
          File(p.join(dir.path, 'video_book.jpg')).readAsBytesSync(),
        );
        expect(
          outputPath,
          isNot(p.join(dir.path, 'video_book.jpg')),
          reason: '候选必须抽到 staged 路径，不能直写目标',
        );
        File(
          outputPath,
        ).writeAsBytesSync(atSeconds == 10 ? _solidJpeg(0, 0, 0) : good);
        return outputPath;
      }

      final String? result = await grabFirstNonBlackCoverFrame(
        outputPath: outputPath,
        candidateSeconds: coverFrameCandidateSeconds(10),
        diagnosticOnly: false,
        grab: grab,
      );

      expect(result, outputPath);
      expect(seenAtDest, <Uint8List>[existing, existing]);
      expect(File(outputPath).readAsBytesSync(), good);
    });
  });
}
