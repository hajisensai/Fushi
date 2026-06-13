import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（TODO-160子d / BUG-227 / TODO-291 阶段2）：Android 媒体播放通知栏「悬浮字幕」
/// custom action，沿用现有 prev/next/playPause 的 StreamController 范式。TODO-291 阶段2
/// 把 toggleFloatingLyricStream 的订阅从 reader 页上移到进程级 [AudiobookSession]，路由回
/// AppModel.toggleFloatingLyricFromControls（真启停 native service + 偏好读写），使退书
/// 后台听书时通知按钮仍能翻转悬浮窗。audio_service 平台通道在 host 不可用，故源码扫描钉接线。
void main() {
  late String handler;
  late String controller;
  late String session;
  late String appModel;
  setUpAll(() {
    handler =
        File('lib/src/utils/misc/hibiki_audio_handler.dart').readAsStringSync();
    controller =
        File('lib/src/models/audio_controller.dart').readAsStringSync();
    session = File(
      'lib/src/media/audiobook/audiobook_session.dart',
    ).readAsStringSync();
    appModel = File('lib/src/models/app_model.dart').readAsStringSync();
  });

  test('handler 有 onToggleFloatingLyric 回调字段', () {
    expect(handler.contains('onToggleFloatingLyric'), isTrue);
  });

  test('handler 覆写 customAction 路由 toggleFloatingLyric', () {
    expect(handler.contains('customAction'), isTrue);
    expect(handler.contains('toggleFloatingLyric'), isTrue);
  });

  test('通知 controls 含 MediaControl.custom 悬浮字幕按钮', () {
    expect(handler.contains('MediaControl.custom'), isTrue);
    expect(handler.contains('ic_notif_floating_lyric'), isTrue);
  });

  test('audio_controller wire onToggleFloatingLyric 到广播 stream', () {
    expect(controller.contains('onToggleFloatingLyric'), isTrue);
    expect(controller.contains('toggleFloatingLyricStream'), isTrue);
  });

  test('session 订阅 toggleFloatingLyricStream（进程级，脱离 reader）', () {
    expect(session.contains('toggleFloatingLyricStream'), isTrue);
    // 通知翻转经注入的 onToggleFloatingLyricFromNotification 回调路由出去。
    expect(session.contains('onToggleFloatingLyricFromNotification'), isTrue);
  });

  test('AppModel 把通知翻转接到 toggleFloatingLyricFromControls', () {
    expect(
      appModel.contains('onToggleFloatingLyricFromNotification ='),
      isTrue,
    );
    expect(appModel.contains('toggleFloatingLyricFromControls'), isTrue);
  });
}
