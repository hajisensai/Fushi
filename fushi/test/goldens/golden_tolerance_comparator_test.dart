import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flutter_test_config.dart';

/// BUG-1585 守卫：容差 golden 比较器**必须只吸收跨平台光栅噪声，不能吸收真实回归**。
///
/// 装容差是有代价的决定——阈值一旦定宽，真实 UI 回归就会被静默放行，而 golden 的
/// 全部价值就在于抓这个。所以这里把阈值**双向**钉死：
///   * 略低于阈值的差异必须通过（否则 macOS/Linux 开发机继续恒红，等于没修）；
///   * 略高于阈值的差异必须失败（否则容差变成了"永远通过"）。
/// 两条一起，阈值就不能被随手调大而无人察觉。
void main() {
  const int kSide = 100; // 100x100 = 10000 像素，1 像素 = 0.01%。

  /// 画一张 [kSide]² 的白底图，前 [blackPixels] 个像素涂黑，返回 PNG 字节。
  /// 逐像素画 1x1 矩形，保证差异像素数**精确可数**，不受抗锯齿影响。
  Future<Uint8List> png(int blackPixels) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kSide.toDouble(), kSide.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final Paint black = Paint()..color = const Color(0xFF000000);
    for (int i = 0; i < blackPixels; i++) {
      final double x = (i % kSide).toDouble();
      final double y = (i ~/ kSide).toDouble();
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), black);
    }
    final ui.Image image = await recorder.endRecording().toImage(kSide, kSide);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  testWidgets('阈值是实测跨平台噪声的数倍余量，且写死在单一常量里', (WidgetTester tester) async {
    // 实测 macOS vs Windows 基准的差异分布是 0.0000 ~ 0.0010（33 条全量实跑）。
    // 阈值必须明显高于噪声上限，又必须远低于任何真实布局回归的量级。
    expect(kGoldenMaxDiffRatio, 0.005);
    expect(kGoldenMaxDiffRatio, greaterThan(0.0010 * 2),
        reason: '低于实测噪声上限的 2 倍就等于没修，非参考平台会继续恒红');
    expect(kGoldenMaxDiffRatio, lessThan(0.01), reason: '再宽就开始吃真实回归了');
  });

  testWidgets('低于阈值的光栅噪声：通过', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Directory dir =
          Directory.systemTemp.createTempSync('golden_tolerance_pass');
      addTearDown(() => dir.deleteSync(recursive: true));

      final Uint8List base = await png(0);
      File('${dir.path}/base.png').writeAsBytesSync(base);

      // 40 / 10000 = 0.0040 < 0.005。
      final Uint8List noisy = await png(40);
      final ToleranceGoldenComparator comparator =
          ToleranceGoldenComparator(Uri.directory(dir.path));

      expect(await comparator.compare(noisy, Uri.parse('base.png')), isTrue);
    });
  });

  testWidgets('高于阈值的真实差异：仍然失败', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final Directory dir =
          Directory.systemTemp.createTempSync('golden_tolerance_fail');
      addTearDown(() => dir.deleteSync(recursive: true));

      final Uint8List base = await png(0);
      File('${dir.path}/base.png').writeAsBytesSync(base);

      // 100 / 10000 = 0.0100 > 0.005。真实回归（改内边距/换配色）比这大得多。
      final Uint8List regressed = await png(100);
      final ToleranceGoldenComparator comparator =
          ToleranceGoldenComparator(Uri.directory(dir.path));

      await expectLater(
        () => comparator.compare(regressed, Uri.parse('base.png')),
        throwsA(isA<FlutterError>()),
      );
    });
  });
}
