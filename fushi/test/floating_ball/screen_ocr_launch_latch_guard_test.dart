import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';

/// BUG-3602（应用内悬浮球不显示）/ BUG-3603（应用外截屏查词点了没反应）。
///
/// 截屏 OCR 的宿主 Activity（`ScreenCaptureRequestActivity`）被 ROM 静默拦下
/// （vivo「后台弹出界面」没开时后台 startActivity 无声失败），或
/// `screenOcrFinished` 在 MainActivity 销毁期间送不到（audio_service 缓存引擎让
/// Dart isolate 活着），Dart 藏起来的应用内球就永远等不到放回来的回调；而 Fushi
/// 在前台时应用外球让位给应用内球，应用内就一颗球都没有。
///
/// 状态机本身由 JVM 单测 `android/app/src/test/kotlin/app/fushi/reader/
/// ScreenOcrFlowLatchTest.kt` 钉住（本仓 CI 不跑 Android JVM 单测，那份只在本地
/// `gradle :app:testDebugUnitTest` 跑）；这里按源码钉住接线——任何一处断开，
/// 对应症状就会回来。
const String _dir = 'android/app/src/main/java/app/fushi/reader';

String _read(String name) =>
    File('$_dir/$name').readAsStringSync().replaceAll('\r\n', '\n');

/// 从 [signature] 开始到方法结束（4 空格缩进的 `}`）的方法体。
String _method(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNot(-1), reason: '找不到 $signature');
  return src.substring(start, src.indexOf('\n    }\n', start));
}

void main() {
  final String request = _read('ScreenCaptureRequestActivity.java');
  final String channel = _read('FloatingBallChannel.java');
  final String mainActivity = _read('MainActivity.java');

  test('发起登记一笔，宿主 Activity onCreate 销账（任何分支之前）', () {
    final String launch = _method(request, 'static boolean launch(');
    // 登记必须在把 Intent 交给系统之前，否则同步起来的 onCreate 先销账、后登记，
    // 下一次就会被误判成「被丢弃」。
    expect(
      launch.indexOf('LATCH.onLaunchRequested();'),
      allOf(
        isNot(-1),
        lessThan(launch.indexOf('BackgroundActivityLauncher.start(')),
      ),
    );
    final String onCreate = _method(
      request,
      'protected void onCreate(@Nullable Bundle savedInstanceState) {',
    );
    expect(
      onCreate.indexOf('LATCH.onHostCreated();'),
      allOf(
        isNot(-1),
        lessThan(onCreate.indexOf('savedInstanceState != null')),
      ),
    );
  });

  test('上一次发起被丢弃：下一次发起给出原因提示', () {
    final String launch = _method(request, 'static boolean launch(');
    expect(launch, contains('LATCH.takeDroppedLaunch(flowActive)'));
    expect(launch, contains('LABEL_LAUNCH_BLOCKED'));
    expect(launch, contains('Toast.makeText('));
    expect(
      request,
      contains(
        'static final String LABEL_LAUNCH_BLOCKED = "ocr_launch_blocked";',
      ),
    );
    // 提示文案由 Dart 按界面语言下发。
    expect(
      floatingBallNativeLabels().containsKey('ocr_launch_blocked'),
      isTrue,
    );
  });

  test('回到前台：被丢弃的发起按结束收尾，没送达的回调补发', () {
    final String onResume = _method(
      mainActivity,
      'protected void onResume() {',
    );
    expect(onResume, contains('FloatingBallChannel.onHostResumed();'));
    final String hostResumed = _method(
      channel,
      'static void onHostResumed() {',
    );
    expect(
      hostResumed,
      contains('ScreenCaptureRequestActivity.onHostAppResumed();'),
    );
    expect(hostResumed, contains('LATCH.takeUndelivered(channel != null)'));
    final String appResumed = _method(
      request,
      'static void onHostAppResumed() {',
    );
    expect(appResumed, contains('LATCH.takeDroppedLaunch(flowActive)'));
    expect(appResumed, contains('onFlowFinished();'));
  });

  test('screenOcrFinished 送不出去时不丢（记成未送达）', () {
    final String notify = _method(
      channel,
      'static void notifyScreenOcrFinished() {',
    );
    expect(notify, contains('LATCH.finish(channel != null)'));
    final String deliver = _method(
      channel,
      'private static void deliverScreenOcrFinished() {',
    );
    expect(
      RegExp(r'LATCH\.onDeliveryFailed\(\);').allMatches(deliver).length,
      2,
      reason: '通道不在 / 发送抛异常两条路都要改记未送达',
    );
    expect(channel, contains('LATCH.onDartStarted();'));
    // 旧的「通道不在就只清标记、不发送」不能回来。
    expect(channel, isNot(contains('dartOcrPending')));
  });
}
