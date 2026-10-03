import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2901：截屏识字的选取层点一个字就被拆掉（`onSelectionTap` 末尾 `finishFlow()`），
/// 查下一个词得重新截屏、重新过授权框；选取层本身整屏压暗 + 每行实线框，满屏蓝框
/// 盖住要读的字。
///
/// 修复是原生 Service / Activity 生命周期上的会话协议，Dart 测试宿主跑不了，这里在
/// 源码层钉住契约：
///   - 点字不收尾，带会话号拉起查词窗；
///   - 选取层只在查词窗回报「已显示」后才隐藏（拉起失败时留着，不会藏起来回不来）；
///   - 查词窗在显示 / 被关 / 用户离开三处各回报一次；
///   - 选取层不整屏压暗、静息不描边，只有按下的那一行描边。
void main() {
  const String root = 'android/app/src/main/java/app/fushi/reader';
  final String service = File('$root/ScreenOcrService.java').readAsStringSync();
  final String activity = File(
    '$root/PopupDictFlutterActivity.kt',
  ).readAsStringSync();

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

  test('the overlay hides only once the popup reports it is shown', () {
    final String receiver = body(
      service,
      'private final BroadcastReceiver lookupReceiver',
      '@Nullable',
    );
    expect(receiver, contains('session != sessionId'), reason: '过期会话的回报必须被忽略');
    expect(receiver, contains('ACTION_LOOKUP_SHOWN.equals(action)'));
    expect(receiver, contains('setSelectionHidden(true)'));
    expect(receiver, contains('ACTION_LOOKUP_CLOSED.equals(action)'));
    expect(receiver, contains('setSelectionHidden(false)'));
    expect(receiver, contains('ACTION_LOOKUP_LEFT.equals(action)'));
    expect(receiver, contains('finishFlow()'));
    expect(service, contains('ContextCompat.RECEIVER_NOT_EXPORTED'));

    final String hide = body(
      service,
      'private void setSelectionHidden',
      'private void removeSelectionView',
    );
    expect(hide, contains('FLAG_NOT_TOUCHABLE'));
    expect(hide, contains('FLAG_NOT_FOCUSABLE'));
    expect(hide, contains('updateViewLayout'));
  });

  test(
    'the popup reports shown / closed / left for its screen OCR session',
    () {
      expect(activity, contains('const val EXTRA_SCREEN_OCR_SESSION'));
      final String resume = body(activity, 'override fun onResume', 'override');
      expect(resume, contains('ScreenOcrService.ACTION_LOOKUP_SHOWN'));
      final String pause = body(activity, 'override fun onPause', 'override');
      expect(pause, contains('isFinishing'));
      expect(pause, contains('ScreenOcrService.ACTION_LOOKUP_CLOSED'));
      final String stop = body(activity, 'override fun onStop', 'private fun');
      expect(stop, contains('ScreenOcrService.ACTION_LOOKUP_LEFT'));
      final String newIntent = body(
        activity,
        'override fun onNewIntent',
        'private fun',
      );
      expect(
        newIntent,
        contains('ScreenOcrService.ACTION_LOOKUP_LEFT'),
        reason: '别的入口复用查词窗时，原截图会话必须收尾',
      );
      expect(
        activity,
        contains('.setPackage(packageName)'),
        reason: '回报广播必须定向本包',
      );
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
