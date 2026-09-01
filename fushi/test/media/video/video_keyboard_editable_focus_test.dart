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
        videoNavigablePanelOpen: false,
      );

  final KeyDownEvent spaceDown =
      down(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
  final KeyRepeatEvent spaceRepeat =
      repeat(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
  final KeyDownEvent fDown =
      down(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
  final KeyRepeatEvent rightRepeat =
      repeat(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
  final KeyDownEvent enterDown =
      down(LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);
  final KeyDownEvent leftDown =
      down(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
  final KeyDownEvent downArrow =
      down(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
  const Set<ModifierKey> ctrl = <ModifierKey>{ModifierKey.ctrl};
  const Set<ModifierKey> shift = <ModifierKey>{ModifierKey.shift};
  const Set<ModifierKey> ctrlShift = <ModifierKey>{
    ModifierKey.ctrl,
    ModifierKey.shift,
  };

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

    test('Shift+字母（打大写）同样让位——Shift 不是硬修饰', () {
      expect(
        resolve(fDown, hasEditableFocus: true, modifiers: shift),
        VideoKeyboardResolution.ignored,
        reason: 'Shift+F 就是在打一个大写 F。把 Shift 当成「这不是文本输入」的信号，'
            '用户在弹幕规则框里打大写字母就会切全屏',
      );
    });

    test('Shift+方向键（扩选）让位', () {
      expect(
        resolve(downArrow, hasEditableFocus: true, modifiers: shift),
        VideoKeyboardResolution.ignored,
      );
    });
  });

  /// 统一修饰键模型：文本框与选词光标共用 [hasHardModifier]——宿主只认领**不带硬
  /// 修饰**的键。文本框比光标多一份 [isTextEditingCombination] 清单，那是宿主自身
  /// 能力的差异（文本框对 Ctrl+←/A/C/V 另有用途），不是第二套模型。
  group('文本框持焦 + 硬修饰：宿主用不上的组合交回视频通道', () {
    test('Ctrl+Enter 在侧栏搜索框里仍然制卡', () {
      expect(
        resolve(enterDown, hasEditableFocus: true, modifiers: ctrl),
        const VideoKeyboardResolution(
            VideoKeyboardDispatch.run, ShortcutAction.popupMineEntry),
        reason: '制卡是浮层的动作、文本框对 Ctrl+Enter 没有任何用途。一刀切让位整条'
            '通道时它直接死掉——查到词想制卡，光标恰好还在搜索框里就按不出来',
      );
    });

    test('Ctrl+F 在文本框里仍然打开字幕列表搜索', () {
      expect(
        resolve(fDown, hasEditableFocus: true, modifiers: ctrl).action,
        ShortcutAction.videoSearchSubtitleList,
      );
    });

    test('负向对照：Ctrl+← 仍归文本框（按词左移），不得变成「上一句字幕」', () {
      // 这条是整个模型的安全阀。`videoPreviousSubtitle` 的默认键就是 Ctrl+←，若判据
      // 简化成「有硬修饰就归视频」，用户在 mpv.conf 编辑框里按 Ctrl+← 就不再是按词
      // 移动光标而是跳字幕——旧实现里文本框根本够不到那张表，这会是**新造**的回归。
      expect(
        resolve(leftDown, hasEditableFocus: true, modifiers: ctrl),
        VideoKeyboardResolution.ignored,
      );
      expect(
        resolve(leftDown, hasEditableFocus: false, modifiers: ctrl).action,
        ShortcutAction.videoPreviousSubtitle,
        reason: '前置条件：没有文本框时 Ctrl+← 确实是个视频动作，上一条才有意义',
      );
    });

    test('负向对照：Ctrl+Shift+← 仍归文本框（按词扩选），不得变成字幕偏移对齐', () {
      expect(
        resolve(leftDown, hasEditableFocus: true, modifiers: ctrlShift),
        VideoKeyboardResolution.ignored,
      );
      expect(
        resolve(leftDown, hasEditableFocus: false, modifiers: ctrlShift).action,
        ShortcutAction.videoAlignSubtitleToPrev,
        reason: '前置条件：没有文本框时 Ctrl+Shift+← 确实是个视频动作',
      );
    });
  });

  group('修饰键模型的三个纯谓词', () {
    test('hasHardModifier：Ctrl/Alt/Meta 算，Shift 不算', () {
      expect(hasHardModifier(const <ModifierKey>{}), isFalse);
      expect(hasHardModifier(shift), isFalse,
          reason: 'Shift 是「同一个键的另一个字符」，不是命令修饰键');
      for (final ModifierKey m in const <ModifierKey>[
        ModifierKey.ctrl,
        ModifierKey.alt,
        ModifierKey.meta,
      ]) {
        expect(hasHardModifier(<ModifierKey>{m}), isTrue, reason: '$m 是硬修饰');
      }
      expect(hasHardModifier(ctrlShift), isTrue,
          reason: '混合修饰只要含一个硬修饰就算');
    });

    test('isTextEditingCombination：只认文本框自己也要用的那一小撮', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyY,
        LogicalKeyboardKey.keyZ,
      ]) {
        expect(isTextEditingCombination(key), isTrue,
            reason: '${key.keyLabel} 带 Ctrl/Meta 时是文本框的编辑动作');
      }
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.escape,
      ]) {
        expect(isTextEditingCombination(key), isFalse,
            reason: '${key.keyLabel} 带硬修饰时文本框没有用途，应交回视频通道');
      }
    });

    test('editableFocusClaimsKey：无硬修饰全认领，有硬修饰只认领编辑组合', () {
      expect(
        editableFocusClaimsKey(
            logicalKey: LogicalKeyboardKey.keyF,
            modifiers: const <ModifierKey>{}),
        isTrue,
      );
      expect(
        editableFocusClaimsKey(
            logicalKey: LogicalKeyboardKey.keyF, modifiers: shift),
        isTrue,
      );
      expect(
        editableFocusClaimsKey(
            logicalKey: LogicalKeyboardKey.keyF, modifiers: ctrl),
        isFalse,
      );
      expect(
        editableFocusClaimsKey(
            logicalKey: LogicalKeyboardKey.arrowLeft, modifiers: ctrl),
        isTrue,
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

    test('press-edge-only 动作的重复沿是不消费（与 swallowRepeat 是两种结论）', () {
      // 这批动作旧表就是 includeRepeats:false：放行给上层，不是吃掉。
      final KeyRepeatEvent bRepeat =
          repeat(LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB);
      expect(resolve(bRepeat, hasEditableFocus: false).action,
          isNull,
          reason: '长按 B 不该按 OS 重复率连翻字幕模糊');
      expect(resolve(bRepeat, hasEditableFocus: false),
          VideoKeyboardResolution.ignored,
          reason: '与 swallowRepeat 的区别是这次按键**不**被吃掉，继续冒泡');
      expect(
        resolve(down(LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB),
                hasEditableFocus: false)
            .action,
        ShortcutAction.videoToggleSubtitleBlur,
        reason: '前置条件：按下沿仍然照常翻，上一条才是「只吃重复沿」而不是「B 失效」',
      );
    });

    test('kVideoPressEdgeOnlyActions 的成员就是这 5 个（直测，不经 resolver）', () {
      // 只经 resolver 间接覆盖时，「集合里少一个动作」会退化成「那个动作的重复沿
      // 照常连发」——而连发本身是别的动作的正确行为，间接用例分不出来。
      expect(
        kVideoPressEdgeOnlyActions,
        <ShortcutAction>{
          ShortcutAction.videoToggleSubtitleBlur,
          ShortcutAction.videoCycleSubtitleObscure,
          ShortcutAction.videoToggleSubtitleHide,
          ShortcutAction.videoEnterCaret,
          ShortcutAction.popupMineEntry,
        },
        reason: '按一下翻一次的动作（模糊 / 遮蔽循环 / 隐藏 / 进选词光标 / 制卡）'
            '——长按不该连发查词、更不该连发制卡',
      );
      // 连续型动作绝不能混进来：混进去 = 长按方向键不能连续快进 / 长按不能持续调音量。
      for (final ShortcutAction continuous in <ShortcutAction>[
        ShortcutAction.videoSeekForward,
        ShortcutAction.videoSeekBackward,
        ShortcutAction.videoVolumeUp,
        ShortcutAction.videoVolumeDown,
        ShortcutAction.videoPreviousFrame,
        ShortcutAction.videoNextFrame,
      ]) {
        expect(kVideoPressEdgeOnlyActions.contains(continuous), isFalse,
            reason: '$continuous 是连续型动作，进了这个集合就是把长按连发删掉');
      }
    });
  });
}
