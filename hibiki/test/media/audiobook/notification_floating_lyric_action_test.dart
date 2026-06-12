import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（TODO-160子d / BUG-227）：Android 媒体播放通知栏新增「悬浮字幕」custom
/// action，沿用现有 prev/next/playPause 的 StreamController 范式路由回 reader
/// 页的 _toggleFloatingLyric（真启停 native service）。audio_service 平台通道在
/// host 不可用，故源码扫描钉接线。
void main() {
  late String handler;
  late String controller;
  late String reader;
  setUpAll(() {
    handler =
        File('lib/src/utils/misc/hibiki_audio_handler.dart').readAsStringSync();
    controller =
        File('lib/src/models/audio_controller.dart').readAsStringSync();
    reader = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
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

  test('reader page 订阅 toggleFloatingLyricStream 并调 _toggleFloatingLyric', () {
    expect(reader.contains('toggleFloatingLyricStream'), isTrue);
    expect(reader.contains('_toggleFloatingLyric()'), isTrue);
  });
}
