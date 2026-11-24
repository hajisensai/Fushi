import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_gal_lookup_log.dart';
import 'package:fushi/src/utils/dart_heartbeat.dart';

/// Dart 失联检测：Dart 侧每秒心跳 + runner 看门狗据此判定的接线守卫。
///
/// 现场（2026-11-24）：缩窗后 fushi 内容整片黑屏，平台线程空闲、窗口消息照常，
/// Dart 却不回应任何本地端口——旧看门狗只量「主线程停泵」，量不到这种事故。
void main() {
  tearDown(resetDartHeartbeatForTest);

  test('Windows：每个间隔发一次心跳，重复安装不叠定时器', () {
    fakeAsync((FakeAsync async) {
      int beats = 0;
      installDartHeartbeat(
        send: () async => beats++,
        isWindows: true,
        isDebug: false,
      );
      installDartHeartbeat(
        send: () async => beats += 100,
        isWindows: true,
        isDebug: false,
      );
      async.elapse(const Duration(seconds: 5));
      expect(beats, 5);
    });
  });

  test('非 Windows：不起定时器', () {
    fakeAsync((FakeAsync async) {
      int beats = 0;
      installDartHeartbeat(
        send: () async => beats++,
        isWindows: false,
        isDebug: false,
      );
      async.elapse(const Duration(seconds: 5));
      expect(beats, 0);
    });
  });

  test('debug 构建：不起定时器（Dart 断点暂停不是卡死）', () {
    fakeAsync((FakeAsync async) {
      int beats = 0;
      installDartHeartbeat(
        send: () async => beats++,
        isWindows: true,
        isDebug: true,
      );
      async.elapse(const Duration(seconds: 5));
      expect(beats, 0);
    });
  });

  test('Dart 失联计量行在反馈日志白名单里', () {
    const String raw =
        '2026-11-24T10:00:00  [native] dart-silence: ms=10100 dump=hang-1.dmp';
    expect(galLookupDiagnosticLines(raw), hasLength(1));
  });

  test('Dart 方法名与 runner 处理器、看门狗接线一致', () {
    final String dart = File(
      'lib/src/utils/window_caption_channel.dart',
    ).readAsStringSync();
    final String window = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    final String dog = File(
      'windows/runner/hang_watchdog.cpp',
    ).readAsStringSync();
    final String header = File(
      'windows/runner/hang_watchdog.h',
    ).readAsStringSync();
    final String main = File('lib/main.dart').readAsStringSync();

    expect(dart, contains("invokeMethod<void>('dartHeartbeat')"));
    expect(
      window,
      contains('call.method_name() == "dartHeartbeat"'),
      reason: 'runner 必须处理 Dart 的 dartHeartbeat，否则永远不会布防',
    );
    expect(window, contains('::fushi::NoteDartHeartbeat();'));
    expect(header, contains('void NoteDartHeartbeat();'));
    expect(dog, contains('g_dart_beat_ms'));
    expect(dog, contains('dart_beat_ms == 0'), reason: '第一次心跳到达前不布防，启动期不能算失联');
    expect(dog, contains('dart heartbeat silent'));
    expect(
      dog,
      contains('WriteProcessMinidump(L"hang"'),
      reason: 'Dart 失联 dump 沿用 hang 前缀，诊断区「崩溃转储」页自动列出',
    );
    expect(main, contains('installDartHeartbeat();'));
  });
}
