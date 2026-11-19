import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4791 / BUG-4792 的接线守卫。
///
/// JVM 单测 `CrossAppAudioPolicyTest` 只钉住纯判定；真机线程模型与 Activity 生命周期在
/// 这里跑不了，故守**调用点**：把判定从调用点拿掉（退回主线程 RPC / 退回 `isFinishing()`）
/// 时纯判定的单测照样绿，只有这里会红。
void main() {
  // Tests run with CWD = `fushi/`.
  const String dir = 'android/app/src/main/java/app/fushi/reader';
  late String channel;
  late String activity;
  setUpAll(() {
    channel = maskComments(
      File('$dir/CrossAppAudioChannel.java').readAsStringSync(),
    );
    activity = maskComments(
      File('$dir/CrossAppAudioRequestActivity.java').readAsStringSync(),
    );
  });

  String methodBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(0), reason: 'missing $signature');
    int depth = 0;
    for (int i = src.indexOf('{', start); i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(start, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  test('provider RPC 方法按判定投到后台执行器（BUG-4791）', () {
    final String body = methodBody(channel, 'static void registerWith(');
    expect(body, contains('CrossAppAudioPolicy.callsProviderOffMain(method)'));
    expect(body, contains('PROVIDER_IO.execute('));
    expect(body, contains('runProviderCall(app, method, backMs)'));
    // 后台线程上未捕获的异常会杀进程，且 Dart Future 必须完成。
    expect(body, contains('catch (RuntimeException'));
    expect(body, contains('result.error('));
    // 主线程 switch 里不得再有直连 Provider 的分支。
    for (final String m in <String>['status', 'stop', 'snapshot']) {
      expect(body, isNot(contains('case "$m"')), reason: m);
    }
    expect(body, isNot(contains('callProvider(')));
    expect(channel, contains('Executors.newSingleThreadExecutor()'));
  });

  test('callProvider 只从 runProviderCall（后台）调用', () {
    final String runBody = methodBody(
      channel,
      'private static Object runProviderCall(',
    );
    final int total = RegExp(r'\bcallProvider\(').allMatches(channel).length;
    final int inRun = RegExp(r'\bcallProvider\(').allMatches(runBody).length;
    // 剩下的一处是 callProvider 自己的声明。
    expect(total - inRun, 1);
  });

  test('授权页销毁按 isChangingConfigurations 结账，不看 isFinishing（BUG-4792）', () {
    final String body = methodBody(activity, 'protected void onDestroy(');
    expect(
      body,
      matches(
        RegExp(
          r'CrossAppAudioPolicy\.releasesPendingStartOnDestroy\(\s*'
          r'owesResult,\s*isChangingConfigurations\(\)\)',
        ),
      ),
    );
    expect(body, isNot(contains('isFinishing()')));
    expect(
      body,
      contains('CrossAppAudioChannel.completeStart(false, "denied")'),
    );
  });
}
