import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// TODO-1145 分辨率守卫：网飞（浏览器扩展）制卡默认分辨率拉高，且未开启压缩时保满分辨率。
///
/// 两个支配点必须同时守：
/// 1. `offscreen.js`（两份镜像：随 app 打包的 assets/ 与真源 tools/）录制的 webm 捕获分辨率
///    是整条链路的**支配性限制器**——下游 GIF 转码宽度再高也无法超采源。必须 1280×720
///    （不再 640×360），并把 `videoBitsPerSecond` 提到 ~2.5Mbps 匹配 720p。
/// 2. GIF 转码档位 [MiningMediaCompression]：压缩档 gifWidth==480、高保真档（关闭压缩）
///    gifWidth==720（≈捕获宽，不降采样 -> 诉求②满分辨率）。
///
/// 逐字节镜像同步本身由 `test/lookup/browser_extension_installer_test.dart` 的
/// 「bundled extension matches source」守卫覆盖；此处只守具体数值不被回退。
void main() {
  group('TODO-1145 Netflix 制卡分辨率守卫', () {
    // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
    final List<File> offscreenMirrors = <File>[
      File('assets/browser_extension/offscreen.js'),
      File('../tools/browser-extension/offscreen.js'),
    ];

    for (final File mirror in offscreenMirrors) {
      group(mirror.path, () {
        test('文件存在', () {
          expect(mirror.existsSync(), isTrue, reason: 'missing ${mirror.path}');
        });

        test('捕获分辨率提到 1280x720（不再 640x360）', () {
          final String src = mirror.readAsStringSync();
          expect(src, contains('maxWidth: 1280, maxHeight: 720'),
              reason: '${mirror.path} 捕获分辨率未拉高到 1280x720');
          expect(src.contains('maxWidth: 640, maxHeight: 360'), isFalse,
              reason: '${mirror.path} 仍残留旧的 640x360 支配性限制器');
        });

        test('videoBitsPerSecond 提到 ~2.5Mbps 匹配 720p（不再 800k）', () {
          final String src = mirror.readAsStringSync();
          expect(src, contains('videoBitsPerSecond: 2500000'),
              reason: '${mirror.path} bitrate 未随分辨率提升');
          expect(src.contains('videoBitsPerSecond: 800000'), isFalse,
              reason: '${mirror.path} 仍残留旧的 800k bitrate');
        });
      });
    }

    test('两份镜像逐字节一致（分辨率/bitrate 同步）', () {
      final List<int> a = offscreenMirrors[0].readAsBytesSync();
      final List<int> b = offscreenMirrors[1].readAsBytesSync();
      expect(a, b, reason: 'offscreen.js 两份镜像内容不一致');
    });

    test('GIF 压缩档 gifWidth==480（默认档也拉高）', () {
      expect(MiningMediaCompression.compressed.gifWidth, 480);
    });

    test('GIF 高保真档 gifWidth==720（关闭压缩=满捕获宽不降采样，诉求②）', () {
      expect(MiningMediaCompression.highFidelity.gifWidth, 720);
      // 未压缩档宽度须达到捕获宽（720），才叫「满分辨率」；不得低于捕获宽而降采样。
      expect(MiningMediaCompression.highFidelity.gifWidth,
          greaterThanOrEqualTo(720));
    });
  });
}
