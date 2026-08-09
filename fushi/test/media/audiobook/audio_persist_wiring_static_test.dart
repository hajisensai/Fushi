import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-031 / TODO-291 阶段2）：有声书音量持久化是「load 读 + 改写 persist」
/// 两段接线，任一段被回归删掉都会让音量重新变成「不保存」。TODO-291 阶段2 把控制器创建 +
/// 音频文件/偏好解析 + persist 接线从 reader 页两条 init 路径下沉到共用的
/// [AudiobookSessionLauncher]（reader + 书架共用）。这条钉住 launcher 仍读出音量/速度
/// （readVolume/readSpeed）并装 persist 回调（onVolumePersist/onSpeedPersist），且会话
/// 把它们传给 load（initialVolume/initialSpeed）。
void main() {
  test('session launcher wires volume + speed read + persist + initial', () {
    final String launcher = File(
      'lib/src/media/audiobook/audiobook_session_launcher.dart',
    ).readAsStringSync();
    final String session = File(
      'lib/src/media/audiobook/audiobook_session.dart',
    ).readAsStringSync();

    // launcher 装 persist 回调 + 从 repo 读出音量/速度。
    expect(launcher.contains('onVolumePersist'), isTrue,
        reason: 'launcher 要装 onVolumePersist 回调');
    expect(RegExp(r'readVolume\(').hasMatch(launcher), isTrue,
        reason: 'launcher 要从 repo 读出持久化音量');
    expect(launcher.contains('onSpeedPersist'), isTrue,
        reason: 'launcher 要装 onSpeedPersist 回调');
    expect(RegExp(r'readSpeed\(').hasMatch(launcher), isTrue,
        reason: 'launcher 要从 repo 读出持久化速度');

    // session 把读出的初值传给控制器 load。
    expect(session.contains('initialVolume:'), isTrue,
        reason: 'session.start 要把音量作为 initialVolume 传给 load');
    expect(session.contains('initialSpeed:'), isTrue,
        reason: 'session.start 要把速度作为 initialSpeed 传给 load');
  });

  /// 源码守卫（TODO-291 阶段2）：有声书控制器的生命周期归进程级 [AudiobookSession]，
  /// 不再绑死 reader 页 State。这条钉住解耦的关键不变量，防回归把控制器又拉回 reader 里
  /// 创建 / dispose（会让「退出书籍后继续听书」失效）：
  ///
  ///  1) reader 页 **不再自己 new AudiobookPlayerController**（创建归 session）；
  ///  2) reader dispose **不 dispose 控制器**，改成 session.detachReader（控制器存活）；
  ///  3) reader dispose **不再无条件 FloatingLyricChannel.hide()**（悬浮窗归 session，只在
  ///     会话结束时才隐藏）；
  ///  4) session 是唯一创建并持有控制器的地方。
  ///
  /// （并自 audiobook_session_ownership_static_test.dart。）
  group('audiobook session ownership (TODO-291 阶段2)', () {
    final String reader = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
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
  });
}
