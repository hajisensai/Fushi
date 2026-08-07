import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 防回归守卫（TODO-886）：Android 12+ 系统 splash 前景必须用专用 splash 图标
/// `ic_splash_minimal_foreground`，且其内容包围盒宽占比要明显窄于自适应图标
/// 安全区（0.667），否则 wordmark 会被 splash 圆形遮罩左右裁切。
///
/// 这些是无法用 widget 测试覆盖的「Android 资源引用 / PNG 几何」契约，用
/// 文件级 + 图像解码扫描兜底。
void main() {
  String read(String relative) {
    // 测试在 hibiki/ 下运行；相对路径即相对该目录。
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync();
  }

  const List<String> densities = <String>[
    'mdpi',
    'hdpi',
    'xhdpi',
    'xxhdpi',
    'xxxhdpi',
  ];

  String splashPng(String density) =>
      'android/app/src/main/res/drawable-$density/'
      'ic_splash_minimal_foreground.png';

  test('v31 / night-v31 splash 前景引用专用 ic_splash_minimal_foreground', () {
    for (final String rel in <String>[
      'android/app/src/main/res/values-v31/styles.xml',
      'android/app/src/main/res/values-night-v31/styles.xml',
    ]) {
      final String styles = read(rel);
      expect(
        styles.contains('android:windowSplashScreenAnimatedIcon') &&
            styles.contains('@drawable/ic_splash_minimal_foreground'),
        isTrue,
        reason: '$rel 的 splash 前景应指向专用 ic_splash_minimal_foreground',
      );
      // 不能再指向启动器图标前景（其 wordmark 太宽会被圆遮罩裁切）。
      expect(
        styles.contains('@drawable/ic_launcher_minimal_foreground'),
        isFalse,
        reason: '$rel 不应再用 ic_launcher_minimal_foreground 作 splash 前景'
            '（内容过宽，会被圆遮罩裁切——即 TODO-886 的剪切症状）',
      );
    }
  });

  test('5 个密度目录都存在 ic_splash_minimal_foreground.png', () {
    for (final String d in densities) {
      final File f = File(splashPng(d));
      expect(f.existsSync(), isTrue, reason: '缺失专用 splash 前景: ${splashPng(d)}');
      expect(f.lengthSync() > 0, isTrue, reason: '${splashPng(d)} 不应为空');
    }
  });

  test('每张 splash 前景内容包围盒宽占比 ≤0.60（消除裁切回归）', () {
    for (final String d in densities) {
      final File f = File(splashPng(d));
      final img.Image? decoded = img.decodePng(f.readAsBytesSync());
      expect(decoded, isNotNull, reason: '${splashPng(d)} 无法解码为 PNG');
      final img.Image im = decoded!;
      final int w = im.width;
      final int h = im.height;

      // 扫描非透明像素的水平包围盒。
      int minX = w;
      int maxX = -1;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final num a = im.getPixel(x, y).a;
          if (a > 0) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
          }
        }
      }
      expect(maxX >= minX, isTrue, reason: '${splashPng(d)} 内容为空（全透明）');
      final double widthRatio = (maxX - minX + 1) / w;
      expect(
        widthRatio <= 0.60,
        isTrue,
        reason: '${splashPng(d)} 内容宽占比 $widthRatio 超过 0.60，'
            '会被 Android 12+ splash 圆形遮罩裁切',
      );
    }
  });
}
