import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview_ios/flutter_inappwebview_ios.dart';
import 'package:flutter_test/flutter_test.dart';

/// 反馈 P2jQzOBBag（iOS 27.2 / 分页模式 / 3.3.0 24555）：双击缩放几乎总是先弹
/// 控制层，只有快速三击才偶尔放大。
///
/// 漫画页的双击窗口在页内 JS 里按 DOM pointer 事件的时间判（第二击 pointerdown
/// 落在挂起的空白单击窗口内才取消它）。iOS 引擎默认的 eager 手势阻塞策略给平台
/// 视图装一个 delaysTouchesBegan/Ended 的延迟识别器，WKWebView 派发 DOM 触摸事件
/// 的识别器要等 Flutter 手势竞技场裁决、acceptGesture 经平台通道回到原生后才收得
/// 到触摸——第二击的 pointerdown 晚到，挂起的单击先发出、悬浮栏被切出来。
///
/// 修法：漫画 WebView 传 `preventGestureDelay: true`，pub-cache 覆盖补丁
/// （ci/patches/hosted/flutter_inappwebview_ios-1.1.2/）把它映射到
/// `UiKitViewGestureBlockingPolicy.doNotBlockGesture`（上游实现按已不存在的类名
/// `DelayingGestureRecognizer` 找识别器，是空操作）。本文件钉住：映射本身、插件真把
/// 策略交给 UiKitView、漫画页确实开了这个选项、覆盖补丁与锁定版本同号。
void main() {
  group('inAppWebViewGestureBlockingPolicy', () {
    test('preventGestureDelay=true → doNotBlockGesture', () {
      expect(
        inAppWebViewGestureBlockingPolicy(preventGestureDelay: true),
        UiKitViewGestureBlockingPolicy.doNotBlockGesture,
      );
    });

    test('未开启时保持插件默认策略（其它 WebView 行为不变）', () {
      expect(
        inAppWebViewGestureBlockingPolicy(preventGestureDelay: false),
        UiKitViewGestureBlockingPolicy.fallbackToPluginDefault,
      );
      expect(
        inAppWebViewGestureBlockingPolicy(preventGestureDelay: null),
        UiKitViewGestureBlockingPolicy.fallbackToPluginDefault,
      );
    });
  });

  testWidgets('IOSInAppWebViewWidget 把策略交给 UiKitView', (
    WidgetTester tester,
  ) async {
    late Widget withFlag;
    late Widget withoutFlag;
    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          // 只调 build 取返回的 widget，不挂载（挂载会去建原生平台视图）。
          withFlag = IOSInAppWebViewWidget(
            IOSInAppWebViewWidgetCreationParams(preventGestureDelay: true),
          ).build(context);
          withoutFlag = IOSInAppWebViewWidget(
            IOSInAppWebViewWidgetCreationParams(),
          ).build(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(withFlag, isA<UiKitView>());
    expect(
      (withFlag as UiKitView).gestureBlockingPolicy,
      UiKitViewGestureBlockingPolicy.doNotBlockGesture,
    );
    expect(
      (withoutFlag as UiKitView).gestureBlockingPolicy,
      UiKitViewGestureBlockingPolicy.fallbackToPluginDefault,
    );
  });

  test('漫画正文 WebView 开启 preventGestureDelay', () {
    final File page = File('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(page.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    final String src = page.readAsStringSync();
    expect(
      src,
      contains('const bool kMangaWebViewPreventGestureDelay = true;'),
    );
    final int webView = src.indexOf(
      "key: const ValueKey<String>('manga_webview')",
    );
    expect(webView, greaterThan(0), reason: '漫画正文 WebView 锚点没找到');
    final int settings = src.indexOf('initialSettings:', webView);
    expect(settings, greaterThan(webView));
    // 必须是这一个 InAppWebView 构造的参数（锚点与 initialSettings 之间）。
    expect(
      src.substring(webView, settings),
      contains('preventGestureDelay: kMangaWebViewPreventGestureDelay'),
    );
  });

  test('覆盖补丁与锁定版本同号（版本一漂 apply-patches 只告警跳过）', () {
    final Directory repoRoot = Directory.current.parent;
    final File overlay = File(
      '${repoRoot.path}/ci/patches/hosted/flutter_inappwebview_ios-1.1.2/'
      'lib/src/in_app_webview/in_app_webview.dart',
    );
    expect(overlay.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    expect(
      overlay.readAsStringSync(),
      contains('gestureBlockingPolicy: inAppWebViewGestureBlockingPolicy('),
    );
    final String lock = File(
      '${repoRoot.path}/pubspec.lock',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final RegExpMatch? m = RegExp(
      r'flutter_inappwebview_ios:\n(?:\s{4}.*\n)*?\s{4}version: "([^"]+)"',
    ).firstMatch(lock);
    expect(m, isNotNull);
    expect(m!.group(1), '1.1.2', reason: '锁定版本变了：把覆盖补丁移到新版本号并核对上游，否则补丁被跳过');
  });
}
