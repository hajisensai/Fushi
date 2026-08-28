import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart' show ModifierKey;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-924 守卫测试：词典浮层可见时，任一视频快捷键先关顶层浮层并**不**跑原动作；浮层
/// 不可见时原动作照跑。这是「视频里关不掉词典 / 浮层开着按 d 竟然快进」的根因守卫
/// （对齐阅读器：浮层可见时导航键先关浮层）。
///
/// 方案 D 之后这条语义住在 press-time 判决 [resolveVideoKeyboardShortcut] 里，不再是
/// 套在 activator 表外面的一层包装，所以本测试直接喂真 [KeyEvent] + 真注册表默认绑定：
/// 判据与页面 / media_kit 解绑，但键位来自真相源，改默认键会被这里发现。
void main() {
  FushiShortcutRegistry defaults() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  KeyDownEvent down(LogicalKeyboardKey key, PhysicalKeyboardKey physical) =>
      KeyDownEvent(
        logicalKey: key,
        physicalKey: physical,
        timeStamp: Duration.zero,
      );

  VideoKeyboardResolution resolve(
    FushiShortcutRegistry registry,
    KeyEvent event, {
    required bool hasVisiblePopup,
    Set<ModifierKey> modifiers = const <ModifierKey>{},
  }) {
    return resolveVideoKeyboardShortcut(
      registry,
      event,
      modifiers: modifiers,
      hasEditableFocus: false,
      hasVisiblePopup: hasVisiblePopup,
      // 画面持焦：让 videoEnterCaret 那条 contextual 判据不干扰本组的浮层语义。
      videoSurfaceHoldsFocus: true,
      panelHoldsFocusNavigation: false,
    );
  }

  final KeyDownEvent seekForward =
      down(LogicalKeyboardKey.keyD, PhysicalKeyboardKey.keyD);
  final KeyDownEvent escape =
      down(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  final KeyDownEvent space =
      down(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);

  test('前置条件：这三个键在默认绑定里确实各自映射到一个视频动作', () {
    final FushiShortcutRegistry registry = defaults();
    expect(
      <VideoKeyboardResolution>[
        resolve(registry, seekForward, hasVisiblePopup: false),
        resolve(registry, escape, hasVisiblePopup: false),
        resolve(registry, space, hasVisiblePopup: false),
      ],
      <VideoKeyboardResolution>[
        const VideoKeyboardResolution(
            VideoKeyboardDispatch.run, ShortcutAction.videoSeekForward),
        // Esc 属 universal scope，主通道靠 video → universal 两段式兜底拿到它，
        // 与手柄通道 resolveGamepad 的兜底逐字对应。
        const VideoKeyboardResolution(
            VideoKeyboardDispatch.run, ShortcutAction.globalBack),
        const VideoKeyboardResolution(
            VideoKeyboardDispatch.run, ShortcutAction.videoTogglePlayPause),
      ],
      reason: '默认键位变了本组就测不到东西了，先把前提钉死',
    );
  });

  test('浮层可见：任一键判成关浮层、消费掉、不跑原动作', () {
    final FushiShortcutRegistry registry = defaults();
    for (final KeyDownEvent event
        in <KeyDownEvent>[seekForward, escape, space]) {
      expect(
        resolve(registry, event, hasVisiblePopup: true),
        VideoKeyboardResolution.dismissPopup,
        reason: '浮层可见时 ${event.logicalKey.keyLabel} 必须先关一层浮层，'
            '不得穿透去控制后面的视频',
      );
    }
  });

  test('未绑定的键即使浮层可见也不消费（不误吞导航）', () {
    final FushiShortcutRegistry registry = defaults();
    // Tab 不是任何视频/universal 动作的绑定键：浮层可见也必须放行给焦点遍历。
    expect(
      resolve(
        registry,
        down(LogicalKeyboardKey.tab, PhysicalKeyboardKey.tab),
        hasVisiblePopup: true,
      ),
      VideoKeyboardResolution.ignored,
      reason: '「先关浮层」只作用于已绑定的视频键，未绑定的键不该被吞',
    );
  });

  test('制卡键必须绕开「先关浮层」——否则按下去只会把浮层关掉，永远制不了卡', () {
    final FushiShortcutRegistry registry = defaults();
    final KeyDownEvent ctrlEnter =
        down(LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);
    expect(
      resolve(
        registry,
        ctrlEnter,
        hasVisiblePopup: true,
        modifiers: const <ModifierKey>{ModifierKey.ctrl},
      ),
      const VideoKeyboardResolution(
          VideoKeyboardDispatch.run, ShortcutAction.popupMineEntry),
      reason: '制卡恰恰只在浮层可见时才有意义（旧实现靠「合并在守卫之后」达到同样效果）',
    );
  });

  test('浮层可见性每次按键实时求值：同一事件两种页面态判决不同', () {
    final FushiShortcutRegistry registry = defaults();
    expect(
      resolve(registry, seekForward, hasVisiblePopup: true),
      VideoKeyboardResolution.dismissPopup,
    );
    expect(
      resolve(registry, seekForward, hasVisiblePopup: false),
      const VideoKeyboardResolution(
          VideoKeyboardDispatch.run, ShortcutAction.videoSeekForward),
      reason: '浮层关掉后同一个键恢复原动作（press-time 解析天然不缓存页面态）',
    );
  });
}
