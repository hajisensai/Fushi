// 反馈 #_uvuiSpjZ7（iOS）：反馈自动截图里阅读器查词卡的 WebView 整块空白。
//
// 根因：反馈截图只走 Flutter 根边界 `RenderRepaintBoundary.toImage`，平台视图
// （WKWebView / Android Hybrid Composition 的 WebView）不在 Flutter 场景里。修复后
// iOS / Android 先截原生窗口（悬浮球通道 `captureScreen`），原生不可用 / 失败时记
// 日志并回退到 toImage。这里钉住 Dart 侧的分流、回退、藏浮层与缩放契约。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

Future<Uint8List> _png(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  try {
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<(int, int)> _size(Uint8List png) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(png);
  final ui.ImageDescriptor d = await ui.ImageDescriptor.encoded(buffer);
  final (int, int) size = (d.width, d.height);
  d.dispose();
  buffer.dispose();
  return size;
}

bool _logged(String source) => ErrorLogService.instance.entries.any(
  (ErrorLogEntry e) => e.source == source,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uint8List boundaryShot = Uint8List.fromList(<int>[0xB0, 0x0B]);
  late int boundaryCalls;
  late int frameWaits;
  late List<bool> activeDuringNative;

  Future<Uint8List?> boundary() async {
    boundaryCalls++;
    return boundaryShot;
  }

  Future<void> awaitFrame() async {
    frameWaits++;
  }

  setUp(() async {
    boundaryCalls = 0;
    frameWaits = 0;
    activeDuringNative = <bool>[];
    await ErrorLogService.instance.clear();
  });

  Future<Uint8List?> run(Future<Uint8List?> Function() native) =>
      captureFeedbackScreenshotWith(
        nativeWindow: () {
          activeDuringNative.add(feedbackWindowCaptureActive.value);
          return native();
        },
        boundary: boundary,
        awaitFrame: awaitFrame,
      );

  test('原生窗口快照成功：用它、不碰 toImage；截图期间浮层被藏、结束后放回', () async {
    final Uint8List shot = await _png(40, 80);
    final Uint8List? out = await run(() async => shot);
    expect(out, same(shot));
    expect(boundaryCalls, 0);
    expect(frameWaits, 1, reason: '藏球那一帧画完再截');
    expect(activeDuringNative, <bool>[true]);
    expect(feedbackWindowCaptureActive.value, isFalse);
  });

  test('原生报错（PlatformException）：记错误日志并回退 toImage', () async {
    final Uint8List? out = await run(
      () async => throw PlatformException(code: 'CAPTURE_FAILED'),
    );
    expect(out, same(boundaryShot));
    expect(boundaryCalls, 1);
    expect(_logged('feedback.screenshot.native'), isTrue);
    expect(feedbackWindowCaptureActive.value, isFalse);
  });

  test('原生没注册（MissingPluginException）：记诊断并回退 toImage', () async {
    final Uint8List? out = await run(
      () async => throw MissingPluginException('captureScreen'),
    );
    expect(out, same(boundaryShot));
    expect(
      ErrorLogService.instance.getFullLog(),
      contains('native window capture not registered'),
    );
    expect(feedbackWindowCaptureActive.value, isFalse);
  });

  test('本设备不支持（Android API 24/25 回 null）：回退 toImage', () async {
    final Uint8List? out = await run(() async => null);
    expect(out, same(boundaryShot));
    expect(
      ErrorLogService.instance.getFullLog(),
      contains('native window capture unsupported'),
    );
  });

  test('原生产物解不开：记错误日志并回退 toImage，不当成截到了图', () async {
    final Uint8List? out = await run(
      () async => Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    expect(out, same(boundaryShot));
    expect(_logged('feedback.screenshot.native_decode'), isTrue);
  });

  test('平台没有原生快照（桌面）：直接走 toImage，不藏浮层不等帧', () async {
    final Uint8List? out = await captureFeedbackScreenshotWith(
      nativeWindow: null,
      boundary: boundary,
      awaitFrame: awaitFrame,
    );
    expect(out, same(boundaryShot));
    expect(frameWaits, 0);
  });

  test('原生物理像素大图缩到长边上限内（iOS 3x 全屏 PNG）', () async {
    final Uint8List big = await _png(3200, 100);
    final Uint8List? fitted = await fitFeedbackScreenshotPng(big);
    expect(fitted, isNotNull);
    expect(await _size(fitted!), (1600, 50));
    final Uint8List small = await _png(100, 50);
    expect(await fitFeedbackScreenshotPng(small), same(small));
  });

  test('接线：iOS/Android 走原生、悬浮球截图期间藏球、Android 实现了 captureScreen', () {
    final String diag = File(
      'lib/src/feedback/feedback_diagnostics.dart',
    ).readAsStringSync();
    expect(
      diag,
      contains(
        'bool get _nativeWindowCaptureSupported => '
        'Platform.isIOS || Platform.isAndroid;',
      ),
    );
    expect(
      RegExp(
        r"invokeMethod<Uint8List>\(\s*'captureScreen',\s*"
        r'nativeWindowCaptureArguments\(\),?\s*\)',
      ).hasMatch(diag),
      isTrue,
      reason: '反馈截图要把长边上限传给原生，原生侧缩好再编码',
    );
    final String host = File(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    ).readAsStringSync();
    expect(host, contains('feedbackWindowCaptureActive.value ||'));
    expect(host, contains('feedbackWindowCaptureActive.addListener('));
    final String android = File(
      'android/app/src/main/java/app/fushi/reader/FloatingBallChannel.java',
    ).readAsStringSync();
    expect(android, contains('case "captureScreen":'));
    expect(
      android,
      contains(
        'AppWindowSnapshot.capture(context, call.argument("maxSide"), result)',
      ),
    );
    final String ios = File(
      'ios/Runner/FushiFloatingBall.swift',
    ).readAsStringSync();
    expect(ios, contains('case "captureScreen":'));
    expect(
      ios,
      contains('drawHierarchy(in: bounds, afterScreenUpdates: true)'),
    );
  });

  test('通道参数：把长边上限交给原生，原生合成时就缩好', () {
    expect(nativeWindowCaptureArguments(), <String, Object>{
      'maxSide': kFeedbackScreenshotMaxSide,
    });
    expect(nativeWindowCaptureArguments(maxSide: 800), <String, Object>{
      'maxSide': 800,
    });
  });

  group('AppWindowSnapshot.java（PR #2095 审查）', () {
    final String snapshot = File(
      'android/app/src/main/java/app/fushi/reader/AppWindowSnapshot.java',
    ).readAsStringSync();

    test('每一处位图分配都接住 OutOfMemoryError，回 CAPTURE_FAILED 而不是崩', () {
      // 通道外层只 catch RuntimeException；OOM 是 Error，漏接 = 低端机点「反馈」闪退。
      expect(
        RegExp(r'Bitmap\.createBitmap\(').allMatches(snapshot).length,
        3,
        reason: '新增分配点要同步补 OOM 处理并更新这里',
      );
      expect(
        RegExp(
          r'session = new Session\(window, decor, maxSide, result\);\s*'
          r'\}\s*catch \(OutOfMemoryError e\)',
        ).hasMatch(snapshot),
        isTrue,
        reason: '整窗位图在 Session 构造里分配',
      );
      expect(
        RegExp(
          r'bitmap = Bitmap\.createBitmap\([^;]*\);\s*'
          r'\}\s*catch \(OutOfMemoryError e\)',
        ).hasMatch(snapshot),
        isTrue,
        reason: 'requestSurface 里每个 SurfaceView 的位图',
      );
      expect(
        snapshot,
        contains('catch (RuntimeException | OutOfMemoryError e)'),
        reason: '合成输出图',
      );
    });

    test('先让窗口真正重画一次再 PixelCopy（HC 下 FlutterImageView 才进缓冲区）', () {
      expect(
        snapshot,
        contains('getViewTreeObserver().addOnDrawListener(this)'),
      );
      expect(snapshot, contains('decor.invalidate();'));
      expect(
        snapshot,
        contains('new RedrawThenCapture(decor, result, () -> startSession('),
      );
      expect(
        RegExp(r'startSession\(').allMatches(snapshot).length,
        2,
        reason: '只有重画回调一个调用点（另一处是定义）',
      );
      expect(
        snapshot,
        contains('public void onViewDetachedFromWindow'),
        reason: '重画前窗口被拆也要回调 result，不能让 Dart 永远等',
      );
    });

    test('合成时按 maxSide 缩放，不传全分辨率 PNG 过通道', () {
      expect(snapshot, contains('scaledSize(width, height, maxSide)'));
      expect(snapshot, contains('canvas.scale('));
    });
  });
}
