import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';

/// BUG-007 设备验证（真 InAppWebView）：cue 推进高亮从图片**前**一句推进到图片**后**
/// 一句时（中间隔着 svg），`__hoshiHighlight` 的锚点间 DOM 检测必须真的触发
/// `onImageDetected`。
///
/// 这正是离散翻页跳过整页插图的等价场景：s1 和 s2 是相邻的两个 cue 锚点，中间的 svg
/// 没有自己的 cue（整页插图无音频），播放从 s1 推进到 s2 时把它「跨过」。旧的
/// IntersectionObserver 视口检测在此布局下漏报；新的锚点间检测能确定性抓到。
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/image_pause_detection_test.dart -d <emulator>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String html = '''
<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
  <p><span data-hoshi-sid="s1">画像の前の文。</span></p>
  <svg id="pic" xmlns="http://www.w3.org/2000/svg" width="120" height="90">
    <rect width="120" height="90" fill="#ccc"></rect>
  </svg>
  <p><span data-hoshi-sid="s2">画像の後の文。</span></p>
</body></html>
''';

  testWidgets(
      'cue-advance across an image fires onImageDetected in a real WebView',
      (WidgetTester tester) async {
    bool imageDetected = false;
    final Completer<void> driven = Completer<void>();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html),
          onWebViewCreated: (InAppWebViewController controller) {
            controller.addJavaScriptHandler(
              handlerName: 'onImageDetected',
              callback: (List<dynamic> _) {
                imageDetected = true;
                return null;
              },
            );
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            // 注入真实 bridge（含 __hoshiHighlight）。
            await AudiobookBridge.inject(controller);
            // 先高亮图片前一句（建立 __hoshiPrevHighlight 锚点）。
            await controller.evaluateJavascript(
              source: "window.__hoshiHighlight('[data-hoshi-sid=s1]', false);",
            );
            // 再推进到图片后一句 —— 中间隔着 svg，应触发检测。
            await controller.evaluateJavascript(
              source: "window.__hoshiHighlight('[data-hoshi-sid=s2]', false);",
            );
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    // 等 WebView 加载 + onLoadStop 把两次推进驱动完。
    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(driven.isCompleted, isTrue, reason: 'WebView 未在 15s 内完成加载/驱动');
    await tester.pump(const Duration(seconds: 1));

    expect(imageDetected, isTrue,
        reason: 'cue 推进从 s1 跨过 svg 到 s2 必须触发 onImageDetected（旧 IO 视口'
            '检测在离散翻页下漏报，新锚点间 DOM 检测应确定性命中）');
  });

  testWidgets(
      'selector cue: crossing an image reveals the IMAGE (not next text) when reveal=true',
      (WidgetTester tester) async {
    final Completer<void> driven = Completer<void>();
    String? revealTarget;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html),
          onWebViewCreated: (InAppWebViewController controller) {
            controller.addJavaScriptHandler(
              handlerName: 'reportReveal',
              callback: (List<dynamic> args) {
                revealTarget = args.isNotEmpty ? args.first as String? : null;
                return null;
              },
            );
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            await controller.evaluateJavascript(
                source: 'window.hoshiReader={scrollToTarget:function(t){'
                    "window.flutter_inappwebview.callHandler('reportReveal',"
                    '(t&&(t.id||t.tagName))||null);}};');
            await AudiobookBridge.inject(controller);
            await controller.evaluateJavascript(
                source:
                    "window.__hoshiHighlight('[data-hoshi-sid=s1]', true);");
            await controller.evaluateJavascript(
                source:
                    "window.__hoshiHighlight('[data-hoshi-sid=s2]', true);");
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(revealTarget, 'pic',
        reason: 'cue 推进跨过插图、reveal=true 时应把视口滚到插图(id=pic)而非 s2 文字');
  });
}
