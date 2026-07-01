import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

/// BUG-264 — 「快捷键设置每个选项是否都生效」审计守卫。
///
/// 用户报「感觉有好几个选项的按钮不生效」。根因审计结论：源码层每个
/// [ShortcutAction] 都有 ① 平台默认绑定、② 设置页本地化标签、③ 至少一个执行体
/// 引用——没有完全孤立的「死项」。剩余「按了没反应」属**按表面的派发门控**
/// （如阅读器查词动作门控在实验性焦点导航开关、视频动作门控在沉浸锁定态），
/// 其执行体在被其它车道占用的巨文件里（reader/video），列为 gated 跟进。
///
/// 本守卫把「可配置即必须可执行」钉成不可回退的不变式：任何新增 [ShortcutAction]
/// 若忘了在某平台默认表里登记，或在所有页面/媒体执行体里都没有派发引用，
/// 即红——杜绝「设置里能配、按了没反应」这一整类死项再次出现。
void main() {
  test('每个 ShortcutAction 三平台默认表都有条目（可配置项必有默认绑定）', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      final Map<ShortcutAction, dynamic> map =
          ShortcutDefaults.forPlatform(platform);
      for (final ShortcutAction action in ShortcutAction.values) {
        expect(
          map.containsKey(action),
          isTrue,
          reason: '$platform 默认表缺少 ${action.key} —— 设置页会显示但没有默认绑定',
        );
      }
    }
  });

  test('每个 ShortcutAction 至少被一个执行体文件按枚举名派发引用（非死项）', () {
    // 执行体所在文件（按表面分派 ShortcutAction → 具体行为）。新增执行表面时
    // 在此登记；任何 action 若在这些文件里都没出现，即「配了不执行」的死项。
    const List<String> executorFiles = <String>[
      'lib/src/pages/implementations/reader_hibiki_page.dart',
      'lib/src/pages/implementations/reader_hibiki/caret.part.dart',
      'lib/src/pages/implementations/home_page.dart',
      'lib/src/media/video/video_player_shortcuts.dart',
      'lib/src/media/audiobook/pointer_seek.dart',
      'lib/src/shortcuts/gamepad_service.dart',
      'lib/src/shortcuts/reader_space_override.dart',
      // TODO-1066: the app-external global lookup hotkey's executor. It reads
      // ShortcutAction.globalExternalLookup from the registry and registers it
      // to the OS-level hotkey_manager (the one action that runs via a system
      // hotkey rather than page/media _executeShortcutAction dispatch).
      'lib/src/lookup/global_lookup_controller.dart',
    ];

    final StringBuffer corpus = StringBuffer();
    for (final String path in executorFiles) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: '执行体文件不存在：$path（路径过期请更新守卫）');
      corpus.writeln(f.readAsStringSync());
    }
    final String source = corpus.toString();

    final List<ShortcutAction> dead = <ShortcutAction>[
      for (final ShortcutAction action in ShortcutAction.values)
        if (!source.contains('ShortcutAction.${action.name}')) action,
    ];

    expect(
      dead,
      isEmpty,
      reason: '以下 action 在所有执行体文件里都没有派发引用（死项，配了不执行）：'
          '${dead.map((ShortcutAction a) => a.key).join(', ')}',
    );
  });
}
