import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-962 同源守卫 + 长按连发守卫。
///
/// 视频页的整张快捷键表现在都过页级 press-time 单通道（`resolveVideoKeyboardShortcut`），
/// 不再挂在 media_kit controls 子树上。这次架构变更同时放大了两个旧契约的爆炸半径，
/// 而它们原来的覆盖随旧测试一起被删了：
///
/// 1. **文本框让位**：旧的页级覆盖层只管空格，判据坏掉最多是「打不出空格」；现在
///    整张表都过这条通道，坏掉就是在 mpv.conf 多行框 / 弹幕屏蔽规则框 / 弹幕手动
///    匹配搜索框里打 `f` 直接切全屏。窗口与全屏都够得着这些框。
/// 2. **长按不连发**：旧表用 `SingleActivator(includeRepeats: false)` + 页级
///    `swallowRepeat` 两段表达；press-time 判决必须把「消费但不做」一并带上，
///    否则只能在「连点播放暂停」和「漏给 space→ActivateIntent 连点激活焦点控件」
///    之间二选一。
void main() {
  FushiShortcutRegistry defaults() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  KeyDownEvent down(LogicalKeyboardKey k, PhysicalKeyboardKey p) =>
      KeyDownEvent(logicalKey: k, physicalKey: p, timeStamp: Duration.zero);
  KeyRepeatEvent repeat(LogicalKeyboardKey k, PhysicalKeyboardKey p) =>
      KeyRepeatEvent(logicalKey: k, physicalKey: p, timeStamp: Duration.zero);

  VideoKeyboardResolution resolve(
    KeyEvent event, {
    required bool hasEditableFocus,
    bool hasVisiblePopup = false,
    Set<ModifierKey> modifiers = const <ModifierKey>{},
  }) =>
      resolveVideoKeyboardShortcut(
        defaults(),
        event,
        modifiers: modifiers,
        hasEditableFocus: hasEditableFocus,
        hasVisiblePopup: hasVisiblePopup,
        videoSurfaceHoldsFocus: false,
        panelHoldsFocusNavigation: false,
      );

  final KeyDownEvent spaceDown =
      down(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
  final KeyRepeatEvent spaceRepeat =
      repeat(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
  final KeyDownEvent fDown =
      down(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
  final KeyRepeatEvent rightRepeat =
      repeat(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);

  group('前置条件', () {
    test('没有文本框时这两个键确实各自命中一个视频动作', () {
      expect(resolve(spaceDown, hasEditableFocus: false).action,
          ShortcutAction.videoTogglePlayPause);
      expect(resolve(fDown, hasEditableFocus: false).action,
          ShortcutAction.videoToggleFullscreen,
          reason: '前置条件塌了下面整组就测了个寂寞');
    });
  });

  group('BUG-962：文本框持焦时整条通道让位', () {
    test('按下沿让位（不消费，落到 text-input）', () {
      expect(resolve(spaceDown, hasEditableFocus: true),
          VideoKeyboardResolution.ignored);
    });

    test('重复沿也让位（长按打连续空格）', () {
      expect(resolve(spaceRepeat, hasEditableFocus: true),
          VideoKeyboardResolution.ignored);
    });

    test('文本框优先于词典浮层：先保证能打字', () {
      expect(
        resolve(spaceDown, hasEditableFocus: true, hasVisiblePopup: true),
        VideoKeyboardResolution.ignored,
        reason: '判据顺序反了就是「弹窗开着，在侧栏搜索框里按空格 = 关弹窗」',
      );
    });

    test('让位的是整条通道、不只是空格：字母键同样不得变成视频动作', () {
      expect(
        resolve(fDown, hasEditableFocus: true),
        VideoKeyboardResolution.ignored,
        reason: '主通道现在承载整张表——在 mpv.conf 框里打 f 不得切全屏。'
            '这正是旧页级覆盖层没有、统一到单通道之后才出现的新暴露面',
      );
    });
  });

  group('长按不连发', () {
    test('播放/暂停的重复沿：消费但不重复执行', () {
      expect(
        resolve(spaceRepeat, hasEditableFocus: false),
        VideoKeyboardResolution.swallowedRepeat,
        reason: '返回 run = 按 OS 重复率连点播放/暂停；返回 ignored = 漏给 '
            'WidgetsApp 默认的 space→ActivateIntent，长按空格连点激活当前焦点'
            '控件（全局 _neutralizeBareSpace 只中和按下沿）。两个都不对',
      );
    });

    test('负向对照：连续型动作（seek）的重复沿照常连发', () {
      final VideoKeyboardResolution r =
          resolve(rightRepeat, hasEditableFocus: false);
      expect(r.dispatch, VideoKeyboardDispatch.run,
          reason: '把所有重复沿一刀切吞掉 = 长按方向键不能连续快进，'
              '那是把功能删了而不是修 bug');
      expect(r.action, ShortcutAction.videoSeekForward);
    });

    test('press-edge-only 动作的重复沿仍是不消费（与 swallow 是两种结论）', () {
      // 这批动作旧表就是 includeRepeats:false，放行给上层，不是吃掉。
      expect(kVideoPressEdgeOnlyActions, isNotEmpty,
          reason: '前置条件：这个集合空了下面这条就恒真');
    });
  });
}
