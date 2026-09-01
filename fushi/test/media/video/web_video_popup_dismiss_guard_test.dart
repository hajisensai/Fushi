import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';

import '../../helpers/source_guard.dart';

/// BUG-924 在**网页视频页**那一半的守卫：[guardVideoShortcutsWithPopupDismiss]。
///
/// 原生视频页已经改成页级 press-time 单通道（[resolveVideoKeyboardShortcut]，覆盖在
/// `video_popup_dismiss_guard_test.dart`），但 `web_video_fushi_page.dart` 仍持有一张
/// 短生命周期的 [CallbackShortcuts] 表，`_keyboardShortcuts()` 就是
/// `guardVideoShortcutsWithPopupDismiss(buildVideoPlayerShortcutsFromRegistry(...))`。
/// 迁移那一轮把这个包装器的 4 条用例整体改写成了新 resolver 的用例，于是这条路径
/// **一条覆盖都不剩**——函数还活着、还在生产里被调，却没有任何东西钉住它。
///
/// 本文件按网页视频页的**实际契约**写，不照抄原生页语义。两处有意的不同：
/// ① **没有制卡豁免**。原生通道要给 `popupMineEntry` 开后门（浮层可见时按 Ctrl+Enter
///    是制卡，不是关浮层）；而网页页那张表是 [videoActionCallbacks] 的产物，
///    `popupMineEntry` 属 dictionaryPopup scope、根本不在里面，没有键需要豁免。
/// ② **只作用于表里已有的键**。未绑定的键压根不进表，不存在「误吞导航键」的形态，
///    所以这里断言的是「键集合不增不减」而不是「未绑定的键放行」。
void main() {
  const ShortcutActivator seekForward =
      SingleActivator(LogicalKeyboardKey.keyD);
  const ShortcutActivator escape = SingleActivator(LogicalKeyboardKey.escape);
  const ShortcutActivator space = SingleActivator(LogicalKeyboardKey.space);

  /// 与 `buildVideoPlayerShortcutsFromRegistry` 的产物同形状
  /// （`Map<ShortcutActivator, VoidCallback>`）的最小替身。
  Map<ShortcutActivator, VoidCallback> baseMap(List<String> log) {
    return <ShortcutActivator, VoidCallback>{
      seekForward: () => log.add('seekForward'),
      escape: () => log.add('escape'),
      space: () => log.add('togglePlayPause'),
    };
  }

  test('浮层可见：任一键先关浮层、不跑原动作', () {
    final List<String> actions = <String>[];
    final List<String> dismisses = <String>[];
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      baseMap(actions),
      isPopupVisible: () => true,
      dismissPopup: () => dismisses.add('dismiss'),
    );

    guarded[seekForward]!();
    guarded[escape]!();
    guarded[space]!();

    expect(actions, isEmpty,
        reason: '浮层开着按 d 竟然快进 / 按空格竟然暂停后台视频，正是 BUG-924 的症状');
    expect(dismisses, <String>['dismiss', 'dismiss', 'dismiss'],
        reason: '每次按键关一层浮层');
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
        reason: '没有浮层时快捷键必须保持原行为——把它们无条件吞掉等于把网页视频页的'
            '快捷键整表删了');
    expect(dismisses, isEmpty, reason: '没有浮层就不该调关闭');
  });

  test('浮层可见性每次按键实时求值（不在建表时冻结）', () {
    final List<String> actions = <String>[];
    bool visible = true;
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      baseMap(actions),
      isPopupVisible: () => visible,
      dismissPopup: () {},
    );

    guarded[seekForward]!();
    expect(actions, isEmpty, reason: '第一次按 d：浮层还开着 → 关浮层');

    visible = false;
    guarded[seekForward]!();
    expect(actions, <String>['seekForward'],
        reason: '浮层关掉后同一个键必须恢复原动作。谓词若在建表时求过一次值就冻住，'
            '网页视频页的表是随 build 重建的短生命周期表，症状会退化成随机时灵时不灵');
  });

  test('键集合不增不减：包装器只换执行体，不动 activator', () {
    final Map<ShortcutActivator, VoidCallback> base = baseMap(<String>[]);
    final Map<ShortcutActivator, VoidCallback> guarded =
        guardVideoShortcutsWithPopupDismiss(
      base,
      isPopupVisible: () => false,
      dismissPopup: () {},
    );
    expect(guarded.keys.toSet(), base.keys.toSet(),
        reason: '少一个键 = 那个快捷键在网页视频页失效；多一个键 = 凭空吞掉一个'
            '本该冒泡的按键');
  });

  test('网页视频页确实还在用这个包装器（否则上面四条守的是死代码）', () {
    // 这个函数在原生视频页已经下岗，唯一的生产消费者就是网页视频页的
    // `_keyboardShortcuts()`。它一旦也改走 press-time 通道，本文件应当整体删除，
    // 而不是留着守一段没人调的代码。
    final String page = File(
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ).readAsStringSync();
    const String signature =
        'Map<ShortcutActivator, VoidCallback> _keyboardShortcuts()';
    final String body = methodBody(page, signature);
    expect(containsIdentifierCall(body, 'guardVideoShortcutsWithPopupDismiss'),
        isTrue,
        reason: '网页视频页的快捷键表必须仍经 guardVideoShortcutsWithPopupDismiss 包一层，'
            '否则浮层开着按键会穿透去控制后面的视频（BUG-924 在网页页复发）');
    expect(
        containsIdentifierCall(body, 'buildVideoPlayerShortcutsFromRegistry'),
        isTrue,
        reason: '被包的必须是注册表产物，改键才生效');
  });
}
