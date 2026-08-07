import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1167 / BUG-552 守卫：安卓「导出片段视频」竖排有声书 ANR/OOM 回归的根因修复。
///
/// 三处叠加根因（origin/develop 2a5c528f5）：
/// 1. `_synthDynamicClipVideo` 先把全部 N 帧 1080×1920 PNG 收进 `pngs` 列表，再在 **UI
///    isolate** 同步无 await 逐帧 `encodeClipTextFrameAsJpg`（2MP 解码 + JPEG 编码）→
///    冻死主线程 → 安卓 ANR 杀进程；静态回退同病。
/// 2. 单 headless WebView 循环 `takeScreenshot()`，每帧 8.3MB native 位图 + N 份 PNG 全
///    驻留 → native OOM；且 `takeScreenshot()` 无超时（load 有 8s 超时，截图没）。
///
/// 修复：JPEG 编码卸到后台 isolate（`encodeClipTextFrameAsJpgAsync` 经 `Isolate.run`）；
/// 渲染层从「返回 `List<Uint8List?>`」改逐帧回调（`AudiobookClipFrameSink`），调用方渲一帧
/// →编码→落盘母帧→释放，内存里只驻留一帧；`takeScreenshot()` 加 `.timeout(...)`。
///
/// 本文件是源码扫描守卫（docs/BUGS.md 第②步「最强可落地层」）：ANR（UI isolate 冻结）与
/// native OOM 无法在 widget test 里可靠复现，故守结构性不变量——防有人回退到同步编码 /
/// 全帧驻留 / 无超时截图。
String _read(String relative) {
  final File f = File(relative);
  expect(f.existsSync(), isTrue,
      reason: 'run tests from fushi/ package root: $relative');
  return f.readAsStringSync().replaceAll('\r\n', '\n');
}

void main() {
  const String exportPath =
      'lib/src/media/audiobook/audiobook_clip_export.dart';
  const String webviewPath =
      'lib/src/media/audiobook/audiobook_clip_webview_render.dart';
  const String textRenderPath =
      'lib/src/media/audiobook/audiobook_clip_text_render.dart';
  const String audiobookPartPath =
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart';

  group('(a) JPEG 编码卸到后台 isolate（不在 UI isolate 同步跑 2MP 解码/编码）', () {
    test('encodeClipTextFrameAsJpgAsync 存在且经 Isolate.run 卸载', () {
      final String code = _read(exportPath);
      expect(code.contains('Future<Uint8List?> encodeClipTextFrameAsJpgAsync('),
          isTrue,
          reason: '必须提供后台 isolate 版编码函数');
      final RegExp isolateWrap = RegExp(
        r'Isolate\.run<Uint8List\?>\(\s*\(\)\s*=>\s*encodeClipTextFrameAsJpg\(',
      );
      expect(isolateWrap.hasMatch(code), isTrue,
          reason: '异步封装必须经 Isolate.run 调同步 encodeClipTextFrameAsJpg，'
              '否则 2MP 解码/编码仍跑在 UI isolate → 安卓 ANR');
    });

    test('导出管线不再同步调 encodeClipTextFrameAsJpg（只走 Async 版）', () {
      final String code = _read(audiobookPartPath);
      final RegExp syncCall = RegExp(r'encodeClipTextFrameAsJpg\(');
      expect(syncCall.allMatches(code).length, 0,
          reason: 'audiobook.part.dart 内不得同步调 encodeClipTextFrameAsJpg('
              '（UI isolate 冻结 → ANR），一律走 encodeClipTextFrameAsJpgAsync');
      final RegExp asyncCall = RegExp(r'encodeClipTextFrameAsJpgAsync\(');
      expect(asyncCall.allMatches(code).length, greaterThanOrEqualTo(2),
          reason: '动态逐帧 + 静态回退两条路径都应经后台 isolate 编码');
    });
  });

  group('(b) takeScreenshot() 带超时（绝不无限卡死整条导出管线）', () {
    test('每个 takeScreenshot() 调用点都 .timeout(...) 守护', () {
      final String code = _read(webviewPath);
      final int calls = RegExp(r'takeScreenshot\(\)').allMatches(code).length;
      final int guarded =
          RegExp(r'takeScreenshot\(\)\s*\.timeout\(').allMatches(code).length;
      expect(calls, greaterThanOrEqualTo(1),
          reason: '截图渲染路径应存在 takeScreenshot() 调用');
      expect(guarded, calls,
          reason: '每个 takeScreenshot() 都必须 .timeout(...)，'
              '否则单帧截图卡死会永久挂住导出管线');
      expect(code.contains('_kClipScreenshotTimeout'), isTrue,
          reason: '截图超时应由具名常量定义');
      expect(code.contains('TimeoutException'), isTrue,
          reason: '超时应捕获 TimeoutException 记日志后回退，不吞成静默');
    });
  });

  group('(c) 流式不全驻留（不再把 N 帧 PNG/JPEG 同时收进列表）', () {
    test('渲染层改逐帧回调 AudiobookClipFrameSink（不再返回 List<Uint8List?>）', () {
      final String textRender = _read(textRenderPath);
      final String webview = _read(webviewPath);
      expect(textRender.contains('typedef AudiobookClipFrameSink'), isTrue,
          reason: '定义逐帧回调类型');
      expect(
          textRender
              .contains('Future<List<Uint8List?>> renderAudiobookClipFrames('),
          isFalse,
          reason: 'renderAudiobookClipFrames 必须改逐帧回调，不再攒 List 返回');
      expect(
          webview.contains(
              'Future<List<Uint8List?>> renderAudiobookClipFramesViaWebView('),
          isFalse,
          reason: 'renderAudiobookClipFramesViaWebView 必须改逐帧回调');
      expect(textRender.contains('required AudiobookClipFrameSink onFrame'),
          isTrue);
      expect(
          webview.contains('required AudiobookClipFrameSink onFrame'), isTrue);
    });

    test('_synthDynamicClipVideo 逐帧落盘母帧，不再攒满 pngs/jpgByIndex', () {
      final String code = _read(audiobookPartPath);
      expect(code.contains('final List<Uint8List?> pngs'), isFalse,
          reason: '不得把全部 N 帧 PNG 同时驻留（native OOM 根因）');
      expect(code.contains('final Map<int, Uint8List> jpgByIndex'), isFalse,
          reason: '不得把全部帧 JPEG 同时驻留内存');
      expect(code.contains('encodeClipTextFrameAsJpgAsync(png)'), isTrue,
          reason: 'onFrame 里逐帧后台编码');
      expect(code.contains('masterJpgPathByIndex'), isTrue,
          reason: '母帧按 highlightCueIndex 落盘落路径映射');
      expect(code.contains('master.copy('), isTrue,
          reason: '帧计划展开时从母帧文件复制成 frame_%04d.jpg（流式，不重驻留内存）');
    });
  });
}
