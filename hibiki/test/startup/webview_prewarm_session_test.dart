import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/webview_prewarm.dart';

import '../helpers/source_guard.dart';

void main() {
  group('WebViewPrewarmSession', () {
    test('载入完成即销毁一次', () async {
      int disposed = 0;
      final List<String> reasons = <String>[];
      final WebViewPrewarmSession session = WebViewPrewarmSession(
        disposeWebView: () async => disposed++,
        onFinished: reasons.add,
      );

      await session.finish('loaded');

      expect(disposed, 1);
      expect(reasons, <String>['loaded']);
      expect(session.isFinished, isTrue);
    });

    test('多路终点先到者胜：重复 finish 不会二次 dispose', () async {
      int disposed = 0;
      final List<String> reasons = <String>[];
      final WebViewPrewarmSession session = WebViewPrewarmSession(
        disposeWebView: () async => disposed++,
        onFinished: reasons.add,
      );

      await session.finish('renderer gone');
      await session.finish('loaded');
      await session.finish('timeout');

      expect(disposed, 1);
      expect(reasons, <String>['renderer gone']);
    });

    test('回调一直不来时由超时兜底销毁（旧实现在这里永久泄漏 renderer）', () {
      fakeAsync((FakeAsync async) {
        int disposed = 0;
        final List<String> reasons = <String>[];
        final WebViewPrewarmSession session = WebViewPrewarmSession(
          disposeWebView: () async => disposed++,
          timeout: const Duration(seconds: 30),
          onFinished: reasons.add,
        );

        session.armTimeout();
        expect(session.hasPendingTimeout, isTrue);

        async.elapse(const Duration(seconds: 29));
        expect(disposed, 0, reason: '超时未到不该提前销毁');

        async.elapse(const Duration(seconds: 2));
        expect(disposed, 1);
        expect(reasons, <String>['timeout']);
        expect(session.isFinished, isTrue);
      });
    });

    test('已终结后 armTimeout 不再挂表，超时也不会二次 dispose', () {
      fakeAsync((FakeAsync async) {
        int disposed = 0;
        final WebViewPrewarmSession session = WebViewPrewarmSession(
          disposeWebView: () async => disposed++,
          timeout: const Duration(seconds: 30),
        );

        session.finish('loaded');
        async.flushMicrotasks();
        session.armTimeout();

        expect(session.hasPendingTimeout, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(disposed, 1);
      });
    });

    test('已装表后正常终结会撤表，超时不再触发', () {
      fakeAsync((FakeAsync async) {
        int disposed = 0;
        final WebViewPrewarmSession session = WebViewPrewarmSession(
          disposeWebView: () async => disposed++,
          timeout: const Duration(seconds: 30),
        );

        session.armTimeout();
        session.finish('loaded');
        async.flushMicrotasks();

        expect(session.hasPendingTimeout, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(disposed, 1);
      });
    });

    test('dispose 抛错不外抛，原因里带上失败信息', () async {
      final List<String> reasons = <String>[];
      final WebViewPrewarmSession session = WebViewPrewarmSession(
        disposeWebView: () async => throw StateError('boom'),
        onFinished: reasons.add,
      );

      await session.finish('loaded');

      expect(session.isFinished, isTrue);
      expect(reasons.single, contains('dispose failed'));
      expect(reasons.single, startsWith('loaded'));
    });
  });

  // 上面的单测只证明 session 本身对；session 没被 main.dart 接上四条终点，
  // 预热照样会泄漏 renderer 并连坐杀进程。这条守卫锚在 warmup 的
  // HeadlessInAppWebView 构造调用上（括号配对给窗口，与缩进/参数顺序无关），
  // 注释里写同样的字面量不算命中。
  group('main.dart 预热接线守卫', () {
    test('warmup 的 HeadlessInAppWebView 接齐四条终点并装了兜底表', () {
      final String source = File('lib/main.dart').readAsStringSync();
      final String code = maskComments(source);
      final EnclosingCall warmup =
          enclosingCallOf(source, 'initialUrlRequest:');

      expect(warmup.name, 'HeadlessInAppWebView',
          reason: 'initialUrlRequest 锚点应落在预热的 HeadlessInAppWebView 构造里');

      final String body = maskComments(warmup.text);
      for (final String callback in <String>[
        'onLoadStop:',
        'onReceivedError:',
        'onRenderProcessGone:',
      ]) {
        expect(body, contains(callback),
            reason: '预热必须接管 $callback，否则该终点缺席：载入失败或 renderer '
                '被 OOM kill 时 headless WebView 永不销毁，且 Android 会连坐杀 app');
      }
      expect(body.split('session.finish(').length - 1, 3,
          reason: '三条回调终点都必须落到同一个 session.finish（幂等收口）');
      expect(code, contains('session.armTimeout()'),
          reason: 'run() 之后必须装兜底表，否则回调全不来时仍然永久泄漏');
    });
  });
}
