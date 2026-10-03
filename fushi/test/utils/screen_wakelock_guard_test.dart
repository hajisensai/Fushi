import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `WakelockPlus.enable/disable/toggle` 的失败全部经返回的 Future 抛出（Linux：
/// D-Bus `org.freedesktop.ScreenSaver` 不存在时 `ServiceUnknown`）。调用点曾写成
/// `try { WakelockPlus.enable(); } catch`——catch 接不住 Future 里的错误，Linux 上
/// 打开阅读器就冒出未处理的异步错误；漫画页则把它和全屏恢复放进同一个 try，wakelock
/// 一失败全屏就被跳过。现在只允许 `screen_wakelock.dart` 直接碰 WakelockPlus，其余
/// 一律经永不抛错的 `setScreenWakelock`。
void main() {
  test('only screen_wakelock.dart talks to WakelockPlus directly', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll(r'\', '/');
      if (normalized.endsWith('lib/src/utils/misc/screen_wakelock.dart')) {
        continue;
      }
      final String source = entity.readAsStringSync();
      if (source.contains('package:wakelock_plus/') ||
          RegExp(r'\bWakelockPlus\.').hasMatch(source)) {
        offenders.add(normalized);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use setScreenWakelock (lib/src/utils/misc/screen_wakelock.dart)',
    );
  });

  test('setScreenWakelock awaits the platform call inside its try', () {
    final String helper = File(
      'lib/src/utils/misc/screen_wakelock.dart',
    ).readAsStringSync();
    expect(helper, contains('await WakelockPlus.toggle(enable: enable);'));
    expect(helper, contains('} catch (e) {'));
  });
}
