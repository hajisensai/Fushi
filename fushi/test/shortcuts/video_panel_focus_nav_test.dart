import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// 手柄重设计 P3：视频浮层面板的焦点导航让位（分类器 + 接线源码守卫）。
///
/// 手柄侧 [isVideoPanelFocusNavButton] 与键盘侧 [isVideoPanelFocusNavKey] 是同一条
/// 语义的两个投影，两边都要有**直测**：只靠 `resolveVideoKeyboardShortcut` 间接覆盖
/// 的话，分类器少认一个键 / 多认一个键都可能被上层别的判据（未绑定 → ignored）掩盖成
/// 同一个结论。
void main() {
  group('isVideoPanelFocusNavButton', () {
    test('dpad 四向 + A 让位给焦点导航', () {
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.dpadUp,
        GamepadButton.dpadDown,
        GamepadButton.dpadLeft,
        GamepadButton.dpadRight,
        GamepadButton.a,
      ]) {
        expect(isVideoPanelFocusNavButton(button), isTrue,
            reason: '${button.label} 应在面板打开时让位');
      }
    });

    test('播放控制按钮不让位（LB/RB seek、B 退出阶梯、X/Y 字幕句在面板开着时仍可用）', () {
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rb,
        GamepadButton.lt,
        GamepadButton.rt,
        GamepadButton.b,
        GamepadButton.x,
        GamepadButton.y,
        GamepadButton.start,
        GamepadButton.select,
        GamepadButton.thumbLeft,
        GamepadButton.thumbRight,
      ]) {
        expect(isVideoPanelFocusNavButton(button), isFalse,
            reason: '${button.label} 不该被面板抢走');
      }
    });
  });

  group('isVideoPanelFocusNavKey（[isVideoPanelFocusNavButton] 的键盘对应物）', () {
    test('四向方向键让位给焦点遍历', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(isVideoPanelFocusNavKey(key), isTrue,
            reason: '${key.keyLabel} 应在面板持焦时让位给焦点遍历');
      }
    });

    test('确认 / 翻页 / 播放控制键不让位', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        // Enter 绑着 videoEnterCaret，由「画面精确持焦才算选词键」那条 contextual
        // 判据天然让位，不在本分类器里重复列一遍（列进来 = 两处真相源）。
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyF,
      ]) {
        expect(isVideoPanelFocusNavKey(key), isFalse,
            reason: '${key.keyLabel} 不该被面板抢走——面板开着时 L / F / 空格等'
                '仍是视频动作');
      }
    });
  });

  group('面板让位的两个前提（判据由 resolveVideoKeyboardShortcut 施加）', () {
    FushiShortcutRegistry defaults() =>
        FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    VideoKeyboardResolution resolve(
      LogicalKeyboardKey key,
      PhysicalKeyboardKey physical, {
      required bool videoNavigablePanelOpen,
      required bool videoSurfaceHoldsFocus,
      Set<ModifierKey> modifiers = const <ModifierKey>{},
      FushiShortcutRegistry? registry,
    }) {
      return resolveVideoKeyboardShortcut(
        registry ?? defaults(),
        KeyDownEvent(
          logicalKey: key,
          physicalKey: physical,
          timeStamp: Duration.zero,
        ),
        modifiers: modifiers,
        hasEditableFocus: false,
        hasVisiblePopup: false,
        videoSurfaceHoldsFocus: videoSurfaceHoldsFocus,
        videoNavigablePanelOpen: videoNavigablePanelOpen,
      );
    }

    test('前置条件：裸 ↓ 在没有面板时是 videoVolumeDown', () {
      expect(
        resolve(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown,
                videoNavigablePanelOpen: false, videoSurfaceHoldsFocus: false)
            .action,
        ShortcutAction.videoVolumeDown,
        reason: '前置条件塌了下面几条就测了个寂寞',
      );
    });

    test('面板开着 + 焦点已不在画面上 → 裸 ↓ 让位', () {
      expect(
        resolve(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown,
            videoNavigablePanelOpen: true, videoSurfaceHoldsFocus: false),
        VideoKeyboardResolution.ignored,
      );
    });

    test('面板开着但画面仍持焦 → 裸 ↓ 照常调音量（不静默失效）', () {
      // 让位的**理由**是「焦点在面板里、方向键此刻是在面板内选行」。今天这个前提由
      // 页面的 `_canOwnVideoFocus`（面板打开就不抢焦）间接成立，那是另一个模块的门控
      // ——它一改，面板开着而焦点仍在画面上时裸方向键就既不移焦也不 seek，静默失效
      // 且没有任何报错。判据必须把前提就地判掉，不能靠远程不变式。
      expect(
        resolve(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown,
                videoNavigablePanelOpen: true, videoSurfaceHoldsFocus: true)
            .action,
        ShortcutAction.videoVolumeDown,
      );
    });

    test('硬修饰组合不让位：Ctrl+← 在面板持焦时仍是「上一句字幕」', () {
      expect(
        resolve(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft,
                videoNavigablePanelOpen: true,
                videoSurfaceHoldsFocus: false,
                modifiers: const <ModifierKey>{ModifierKey.ctrl})
            .action,
        ShortcutAction.videoPreviousSubtitle,
        reason: 'Ctrl+←/→ 是明确的视频动作，面板开着时照常执行',
      );
    });

    test('Shift 不算硬修饰：Shift+↓ 在面板持焦时仍让位（列表里那是扩选）', () {
      // 旧判据是 `modifiers.isEmpty`，于是 Shift+↓ 会掉进注册表解析——与 caret 那侧
      // 「只有 Ctrl/Alt/Meta 才算硬修饰」的模型不一致。两处现在共用 hasHardModifier。
      //
      // ⚠️ 判据必须**能分辨两种模型**：默认表里 Shift+↓ 没有任何绑定，于是两种模型都
      // 落到 `ignored`——用默认表写这条断言是同义反复（变异实测：把判据换回
      // `modifiers.isEmpty` 仍然全绿）。所以这里显式把 Shift+↓ 绑成一个视频动作
      // （用户在快捷键设置里完全做得到），让「让位」与「解析成动作」成为两个不同答案。
      final FushiShortcutRegistry rebound = defaults();
      rebound.updateBinding(
        ShortcutAction.videoVolumeDown,
        ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            ...rebound
                .bindingsFor(ShortcutAction.videoVolumeDown)
                .keyboardBindings,
            const InputBinding(
              key: LogicalKeyboardKey.arrowDown,
              modifiers: <ModifierKey>{ModifierKey.shift},
            ),
          ],
        ),
      );
      expect(
        resolve(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown,
                videoNavigablePanelOpen: false,
                videoSurfaceHoldsFocus: false,
                modifiers: const <ModifierKey>{ModifierKey.shift},
                registry: rebound)
            .action,
        ShortcutAction.videoVolumeDown,
        reason: '前置条件：改键之后 Shift+↓ 确实是个视频动作，下一条才有分辨力',
      );
      expect(
        resolve(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown,
            videoNavigablePanelOpen: true,
            videoSurfaceHoldsFocus: false,
            modifiers: const <ModifierKey>{ModifierKey.shift},
            registry: rebound),
        VideoKeyboardResolution.ignored,
        reason: '面板持焦时 Shift+方向键在列表里是扩选，仍归焦点遍历；'
            '判据退回 modifiers.isEmpty 就会在这里改调音量',
      );
    });
  });

  group('接线源码守卫（分类器单测抓不到「闸门被删」）', () {
    test('视频手柄处理器在注册表解析之前放行面板焦点导航按钮', () {
      final String code = maskComments(
          File('lib/src/pages/implementations/video_fushi_page.dart')
              .readAsStringSync());
      expect(
        code.contains(
            'if (_videoNavigablePanelOpen && isVideoPanelFocusNavButton(button)) {'),
        isTrue,
        reason: '闸门缺席：面板打开时 D-pad 仍会被解析成音量/seek，手柄进不了面板',
      );
    });

    test('三类面板都包了 PanelFocusScope（焦点领进面板的唯一入口）', () {
      const Map<String, String> panels = <String, String>{
        'lib/src/pages/implementations/video_fushi/episode.part.dart': '剧集轨',
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart': '字幕列表',
        'lib/src/pages/implementations/video_fushi/side_panel.part.dart': '侧栏',
      };
      panels.forEach((String path, String label) {
        final String code = maskComments(File(path).readAsStringSync());
        expect(code.contains('PanelFocusScope('), isTrue,
            reason: '$label（$path）没包 PanelFocusScope：打开后焦点留在页面节点，'
                'D-pad 让位了也没有可移动的焦点');
      });
    });
  });
}
