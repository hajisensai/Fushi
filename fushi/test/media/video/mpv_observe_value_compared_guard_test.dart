import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（BUG-3315）：app 代码订阅 libmpv 属性一律走比值订阅
/// `observePropertyChanges`，不得直接调用无格式的 `observeProperty`。
///
/// media_kit 的 `observeProperty` 以 `MPV_FORMAT_NONE` 订阅，mpv 对无格式订阅恒报
/// 「已变化」；挂在 `MPV_EVENT_TICK` 上的属性（`sub-start` / `sub-end` / `time-pos` /
/// 帧计数，以及本仓 libmpv 补丁加的 `disc-navigation-state-json`）于是每帧来一次事件，
/// 每次还先在事件 isolate 上同步 `mpv_get_property_string`（拿 mpv 核心锁）。实测
/// 60 fps 播 2 s：无格式 121 次回调，比值订阅 1 次
/// （`test/third_party/media_kit_observe_changes_test.dart`）。
///
/// 一条规则、不留白名单：哪个属性挂在 TICK 上要去翻 mpv 源码与本仓补丁，逐个判断必然
/// 漏；比值订阅对非 TICK 属性同样正确，没有理由再用无格式订阅。
void main() {
  test('lib/ 下没有直接调用无格式 observeProperty', () {
    final RegExp bare = RegExp(r'\.observeProperty\(');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final List<String> lines = e.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String code = lines[i].split('//').first;
        if (bare.hasMatch(code)) offenders.add('${e.path}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '改用 native.observePropertyChanges（mpv 比值，值随事件到达）：'
          '无格式订阅在 TICK 属性上每帧一次同步锁 mpv 核心 → $offenders',
    );
  });
}
