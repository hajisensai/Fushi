// BUG-3296 真机取证（Windows 桌面 + 真 media_kit_video 插件 + ANGLE 共享纹理）：
// 「画质增强」开 / 关 × 硬件解码 默认 / 复制 四组，抓 Flutter 合成后的真实像素，
// 量画面是否把 H.264 1080p 的编码填充行（coded 1920x1088）一起压进 16:9 画面。
//
// 片源由 `-DartDefine FUSHI_PROBE_CROP_VIDEO=<绝对路径>` 传入：1920x1080 x264 yuv420p，
// 顶部 8 行绿、底部 8 行红、每 120 行一条 2 行白线（`.codex-test/hwdec/gen.py` 生成）。
// 正确裁剪时：顶绿 = 底红 = 8 行，白线中心在 120.5 / 240.5 / … / 960.5；
// 若采样了未裁剪的 1088 解码面：底红 ≈ 16 行（含 8 行复制出来的填充），白线按 1080/1088 上移。
//
// 播放器装配与生产一致：VideoController 的 hwdec 走 [resolvePlatformHwdec]，属性走
// [applyMpvConfigToPlayer]，着色器走 [applyShadersToPlayer]（「无」档 = 空列表）。
//
// 运行（fushi/ 下）：
//   .\tool\run_windows_itest.ps1 integration_test/video_hwdec_crop_probe_itest.dart `
//     -DartDefine FUSHI_PROBE_CROP_VIDEO=D:/path/crop1088.mp4
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';

const String _kVideo = String.fromEnvironment('FUSHI_PROBE_CROP_VIDEO');

/// 一组 A/B 组合。
class _Combo {
  const _Combo(this.label, {required this.highQuality, required this.hwdec});
  final String label;
  final bool highQuality;
  final String hwdec;
}

/// 从中线一列像素量出的几何特征。
class _Bands {
  const _Bands(this.topGreen, this.bottomRed, this.whiteLines);
  final int topGreen;
  final int bottomRed;
  final List<double> whiteLines;

  @override
  String toString() =>
      'topGreen=$topGreen bottomRed=$bottomRed whiteLines=$whiteLines';
}

