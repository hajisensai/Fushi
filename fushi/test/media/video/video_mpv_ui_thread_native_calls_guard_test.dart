import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-3507 守卫：app 代码不得在 UI 线程上同步碰 mpv 内核锁。
///
/// media_kit 的 `getProperty`（`mpv_get_property_string`）和直接 FFI 的
/// `mpv_command` / `mpv_get_property` / `mpv_set_property*` 都在调用线程上等 mpv
/// 内核锁——在 app 里就是 Flutter UI 线程。内核一忙，事件循环停 0.4–0.6 s，视频
/// 纹理新帧排不上合成，画面冻住而声音照常。实测证据：诊断日志里 `[frame]` 探针的
/// 1 s 定时器被拖到与 `mpv/stats` 那轮同步读**同一毫秒**才触发。
///
/// 读一律走 media_kit 补丁的 `getPropertyAsync`，要结果码的命令走
/// `commandWithResult`；`setProperty` / `command` 由补丁走 `mpv_*_async`。
void main() {
  final RegExp forbidden = RegExp(r'\.getProperty\(|\.mpv\.mpv_[a-z_]+\(');

  test('fushi/lib never calls libmpv synchronously', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String source = entity.readAsStringSync();
      // 掩码串与原串逐字节等长、换行同位，可按行对照回原文。
      final List<String> masked = maskComments(source).split('\n');
      final List<String> lines = source.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (forbidden.hasMatch(masked[i])) {
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '同步 mpv 调用会在 UI 线程上排内核锁、冻住视频合成（BUG-3507）。'
          '读用 getPropertyAsync，要结果码的命令用 commandWithResult。',
    );
  });

  test('media_kit patch keeps property access off the calling thread', () {
    final File patch = File(
      '../ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/player/real.dart',
    );
    expect(patch.existsSync(), isTrue, reason: 'media_kit 补丁路径变了，同步更新本守卫');
    final String source = patch.readAsStringSync();

    String body(String signature) {
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '补丁里找不到 $signature');
      final int end = source.indexOf('\n  }\n', start);
      return source.substring(start, end);
    }

    final String getAsync = body('Future<String> getPropertyAsync(');
    expect(getAsync, contains('_queuePropertyRead('));
    expect(getAsync, isNot(contains('mpv_get_property_string(')));
    final String queueRead = body('Future<String?> _queuePropertyRead(');
    expect(queueRead, contains('mpv_get_property_async('));
    expect(queueRead, isNot(contains('mpv_get_property_string(')));

    final String setProperty = body('Future<void> setProperty(');
    expect(
      setProperty,
      contains('mpv_set_property_async('),
      reason: '公开 setProperty 必须走异步写（同步分支只留给 configuration.async=false）',
    );

    final String command = body('Future<int> commandWithResult(');
    expect(command, contains('mpv_command_async('));
    expect(command, isNot(contains('mpv.mpv_command(')));

    expect(source, contains('MPV_EVENT_GET_PROPERTY_REPLY'));
    expect(source, contains('_commandResultRequests.remove('));
    expect(
      body('Future<void> dispose('),
      contains('_completePendingAsyncRequests()'),
      reason: 'dispose 必须收掉挂起的异步请求，否则等回包的调用方永远挂着',
    );
  });

  // BUG-3507 收尾：事件循环（Flutter UI 线程）上的同步内核锁调用不只在 app 代码里，
  // 补丁里的事件分发与 on_load / on_unload 钩子体也算。observeProperty 的 FORMAT_NONE
  // 分支与钩子体改走 mpv_*_async；libmpv 没有异步版的 mpv_hook_add /
  // mpv_hook_continue（client.c 里 lock_core）只许出现在辅助 isolate 的顶层函数里。
  test('media_kit patch event loop and hooks take no core lock in-thread', () {
    final String source = maskComments(
      File(
        '../ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/player/real.dart',
      ).readAsStringSync(),
    );
    const List<String> coreLocked = <String>[
      'mpv.mpv_get_property_string(',
      'mpv.mpv_get_property(',
      'mpv.mpv_set_property(',
      'mpv.mpv_set_property_string(',
      'mpv.mpv_command(',
      'mpv.mpv_hook_add(',
      'mpv.mpv_hook_continue(',
    ];

    ({int start, int end}) span(String signature, String closing) {
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '补丁里找不到 $signature');
      return (start: start, end: source.indexOf(closing, start));
    }

    for (final String method in <String>[
      'Future<void> _handler(',
      'Future<void> _runHook(',
      'Future<void> _runOnLoadHook(',
      'Future<void> _runOnUnloadHook(',
    ]) {
      final ({int start, int end}) s = span(method, '\n  }\n');
      final String body = source.substring(s.start, s.end);
      if (method == 'Future<void> _handler(') {
        // 切片必须盖住整个分发函数（含末尾的钩子分支），否则后面的断言是空壳。
        expect(body, contains('MPV_EVENT_HOOK'));
        expect(body, contains('MPV_FORMAT_NONE'));
      }
      for (final String call in coreLocked) {
        expect(
          body.contains(call),
          isFalse,
          reason: '$method 跑在事件循环所在的 UI 线程上，不能同步调 $call',
        );
      }
    }

    // 钩子注册 / 放行只许在辅助 isolate 的顶层函数里。
    final List<({int start, int end})> offThread = <({int start, int end})>[
      span('void _hookAddLoadUnload(', '\n}\n'),
      span('void _hookContinue(', '\n}\n'),
    ];
    for (final String call in <String>[
      'mpv.mpv_hook_add(',
      'mpv.mpv_hook_continue(',
    ]) {
      int at = source.indexOf(call);
      expect(at, isNonNegative, reason: '补丁里找不到 $call');
      while (at >= 0) {
        expect(
          offThread.any(
            (({int start, int end}) r) => at > r.start && at < r.end,
          ),
          isTrue,
          reason: '$call 会拿 mpv 内核锁，只能经 compute 在辅助 isolate 里调',
        );
        at = source.indexOf(call, at + 1);
      }
    }
    final ({int start, int end}) d = span('Future<void> dispose(', '\n  }\n');
    expect(
      source.substring(d.start, d.end),
      contains('_offThreadNativeCalls'),
      reason: '销毁句柄前必须等辅助 isolate 上的钩子放行跑完',
    );
  });

  // 暂停 OCR 截帧不得占 Player 串行锁：截帧 + 纯 Dart 编 PNG 要几百毫秒，持锁期间
  // play() / pause() 全排队，开着暂停识别时按继续播放要等截帧编完才响应。不持锁
  // 的截帧必须登记进 `_offThreadNativeCalls`，否则 dispose 可能在它还在用句柄时
  // mpv_terminate_destroy。
  test('pause-OCR frame capture does not hold the player lock', () {
    final String controller = maskComments(
      File(
        'lib/src/media/video/video_player_controller.dart',
      ).readAsStringSync(),
    );
    final int at = controller.indexOf(
      'Future<Uint8List?> captureFrameWithSubtitles(',
    );
    expect(at, isNonNegative, reason: '找不到 captureFrameWithSubtitles');
    final String capture = controller.substring(
      at,
      controller.indexOf('\n  }\n', at),
    );
    expect(capture, contains('.screenshot('));
    expect(
      capture,
      contains('synchronized: false'),
      reason: '持锁截帧会把 play()/pause() 卡在截帧 + 编码后面',
    );

    final String patch = maskComments(
      File(
        '../ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/player/real.dart',
      ).readAsStringSync(),
    );
    final int s = patch.indexOf('Future<Uint8List?> screenshot(');
    expect(s, isNonNegative, reason: '补丁里找不到 screenshot(');
    final String screenshot = patch.substring(s, patch.indexOf('\n  }\n', s));
    expect(screenshot, contains('compute('));
    expect(
      screenshot,
      contains('_offThreadNativeCalls.add('),
      reason: '不持锁的截帧要让 dispose 等它跑完再销毁句柄',
    );
    expect(screenshot, contains('_offThreadNativeCalls.remove('));
  });
}
