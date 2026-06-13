import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-291 阶段2）：有声书控制器的生命周期归进程级 [AudiobookSession]，
/// 不再绑死 reader 页 State。这条钉住解耦的关键不变量，防回归把控制器又拉回 reader 里
/// 创建 / dispose（会让「退出书籍后继续听书」失效）：
///
///  1) reader 页 **不再自己 new AudiobookPlayerController**（创建归 session）；
///  2) reader dispose **不 dispose 控制器**，改成 session.detachReader（控制器存活）；
///  3) reader dispose **不再无条件 FloatingLyricChannel.hide()**（悬浮窗归 session，只在
///     会话结束时才隐藏）；
///  4) session 是唯一创建并持有控制器的地方。
void main() {
  final String reader = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();
  final String session = File(
    'lib/src/media/audiobook/audiobook_session.dart',
  ).readAsStringSync();

  test('reader page no longer constructs an AudiobookPlayerController', () {
    expect(
      reader.contains('AudiobookPlayerController()'),
      isFalse,
      reason: '控制器创建归 AudiobookSession，reader 不再 new 控制器',
    );
  });

  test('reader dispose detaches the session instead of disposing controller',
      () {
    final RegExpMatch? body = RegExp(
      r'void dispose\(\) \{(.*?)\n    super\.dispose\(\);',
      dotAll: true,
    ).firstMatch(reader);
    expect(body, isNotNull, reason: '找不到 reader dispose 方法体');
    final String disposeBody = body!.group(1)!;
    expect(
      disposeBody.contains('audiobookSession.detachReader(this)'),
      isTrue,
      reason: 'reader dispose 必须 detach session（不 dispose 控制器）',
    );
    expect(
      disposeBody.contains('_audiobookController?.dispose()'),
      isFalse,
      reason: 'reader dispose 不得 dispose 控制器（控制器归 session 进程级持有）',
    );
    expect(
      disposeBody.contains('FloatingLyricChannel.hide()'),
      isFalse,
      reason: 'reader dispose 不得无条件隐藏悬浮窗（悬浮窗归 session，退书后台听书继续刷字）',
    );
  });

  test('session is the controller owner (creates + disposes it)', () {
    expect(session.contains('AudiobookPlayerController()'), isTrue,
        reason: 'session.start 是控制器的创建点');
    expect(
      RegExp(r'controller\.dispose\(\)').hasMatch(session),
      isTrue,
      reason: 'session 是控制器的 dispose 点（stop / dispose）',
    );
    expect(session.contains('void detachReader('), isTrue);
    // detachReader 把跨章参照系复位成 -1（跨章守卫天然不动作）。
    expect(
      session.contains('getCurrentReaderSection = () => -1'),
      isTrue,
      reason: 'detach 后 getCurrentReaderSection 复位 -1，跨章守卫不动作',
    );
  });
}
