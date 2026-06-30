import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/startup/observe_blank_detector.dart';
import 'package:hibiki/src/startup/test_environment.dart';

/// 一次离屏观察抓图的结果。
class ObserveShot {
  const ObserveShot({
    required this.name,
    required this.path,
    required this.saved,
    required this.nonBlank,
    required this.bytes,
  });

  final String name;
  final String path;
  final bool saved;
  final bool nonBlank;
  final int bytes;
}

/// 解析截图落盘目录 `<evidenceDir>/screenshots/`。
///
/// run_windows_itest.ps1 经 --dart-define 传 HIBIKI_TEST_ROOT=<evidenceDir>/isolated-root，
/// 故 evidenceDir = isolated-root 的父目录（与 reader_computer_use_flow_test 同约定）。
/// 无 HIBIKI_TEST_ROOT（裸 flutter test）时落 .codex-test/observe/<runId|local>/screenshots。
Directory observeScreenshotDir() {
  final String? root = hibikiTestRootPath();
  Directory base;
  if (root != null && root.isNotEmpty) {
    base = Directory(root);
    final String leaf = base.path.split(Platform.pathSeparator).last;
    if (leaf.toLowerCase() == 'isolated-root') {
      base = base.parent;
    }
  } else {
    final String? runId = hibikiTestRunId();
    final String runLeaf =
        (runId != null && runId.isNotEmpty) ? runId : 'local';
    base = Directory('.codex-test/observe/$runLeaf');
  }
  final Directory dir = Directory('${base.path}/screenshots');
  dir.createSync(recursive: true);
  return dir;
}

Future<ObserveShot> _save(String name, Uint8List? png, bool nonBlank) async {
  if (png == null || png.isEmpty) {
    return ObserveShot(
        name: name, path: '', saved: false, nonBlank: false, bytes: 0);
  }
  final String path = '${observeScreenshotDir().path}/$name.png';
  await File(path).writeAsBytes(png, flush: true);
  return ObserveShot(
    name: name,
    path: path,
    saved: true,
    nonBlank: nonBlank,
    bytes: png.length,
  );
}

Future<bool> _pngLooksNonBlank(Uint8List png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(png);
  try {
    final ui.FrameInfo frame = await codec.getNextFrame();
    try {
      final ByteData? rgba =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return rgba != null && rgbaLooksNonBlank(rgba.buffer.asUint8List());
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// 抓 Flutter 图层树（不含 WebView 原生纹理）为 PNG，落盘并判非空白。
/// 抓图失败（图层未就绪 / 编码异常）返回 saved=false，不抛——与 WebView 路径一致。
///
/// 直接对根 RenderView 的 OffsetLayer.toImage —— 与 OS 抓屏无关、真离屏可用、不受窗口
/// 可见性 / 遮挡影响。覆盖设置 / 弹窗 / 主页 / 词典结果 / 对话框等所有 Flutter 渲染面。
///
/// [pixelRatio] 输出像素 / 逻辑像素之比；默认 1.0（取证只需可读，不必放大）。
Future<ObserveShot> captureFlutterFrame(
  WidgetTester tester,
  String name, {
  double pixelRatio = 1.0,
}) async {
  await tester.pumpAndSettle();
  try {
    final RenderView view = tester.binding.renderViews.first;
    final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
    if (layer == null) {
      return ObserveShot(
          name: name, path: '', saved: false, nonBlank: false, bytes: 0);
    }
    final ui.Image image =
        await layer.toImage(view.paintBounds, pixelRatio: pixelRatio);
    try {
      final ByteData? rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bool nonBlank =
          rgba != null && rgbaLooksNonBlank(rgba.buffer.asUint8List());
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return _save(name, png?.buffer.asUint8List(), nonBlank);
    } finally {
      image.dispose();
    }
  } catch (_) {
    return ObserveShot(
        name: name, path: '', saved: false, nonBlank: false, bytes: 0);
  }
}

/// 阅读器 WebView 是否已创建（onWebViewCreated 注册了抓图钩子）。跨模式可靠信号：
/// 章节阅读器与歌词模式（有声书）都会触发 onWebViewCreated → 钩子非空，比等
/// `hoshi_webview` widget key 更稳（歌词模式可能是不同页 / 不同 key）。
bool readerWebViewReady() => ReaderHibikiPage.debugCaptureWebView != null;

/// 抓阅读器 EPUB 正文（WebView2，经 CDP Page.captureScreenshot，真离屏可用）为 PNG。
///
/// 走 ReaderHibikiPage.debugCaptureWebView 钩子（仅 debug/profile 注册）。钩子为空
/// （未在阅读器页 / release build）时返回 saved=false，不抛。
Future<ObserveShot> captureReaderWebView(String name) async {
  final Future<Uint8List?> Function()? hook =
      ReaderHibikiPage.debugCaptureWebView;
  if (hook == null) {
    return ObserveShot(
        name: name, path: '', saved: false, nonBlank: false, bytes: 0);
  }
  try {
    final Uint8List? png = await hook();
    final bool nonBlank =
        png != null && png.isNotEmpty && await _pngLooksNonBlank(png);
    return _save(name, png, nonBlank);
  } catch (_) {
    return ObserveShot(
        name: name, path: '', saved: false, nonBlank: false, bytes: 0);
  }
}
