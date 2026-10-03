import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2901：截屏识字的选取层点一个字就被拆掉（`onSelectionTap` 末尾 `finishFlow()`），
/// 查下一个词得重新截屏、重新过授权框；选取层本身整屏压暗 + 每行实线框，满屏蓝框
/// 盖住要读的字。
///
/// 修复是原生 Service / Activity 生命周期上的会话协议。协议的**取舍**（何时报
/// SHOWN / CLOSED / LEFT、过期会话忽略、先盯令牌再隐藏、屏幕几何变了就收尾）全在纯
/// 状态机 `ScreenOcrSession.kt`（`ScreenOcrLookupReporter` / `ScreenOcrSelectionSession`）
/// 里，行为由 JVM 单测 `android/app/src/test/kotlin/app/fushi/reader/ScreenOcrSessionTest.kt`
/// 钉住（本仓 CI 不跑 Android JVM 单测，那份只在本地 `gradlew :app:testDebugUnitTest` 跑）。
/// 这里在源码层钉住结构：
///   - 点字不收尾，带会话号拉起查词窗；
///   - Service / Activity 只接线，决定一律经状态机，不在接线层重写判断；
///   - 状态机不依赖 android.*（否则 JVM 单测跑不起来）；
///   - 选取层不整屏压暗、静息不描边，只有按下的那一行描边。
void main() {
  const String root = 'android/app/src/main/java/app/fushi/reader';
  final String service = File('$root/ScreenOcrService.java').readAsStringSync();
  final String activity = File(
    '$root/PopupDictFlutterActivity.kt',
  ).readAsStringSync();
  final String machine = File('$root/ScreenOcrSession.kt').readAsStringSync();

  String body(String src, String start, String end) {
    final int from = src.indexOf(start);
    expect(from, isNonNegative, reason: '找不到 $start');
    final int to = src.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: '找不到 $end');
    return src.substring(from, to);
  }

  test(
    'tapping a glyph launches the popup with a session and keeps the flow',
    () {
      final String tap = body(
        service,
        'private void onSelectionTap',
        'private void setSelectionHidden',
      );
      expect(tap, contains('BackgroundActivityLauncher.start(this, intent)'));
      expect(
        tap,
        contains('PopupDictFlutterActivity.EXTRA_SCREEN_OCR_SESSION'),
      );
      // 行外点击仍然收尾；行内点字之后不再收尾。
      final String afterLaunch = tap.substring(
        tap.indexOf('BackgroundActivityLauncher.start'),
      );
      expect(
        afterLaunch,
        isNot(contains('finishFlow()')),
        reason: '点字后拆掉选取层 = 每查一个词都要重新截屏授权（BUG-2901）',
      );
    },
  );

  test(
    'the service routes every lookup decision through the state machine',
    () {
      final String receiver = body(
        service,
        'private final BroadcastReceiver lookupReceiver',
        'private static ScreenOcrLookupEvent lookupEventOf',
      );
      expect(receiver, contains('session.onLookupEvent('));
      expect(
        receiver,
        isNot(contains('setSelectionHidden(')),
        reason: '隐藏 / 恢复由 ScreenOcrSelectionSession 决定，接收端不许自己判',
      );
      expect(receiver, isNot(contains('finishFlow()')));
      expect(receiver, contains('currentScreenIdentity()'));
      expect(
        service,
        isNot(contains('private long sessionId')),
        reason: '会话号只有状态机一份，Service 不留第二份',
      );
      // 终点用函数自己的兜底 return：签名里的参数就带 @Nullable，拿它当终点
      // 只会切出签名一行。
      final String mapping = body(
        service,
        'private static ScreenOcrLookupEvent lookupEventOf',
        'return null;',
      );
      expect(mapping, contains('ACTION_LOOKUP_SHOWN.equals(action)'));
      expect(mapping, contains('ACTION_LOOKUP_CLOSED.equals(action)'));
      expect(mapping, contains('ACTION_LOOKUP_LEFT.equals(action)'));
      expect(service, contains('ContextCompat.RECEIVER_NOT_EXPORTED'));

      final String hide = body(
        service,
        'private void setSelectionHidden',
        'private void removeSelectionView',
      );
      expect(hide, contains('FLAG_NOT_TOUCHABLE'));
      expect(hide, contains('FLAG_NOT_FOCUSABLE'));
      expect(hide, contains('updateViewLayout'));
    },
  );

  test(
    'the frozen selection is invalidated when the screen geometry changes',
    () {
      // 查词窗 configChanges 含 orientation|screenSize，在它里面转屏不会走 LEFT：选取层
      // 必须自己记住截屏时的几何，变了就收尾，不把竖屏定格帧盖到横屏上。
      final String capture = body(
        service,
        'private void startCapture',
        'captureThread = new HandlerThread',
      );
      expect(capture, contains('session.onCaptureStarted('));
      expect(capture, contains('displayRotation()'));
      final String config = body(
        service,
        'public void onConfigurationChanged',
        'public void onDestroy',
      );
      expect(
        config,
        contains('session.onConfigurationChanged(currentScreenIdentity())'),
      );
      final String identity = body(
        service,
        'private ScreenOcrSelectionSession.ScreenIdentity currentScreenIdentity',
        'private String label',
      );
      expect(identity, contains('realScreenBounds()'));
      expect(identity, contains('getRotation()'));
      final String closed = body(
        machine,
        'ScreenOcrLookupEvent.CLOSED ->',
        'ScreenOcrLookupEvent.LEFT ->',
      );
      expect(
        closed.indexOf('matchesCapture(current)'),
        lessThan(closed.indexOf('setHidden(false)')),
        reason: '恢复选取层之前必须先核对屏幕几何',
      );
    },
  );

  test('the popup feeds its lifecycle to the reporter state machine', () {
    expect(activity, contains('const val EXTRA_SCREEN_OCR_SESSION'));
    expect(
      body(activity, 'override fun onCreate', 'override fun'),
      contains('screenOcrReporter.onCreate('),
    );
    expect(
      body(activity, 'override fun onNewIntent', 'private fun'),
      contains('screenOcrReporter.onNewIntent('),
      reason: '别的入口复用查词窗时，原截图会话必须收尾',
    );
    expect(
      body(activity, 'override fun onResume', 'override'),
      contains('screenOcrReporter.onResume()'),
    );
    expect(
      body(activity, 'override fun onPause', 'override'),
      contains('screenOcrReporter.onPause(isFinishing)'),
    );
    expect(
      body(activity, 'override fun onStop', 'private fun'),
      contains('screenOcrReporter.onStop(isFinishing)'),
    );
    expect(
      activity,
      isNot(contains('private var screenOcrSession')),
      reason: '会话号只有 ScreenOcrLookupReporter 一份',
    );
    final String send = body(
      activity,
      'private fun reportScreenOcr',
      'override fun onDestroy',
    );
    expect(send, contains('ScreenOcrService.ACTION_LOOKUP_SHOWN'));
    expect(send, contains('ScreenOcrService.ACTION_LOOKUP_CLOSED'));
    expect(send, contains('ScreenOcrService.ACTION_LOOKUP_LEFT'));
    expect(send, contains('.setPackage(packageName)'), reason: '回报广播必须定向本包');
  });

  test('the session state machine stays free of the Android framework', () {
    expect(
      RegExp(r'^import android\.', multiLine: true).hasMatch(machine),
      isFalse,
      reason: '状态机碰了 android.* 就跑不了 JVM 单测',
    );
    expect(machine, contains('class ScreenOcrLookupReporter'));
    expect(machine, contains('class ScreenOcrSelectionSession'));
    expect(
      File(
        'android/app/src/test/kotlin/app/fushi/reader/ScreenOcrSessionTest.kt',
      ).existsSync(),
      isTrue,
      reason: '状态机的行为测试不能被删掉',
    );
  });

  test('a dead popup process cannot strand the hidden overlay', () {
    // 选取层隐藏后，:popup 进程崩了就发不出 CLOSED / LEFT：只能靠 Binder 死亡通知收尾，
    // 否则选取层永远藏着、流程锁不解、悬浮球回不来。
    final String shown = body(
      machine,
      'ScreenOcrLookupEvent.SHOWN ->',
      'ScreenOcrLookupEvent.CLOSED ->',
    );
    final int watch = shown.indexOf('watchLookupToken(token)');
    expect(watch, isNonNegative);
    expect(
      shown.indexOf('setHidden(true)'),
      greaterThan(watch),
      reason: '没盯住查词窗进程之前不许隐藏',
    );
    expect(service, contains('token.linkToDeath('));
    expect(service, contains('session.onLookupProcessDied()'));
    final String finish = body(
      service,
      'private void finishFlow()',
      'stopSelf()',
    );
    expect(finish, contains('session.reset()'));
    expect(finish, contains('unwatchLookupToken()'));
    expect(activity, contains('putBinder(ScreenOcrService.EXTRA_LOOKUP_TOKEN'));
  });

  test(
    'recognition finishing after the flow ended does not show an overlay',
    () {
      final String recognize = body(
        service,
        'private void recognize',
        'private static List<ScreenOcrLayout.Line> toLines',
      );
      final int success = recognize.indexOf('addOnSuccessListener');
      final int guard = recognize.indexOf('if (finished)', success);
      expect(guard, greaterThan(success));
      expect(recognize.indexOf('showSelection(lines)'), greaterThan(guard));
    },
  );

  test('the selection layer draws the frozen frame without dimming or a box '
      'around every line', () {
    final String draw = body(
      service,
      'protected void onDraw',
      'private float topInset',
    );
    expect(draw, contains('canvas.drawBitmap(frame'));
    expect(draw, isNot(contains('dimPaint')));
    expect(service, isNot(contains('0x33000000')));
    // 描边只在按下的那一行。
    final int stroke = draw.indexOf('strokePaint');
    final int pressed = draw.indexOf('i == pressedLine');
    expect(pressed, isNonNegative);
    expect(stroke, greaterThan(pressed));
    expect('strokePaint'.allMatches(draw).length, 1);
  });
}
