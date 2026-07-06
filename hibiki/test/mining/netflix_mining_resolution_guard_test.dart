import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// TODO-1145 分辨率守卫：网飞（浏览器扩展）制卡默认分辨率拉高，且未开启压缩时保满分辨率。
///
/// 两个支配点必须同时守：
/// 1. `offscreen.js`（两份镜像：随 app 打包的 assets/ 与真源 tools/）录制的 webm 捕获分辨率
///    是整条链路的**支配性限制器**——下游 GIF 转码/单帧再高也无法超采源。用户决策：
///    上限对齐 app 内视频制卡——app 内本地源典型 1080p，静帧路径
///    （extractVideoFrameViaFfmpeg 不缩放 + downsampleCardScreenshot 高保真长边 2000）
///    对 1080p 源原样透传 1920。故捕获须 1920×1080（不再 1280×720），并把
///    `videoBitsPerSecond` 按面积比例（×2.25）提到 5.625Mbps 匹配 1080p。
/// 2. GIF 转码档位 [MiningMediaCompression]：压缩档 gifWidth==480、高保真档（关闭压缩）
///    gifWidth==720。该档位与 app 内视频制卡共用同一 [MiningMediaCompression]，
///    GIF 输出两条链路天然一致（对齐后无需再动）。
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

        test('捕获分辨率对齐 app 内视频制卡 1920x1080（不再 1280x720）', () {
          final String src = mirror.readAsStringSync();
          expect(src, contains('maxWidth: 1920, maxHeight: 1080'),
              reason: '${mirror.path} 捕获分辨率未对齐 app 内视频制卡 1920x1080');
          expect(src.contains('maxWidth: 1280, maxHeight: 720'), isFalse,
              reason: '${mirror.path} 仍残留旧的 1280x720 支配性限制器');
          expect(src.contains('maxWidth: 640, maxHeight: 360'), isFalse,
              reason: '${mirror.path} 仍残留更旧的 640x360 支配性限制器');
        });

        test('videoBitsPerSecond 按面积比例提到 5.625Mbps 匹配 1080p（不再 2.5M）', () {
          final String src = mirror.readAsStringSync();
          expect(src, contains('videoBitsPerSecond: 5625000'),
              reason: '${mirror.path} bitrate 未随分辨率按面积比例提升');
          expect(src.contains('videoBitsPerSecond: 2500000'), isFalse,
              reason: '${mirror.path} 仍残留旧的 2.5Mbps bitrate');
          expect(src.contains('videoBitsPerSecond: 800000'), isFalse,
              reason: '${mirror.path} 仍残留更旧的 800k bitrate');
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

    test('GIF 高保真档 gifWidth==720（与 app 内视频制卡共用档位，天然对齐）', () {
      expect(MiningMediaCompression.highFidelity.gifWidth, 720);
    });

    test('静帧路径对齐：高保真截图长边 2000 >= 1080p 捕获长边 1920（原样透传）', () {
      // 捕获 1920×1080 的单帧经 downsampleCardScreenshot 高保真档（长边 2000）
      // 不会被二次降采样——这正是「网飞上限 = app 内视频制卡分辨率」的静帧一半。
      expect(MiningMediaCompression.highFidelity.screenshotMaxLongEdge,
          greaterThanOrEqualTo(1920));
    });
  });
}
