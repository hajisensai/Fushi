import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_shortcuts.dart';

/// BUG-922 守卫测试：词典浮层可见时，任一视频快捷键先关顶层浮层并**不**跑原动作；浮层
/// 不可见时原动作照跑一次。这是「视频里关不掉词典 / 浮层开着按 d 竟然快进」的根因守卫
/// （对齐阅读器：浮层可见时导航键先关浮层）。测纯函数 [guardVideoShortcutsWithPopupDismiss]，
/// 与页面 / media_kit / 具体键位解绑，不随视频动作增删而脆化。
void main() {
  const ShortcutActivator seekForward =
      SingleActivator(LogicalKeyboardKey.keyD);
  const ShortcutActivator escape = SingleActivator(LogicalKeyboardKey.escape);
  const ShortcutActivator space = SingleActivator(LogicalKeyboardKey.space);

  /// 造一张「动作名 → 记录到 log」的快捷键表，模拟 buildVideoPlayerShortcutsFromRegistry
  /// 的产物形状（Map<ShortcutActivator, VoidCallback>）。
  Map<ShortcutActivator, VoidCallback> baseMap(List<String> log) {
    return <ShortcutActivator, VoidCallback>{
      seekForward: () => log.add('seekForward'),
      escape: () => log.add('escape'),
      space: () => log.add('togglePlayPause'),
    };
  }

  test('浮层可见：任一键先关浮层、消费掉、不跑原动作', () {
    final List<String> actions = <String>[];
    final List<String> dismisses = <String>[];
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      baseMap(actions),
      isPopupVisible: () => true,
      dismissPopup: () => dismisses.add('dismiss'),
    );

    // d（快进）：浮层开着时应关浮层，不快进。
    guarded[seekForward]!();
    // Esc：同样先关浮层。
    guarded[escape]!();
    // 裸空格语义键：同样先关浮层，不 play/pause。
    guarded[space]!();

    expect(actions, isEmpty, reason: '浮层可见时原视频动作一次都不该跑');
    expect(dismisses, <String>['dismiss', 'dismiss', 'dismiss'],
        reason: '每次按键都关一层浮层');
  });

  test('浮层不可见：原动作照跑一次、不关浮层', () {
    final List<String> actions = <String>[];
    final List<String> dismisses = <String>[];
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      baseMap(actions),
      isPopupVisible: () => false,
      dismissPopup: () => dismisses.add('dismiss'),
    );

    guarded[seekForward]!();
    guarded[escape]!();
    guarded[space]!();

    expect(actions, <String>['seekForward', 'escape', 'togglePlayPause'],
        reason: '浮层不可见时快捷键保持原行为');
    expect(dismisses, isEmpty, reason: '没有浮层就不该调关闭');
  });

  test('浮层可见性是每次按键实时求值（谁先谁后不缓存）', () {
    final List<String> actions = <String>[];
    bool visible = true;
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      baseMap(actions),
      isPopupVisible: () => visible,
      dismissPopup: () {},
    );

    // 第一次按 d：浮层还开着 → 关浮层（记为已关，翻转谓词）。
    guarded[seekForward]!();
    expect(actions, isEmpty);

    // 浮层已关，再按 d → 这次真快进。
    visible = false;
    guarded[seekForward]!();
    expect(actions, <String>['seekForward'], reason: '浮层关掉后同一个键恢复原动作');
  });

  test('守卫保留原表的键集合，不增删 activator', () {
    final Map<ShortcutActivator, VoidCallback> base = baseMap(<String>[]);
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      base,
      isPopupVisible: () => false,
      dismissPopup: () {},
    );
    expect(guarded.keys.toSet(), base.keys.toSet());
  });
}
