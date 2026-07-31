import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// 开媒体反馈守卫（渐进重建 phase2）：audio_service 冷启不得阻塞 Navigator.push。
///
/// 旧 openMedia 在 push 之前 `await initialiseAudioHandler()`——冷路径数百 ms 的
/// 平台通道重活，表现为「点下书/视频卡片后屏幕毫无反应的那段」。修复后的时序
/// 契约拆成三条不变量，缺一即回归：
///  ① openMedia 只起跑不 await（导航立即开始）；
///  ② AudioController.initialiseHandler 记忆化在飞 future（并发安全、可重复
///     await——没有这条，② 的消费端 await 与 ① 的起跑会双跑 AudioService.init）；
///  ③ handler 的真正消费端补 await：reader `_resolveAudioSlot`（session
///     attach/start 挂媒体通知前）与书架后台听书 `startBackgroundListening`。
///
/// 行为驱动需要真平台通道（AudioService.init），host 测试不可用，落源码语料层。
void main() {
  final String appModelSrc = File('lib/src/models/app_model.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final String audioCtrlSrc = File('lib/src/models/audio_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final String readerSrc = readReaderPageSource();

  test('① openMedia 不再 await audio handler 冷启（起跑不阻塞导航）', () {
    final int start = appModelSrc.indexOf('Future<void> openMedia({');
    final int end = appModelSrc.indexOf('Future<void> closeMedia({');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String body = appModelSrc.substring(start, end);
    expect(body.contains('await initialiseAudioHandler()'), isFalse,
        reason: 'push 前 await 冷启 = 点击后零反馈的那段，禁止回归');
    expect(body.contains('unawaited(initialiseAudioHandler())'), isTrue,
        reason: '必须仍在 openMedia 起跑（尽早并行热身），只是不阻塞');
  });

  test('② initialiseHandler 记忆化在飞 future（并发安全单次初始化）', () {
    expect(audioCtrlSrc.contains('_handlerInit ??= _initialiseHandlerOnce()'),
        isTrue,
        reason: '无记忆化时「openMedia 起跑 + 消费端 await」并发双跑 '
            'AudioService.init');
  });

  test('③ reader _resolveAudioSlot 在会话操作前 await handler 就绪', () {
    final int slotStart = readerSrc
        .indexOf('Future<void> _resolveAudioSlot({bool forceReload = false})');
    final int sessionUse = readerSrc.indexOf(
        'final AudiobookSession session = appModel.audiobookSession;',
        slotStart);
    expect(slotStart, greaterThanOrEqualTo(0));
    expect(sessionUse, greaterThan(slotStart));
    final String beforeSession = readerSrc.substring(slotStart, sessionUse);
    expect(beforeSession.contains('await appModel.initialiseAudioHandler();'),
        isTrue,
        reason: 'session attach/start 挂媒体通知前 handler 必须就绪——'
            'openMedia 不再兜底这个时序，消费端自己 await');
  });

  test('③ 书架后台听书入口仍 await handler 就绪', () {
    final int start = appModelSrc
        .indexOf('Future<BackgroundListenResult> startBackgroundListening(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = appModelSrc.substring(start, start + 800);
    expect(body.contains('await initialiseAudioHandler();'), isTrue);
  });
}
