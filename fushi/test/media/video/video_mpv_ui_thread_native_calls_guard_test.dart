import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-3501 守卫：app 代码不得在 UI 线程上同步碰 mpv 内核锁。
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
          '同步 mpv 调用会在 UI 线程上排内核锁、冻住视频合成（BUG-3501）。'
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
    expect(getAsync, contains('mpv_get_property_async('));
    expect(getAsync, isNot(contains('mpv_get_property_string(')));

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
}
