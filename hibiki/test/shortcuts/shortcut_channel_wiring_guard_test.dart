import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

/// 「某个 scope 开放了某个输入通道，就必须真的存在该通道的解析入口」。
///
/// 与 `shortcut_action_wiring_guard_test` 的区别，也正是它抓不到的那类：那条守卫
/// 只扫「`ShortcutAction.<名>` 这个符号在某个执行体文件里出现过没有」。漫画页把
/// `ShortcutAction.mangaPageForward` 用在**键盘**路径上，符号出现了，于是那条守卫
/// 全绿——而同一个 action 的**手柄**默认绑定（RB / LB / dpad / B）压根没有消费者：
/// 漫画页既没有 `resolveGamepad`，也没有 `GamepadButtonIntent` 的 Action，Android
/// 的 `gameButton*` 键事件同样匹配不到纯键盘绑定。结果是用户在设置里能配手柄、按下
/// 去毫无反应——**比压根没有这个选项更糟**，用户会以为是自己手柄坏了。
///
/// 判据因此不是「符号出现过」，而是「**这个通道有没有解析入口**」：
/// 消费一个通道只有两种真实写法，缺一不可地都算证据——
///   ① 按 scope 解析：`registry.resolveKeyboard/resolveGamepad/resolveMouse(
///      …, scope: ShortcutScope.X)`；
///   ② 按 action 取绑定表：`registry.bindingsFor(<该 scope 的某个 action>)
///      .keyboardBindings / .gamepadBindings / .mouseBindings / .wheelBindings`
///      （video 的键盘、globalExternal 的 OS 级热键、查词弹窗的滚轮都走这条）。
/// 一个文件只有同时出现「该 scope 的身份」（`ShortcutScope.X` 或它名下某个
/// `ShortcutAction.<名>`）和「该通道的取用」，才算这个 (scope, channel) 的消费者。
void main() {
  /// 通道 → 该通道在源码里的取用写法（命中任一即算取用）。
  const Map<ShortcutChannel, List<String>> channelTokens =
      <ShortcutChannel, List<String>>{
    ShortcutChannel.keyboard: <String>['resolveKeyboard(', '.keyboardBindings'],
    ShortcutChannel.gamepad: <String>['resolveGamepad(', '.gamepadBindings'],
    ShortcutChannel.mouse: <String>['resolveMouse(', '.mouseBindings'],
    ShortcutChannel.wheel: <String>['resolveWheel(', '.wheelBindings'],
  };

  /// 定义/展示层：这些文件按定义列举所有 scope 与通道，不构成任何「消费」证据。
  /// 不排掉它们，每个 scope 的每个通道都会因为设置页而假绿。
  const List<String> definitionOnly = <String>[
    'lib/src/shortcuts/shortcut_action.dart',
    'lib/src/shortcuts/shortcut_defaults.dart',
    'lib/src/shortcuts/shortcut_registry.dart',
    'lib/src/shortcuts/input_binding.dart',
    'lib/src/shortcuts/shortcut_labels.dart',
    'lib/src/pages/implementations/shortcut_settings_page.dart',
    'lib/src/pages/implementations/shortcut_settings',
  ];

  /// 既有欠账：**开放了通道但至今没有消费者**的 (scope, channel)。
  ///
  /// 这些是本守卫落地之前就存在的，危害小于漫画那处——它们只是设置页多出一个空的
  /// 通道分组，**默认表里没有任何绑定**，所以不会出现「开箱就配好了却按不动」。
  /// 本清单是**棘轮**：下面断言的是「实际欠账集合 == 本清单」，因此
  ///   · 新增任何死通道 → 红（这正是漫画那处会被拦下的原因）；
  ///   · 接上某个通道后忘了从清单里划掉 → 也红，逼你把账销掉。
  /// 修的方向是二选一：要么接上解析入口，要么把该通道从 `scope.channels` 摘掉。
  const Set<String> knownUnconsumedChannels = <String>{
    // 视频页的鼠标绑定无人解析（`resolveMouse` 只有 reader / audiobook 两处）。
    'video.mouse',
    'home.mouse',
    'global.mouse',
    // gamepad scope 只装 dpad 四向，只经 GamepadService 的手柄通道消费。
    'gamepad.keyboard',
    'gamepad.mouse',
    // globalExternal 只把键盘绑定注册进 OS 级 hotkey_manager，另两个通道没有 OS
    // 级对应物。
    'globalExternal.gamepad',
    'globalExternal.mouse',
  };

  Map<ShortcutScope, List<ShortcutAction>> actionsByScope() {
    final Map<ShortcutScope, List<ShortcutAction>> byScope =
        <ShortcutScope, List<ShortcutAction>>{};
    for (final ShortcutAction action in ShortcutAction.values) {
      byScope.putIfAbsent(action.scope, () => <ShortcutAction>[]).add(action);
    }
    return byScope;
  }

  List<File> consumerFiles() {
    return Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .where((File f) {
      final String p = f.path.replaceAll('\\', '/');
      return !definitionOnly.any((String d) => p.startsWith(d));
    }).toList();
  }

  /// 实际存在消费者的 (scope, channel)。
  Set<String> consumedPairs() {
    final Map<ShortcutScope, List<ShortcutAction>> byScope = actionsByScope();
    final Set<String> consumed = <String>{};
    for (final File file in consumerFiles()) {
      final String source = file.readAsStringSync();
      for (final MapEntry<ShortcutScope, List<ShortcutAction>> entry
          in byScope.entries) {
        final bool identifiesScope =
            source.contains('ShortcutScope.${entry.key.name}') ||
                entry.value.any((ShortcutAction a) =>
                    source.contains('ShortcutAction.${a.name}'));
        if (!identifiesScope) continue;
        for (final MapEntry<ShortcutChannel, List<String>> ch
            in channelTokens.entries) {
          if (ch.value.any((String token) => source.contains(token))) {
            consumed.add('${entry.key.name}.${ch.key.name}');
          }
        }
      }
    }
    return consumed;
  }

  test('默认表里配了某通道的绑定 → 该通道必须开放且有解析入口（零豁免）', () {
    // 这是硬断言，没有豁免清单：**开箱就带着默认绑定**的通道，用户不做任何配置就
    // 会去按，按不动就是纯粹的谎报。漫画页的手柄绑定正是死在这一条上。
    final Set<String> consumed = consumedPairs();
    final List<String> violations = <String>[];
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      final Map<ShortcutAction, ShortcutBindingSet> table =
          ShortcutDefaults.forPlatform(platform);
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
          in table.entries) {
        final ShortcutScope scope = entry.key.scope;
        final Map<ShortcutChannel, bool> declared = <ShortcutChannel, bool>{
          ShortcutChannel.keyboard: entry.value.keyboardBindings.isNotEmpty,
          ShortcutChannel.gamepad: entry.value.gamepadBindings.isNotEmpty,
          ShortcutChannel.mouse: entry.value.mouseBindings.isNotEmpty,
          ShortcutChannel.wheel: entry.value.wheelBindings.isNotEmpty,
        };
        for (final MapEntry<ShortcutChannel, bool> ch in declared.entries) {
          if (!ch.value) continue;
          final String pair = '${scope.name}.${ch.key.name}';
          if (!scope.channels.contains(ch.key)) {
            violations.add('$platform ${entry.key.key}：默认表配了 '
                '${ch.key.name} 绑定，但 ${scope.name}.channels 没开放该通道');
          } else if (!consumed.contains(pair)) {
            violations.add('$platform ${entry.key.key}：默认表配了 '
                '${ch.key.name} 绑定，但全仓找不到 $pair 的解析入口'
                '（既无 resolve${ch.key.name} 也无 .${ch.key.name}Bindings 取用）');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '开箱即带默认绑定却无人解析 = 用户配了/直接按都没反应，'
          '比没有这个选项更糟。要么接上解析入口，要么把默认绑定和通道一起撤掉。'
          '命中：\n${violations.join('\n')}',
    );
  });

  test('开放但无人消费的通道集合 == 已登记的既有欠账（棘轮，只许缩不许涨）', () {
    final Set<String> consumed = consumedPairs();
    final Set<String> unconsumed = <String>{};
    for (final ShortcutScope scope in ShortcutScope.values) {
      for (final ShortcutChannel channel in scope.channels) {
        final String pair = '${scope.name}.${channel.name}';
        if (!consumed.contains(pair)) unconsumed.add(pair);
      }
    }

    final Set<String> newlyDead =
        unconsumed.difference(knownUnconsumedChannels);
    expect(
      newlyDead,
      isEmpty,
      reason: '新增了「设置页开放、却没有任何解析入口」的通道：$newlyDead。'
          '用户能在设置里配，按下去不会有任何反应。要么接上解析入口，'
          '要么别在 channels 里开放它。',
    );

    final Set<String> alreadyFixed =
        knownUnconsumedChannels.difference(unconsumed);
    expect(
      alreadyFixed,
      isEmpty,
      reason: '$alreadyFixed 已经有解析入口（或通道已摘掉），'
          '请从 knownUnconsumedChannels 里删掉，别让欠账清单虚高。',
    );
  });

  test('漫画 scope 只开放键盘，且默认表不含手柄绑定', () {
    // 回归钉：这三个 action 曾带着 RB/LB/dpad/B 默认绑定发出去，而漫画页没有任何
    // 手柄解析入口。要恢复必须先照 reader `_handleGamepadButton` 接上入口并真机验证。
    expect(ShortcutScope.manga.channels, <ShortcutChannel>{
      ShortcutChannel.keyboard,
    });
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      final Map<ShortcutAction, ShortcutBindingSet> table =
          ShortcutDefaults.forPlatform(platform);
      for (final ShortcutAction action in ShortcutAction.values
          .where((ShortcutAction a) => a.scope == ShortcutScope.manga)) {
        expect(table[action]!.gamepadBindings, isEmpty,
            reason: '$platform ${action.key} 不得有手柄默认绑定（漫画页没接手柄）');
        expect(table[action]!.keyboardBindings, isNotEmpty,
            reason: '$platform ${action.key} 必须有键盘默认绑定');
      }
    }
  });
}