_Bands _measure(ByteData rgba, int width, int height) {
  final int x = width ~/ 2;
  List<int> px(int y) {
    final int o = (y * width + x) * 4;
    return <int>[rgba.getUint8(o), rgba.getUint8(o + 1), rgba.getUint8(o + 2)];
  }

  bool red(List<int> c) => c[0] > 150 && c[1] < 90 && c[2] < 90;
  bool green(List<int> c) => c[1] > 90 && c[0] < 60 && c[2] < 60;
  int run(bool Function(List<int>) pred, Iterable<int> ys) {
    int n = 0;
    for (final int y in ys) {
      if (!pred(px(y))) break;
      n++;
    }
    return n;
  }

  final List<double> lines = <double>[];
  List<int> cur = <int>[];
  for (int y = 0; y < height; y++) {
    final List<int> c = px(y);
    if (c.reduce((int a, int b) => a < b ? a : b) <= 180) continue;
    if (cur.isNotEmpty && y != cur.last + 1) {
      lines.add(cur.reduce((int a, int b) => a + b) / cur.length);
      cur = <int>[];
    }
    cur.add(y);
  }
  if (cur.isNotEmpty) {
    lines.add(cur.reduce((int a, int b) => a + b) / cur.length);
  }
  return _Bands(
    run(green, List<int>.generate(height, (int i) => i)),
    run(red, List<int>.generate(height, (int i) => height - 1 - i)),
    lines,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const List<_Combo> combos = <_Combo>[
    _Combo('enhance-off_hwdec-default', highQuality: false, hwdec: 'auto-safe'),
    _Combo('enhance-off_hwdec-copy', highQuality: false, hwdec: 'auto-copy'),
    _Combo('enhance-low_hwdec-default', highQuality: true, hwdec: 'auto-safe'),
    _Combo('enhance-low_hwdec-copy', highQuality: true, hwdec: 'auto-copy'),
  ];

  for (final _Combo combo in combos) {
    testWidgets('BUG-3296 crop probe: ${combo.label}', (
      WidgetTester tester,
    ) async {
      expect(_kVideo, isNotEmpty, reason: '缺 FUSHI_PROBE_CROP_VIDEO');
      MediaKit.ensureInitialized();
      late final Player player;
      late final VideoController controller;
      final GlobalKey boundary = GlobalKey();
      // media_kit 的原生初始化全是真异步：Player / VideoController 必须在 runAsync
      // 里建，否则它们的 future 落在 fake-async zone 里永不完成（会挂到超时）。
      await tester.runAsync(() async {
        player = Player();
        controller = VideoController(
          player,
          configuration: VideoControllerConfiguration(
            hwdec: resolvePlatformHwdec(combo.hwdec),
          ),
        );
        debugPrint('[crop-probe] ${combo.label} controller created');
      });
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 960,
                  height: 540,
                  child: Video(
                    controller: controller,
                    fit: BoxFit.fill,
                    controls: NoVideoControls,
                    wakelock: false,
                  ),
                ),
              ),
            ),
          ),
        );
        // 先挂上 Video（纹理 / 平台回调要在真实帧循环里推进），再开文件、下发配置；
        // 全程边 pump 边等，不在帧循环外死等 media_kit 的 future。
        Future<void> settle(bool Function() done, String what) async {
          for (int i = 0; i < 200 && !done(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump();
          }
          debugPrint('[crop-probe] ${combo.label} $what: ${done()}');
        }

        bool opened = false;
        bool configured = false;
        await tester.runAsync(() async {
          unawaited(
            player.open(Media(_kVideo), play: false).then((_) => opened = true),
          );
        });
        await settle(
          () => opened || player.state.duration > Duration.zero,
          'file loaded',
        );
        await tester.runAsync(() async {
          final VideoMpvConfig config = VideoMpvConfig.defaults.copyWith(
            highQuality: combo.highQuality,
            hwdec: combo.hwdec,
          );
          unawaited(
            applyMpvConfigToPlayer(player, config)
                .then((_) => applyShadersToPlayer(player, const <String>[]))
                .then((_) => configured = true),
          );
        });
        await settle(() => configured, 'configured');
        for (int i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        final dynamic native = player.platform;
        final String hwdecCurrent =
            await tester.runAsync(
              () async =>
                  (await native.getProperty('hwdec-current')).toString(),
            ) ??
            '?';
        final String scaleProps =
            await tester.runAsync(() async {
              final List<String> parts = <String>[];
              for (final String k in <String>[
                'scale',
                'cscale',
                'correct-downscaling',
                'linear-downscaling',
                'sigmoid-upscaling',
              ]) {
                parts.add('$k=${await native.getProperty(k)}');
              }
              return parts.join(' ');
            }) ??
            '?';
        final String outParams =
            await tester.runAsync(
              () async =>
                  '${await native.getProperty('video-out-params/dw')}x'
                  '${await native.getProperty('video-out-params/dh')}',
            ) ??
            '?';
        final RenderRepaintBoundary rb =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final (ByteData, int, int)? shot = await tester.runAsync(() async {
          final ui.Image image = await rb.toImage(pixelRatio: 2.0);
          final ByteData data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final ByteData png = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          const String root = String.fromEnvironment('FUSHI_TEST_ROOT');
          final String dir = root.isEmpty ? Directory.systemTemp.path : root;
          File(
            '$dir/crop-${combo.label}.png',
          ).writeAsBytesSync(png.buffer.asUint8List());
          return (data, image.width, image.height);
        });
        final _Bands bands = _measure(shot!.$1, shot.$2, shot.$3);
        debugPrint(
          '[crop-probe] ${combo.label} hwdec-current=$hwdecCurrent '
          '[$scaleProps] out=$outParams image=${shot.$2}x${shot.$3} $bands',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => player.dispose());
      }
    }, skip: !Platform.isWindows);
  }
}
