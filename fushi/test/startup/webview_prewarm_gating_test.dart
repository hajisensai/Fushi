import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/webview_prewarm.dart';

import '../helpers/source_guard.dart';

void main() {
  group('shouldPrewarmWebView', () {
    test('mobile prewarms when not low-memory', () {
      expect(
        shouldPrewarmWebView(
          isMobile: true,
          isDesktop: false,
          lowMemory: false,
        ),
        isTrue,
      );
    });

    test('mobile skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: true, isDesktop: false, lowMemory: true),
        isFalse,
      );
    });

    test('desktop prewarms (regression: was mobile-only)', () {
      expect(
        shouldPrewarmWebView(
          isMobile: false,
          isDesktop: true,
          lowMemory: false,
        ),
        isTrue,
      );
    });

    test('desktop skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: false, isDesktop: true, lowMemory: true),
        isFalse,
      );
    });

    test('neither mobile nor desktop does not prewarm', () {
      expect(
        shouldPrewarmWebView(
          isMobile: false,
          isDesktop: false,
          lowMemory: false,
        ),
        isFalse,
      );
    });
  });

  // 反馈 LQhvpnzzkz：移动端旧实现首帧前就 run() headless WebView，Android 插件在主线程
  // 同步初始化 chromium，低端机首帧画不出 → 8s「no focused window」ANR。时机门用
  // Completer 当 fake binding：首帧光栅化与主线程空闲两个信号都到了才允许预热。
  group('runWebViewPrewarmWhenIdle', () {
    test('首帧光栅化前不预热、也不提前申请空闲槽', () async {
      final Completer<void> firstFrame = Completer<void>();
      int idleRequests = 0;
      int prewarms = 0;
      unawaited(
        runWebViewPrewarmWhenIdle(
          firstFrameRasterized: firstFrame.future,
          whenIdle: () async => idleRequests++,
          prewarm: () async => prewarms++,
        ),
      );
      await pumpEventQueue();
      expect(prewarms, 0, reason: '首帧还没上屏就预热，会把首帧堵死（ANR 根因）');
      expect(idleRequests, 0, reason: '空闲槽应在首帧上屏之后才申请');
    });

    test('首帧已上屏但主线程未空闲时不预热', () async {
      final Completer<void> idle = Completer<void>();
      int prewarms = 0;
      unawaited(
        runWebViewPrewarmWhenIdle(
          firstFrameRasterized: Future<void>.value(),
          whenIdle: () => idle.future,
          prewarm: () async => prewarms++,
        ),
      );
      await pumpEventQueue();
      expect(prewarms, 0, reason: '首屏动效 / 帧还在跑时不该抢主线程');
    });

    test('首帧上屏 + 主线程空闲后恰好预热一次', () async {
      final Completer<void> firstFrame = Completer<void>();
      final Completer<void> idle = Completer<void>();
      final List<String> order = <String>[];
      final Future<void> done = runWebViewPrewarmWhenIdle(
        firstFrameRasterized: firstFrame.future,
        whenIdle: () {
          order.add('idle-requested');
          return idle.future;
        },
        prewarm: () async => order.add('prewarm'),
      );
      firstFrame.complete();
      await pumpEventQueue();
      expect(order, <String>['idle-requested']);
      idle.complete();
      await done;
      expect(order, <String>['idle-requested', 'prewarm']);
    });

    test('prewarm 抛错原样外抛给调用方处理', () async {
      await expectLater(
        runWebViewPrewarmWhenIdle(
          firstFrameRasterized: Future<void>.value(),
          whenIdle: () async {},
          prewarm: () async => throw StateError('boom'),
        ),
        throwsStateError,
      );
    });
  });

  // 单测只证明时机门本身对；main.dart 不经它直接构造 HeadlessInAppWebView，首帧前预热
  // 的 ANR 照旧。守卫：main.dart 唯一的 HeadlessInAppWebView 构造落在
  // runWebViewPrewarmWhenIdle(...) 调用之内，且接的是首帧光栅化 + idle 优先级。
  group('main.dart 预热时机守卫', () {
    test('HeadlessInAppWebView 只在 runWebViewPrewarmWhenIdle 之内构造', () {
      final String code = maskComments(
        File('lib/main.dart').readAsStringSync(),
      );
      final int gate = code.indexOf('runWebViewPrewarmWhenIdle(');
      final int ctor = code.indexOf('HeadlessInAppWebView(');
      expect(gate, isNonNegative, reason: '预热必须走 runWebViewPrewarmWhenIdle');
      expect(
        'HeadlessInAppWebView('.allMatches(code).length,
        1,
        reason: 'main.dart 只应有预热这一处 headless WebView 构造',
      );
      expect(ctor, greaterThan(gate), reason: '构造必须在时机门的 prewarm 回调里');
      final String gateArgs = code.substring(gate, ctor);
      expect(
        gateArgs,
        contains('waitUntilFirstFrameRasterized'),
        reason: 'endOfFrame 不够：deferFirstFrame 期间帧照跑但没上屏',
      );
      expect(gateArgs, contains('Priority.idle'));
    });
  });
}
