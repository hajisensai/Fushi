import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-697（TODO-1378）：视频**全屏路由**内手柄只有 B（返回）可用，A / D-pad 静默
/// no-op；窗口模式一切正常。
///
/// 根因：全屏是推到根 navigator 的独立 [PageRouteBuilder]（fullscreen.part.dart），
/// 窗口侧 build() 最外层的手柄输入层 _wrapVideoGamepadControls
/// （Actions<GamepadButtonIntent> + 旁观 Focus）不是这棵子树的祖先。桌面手柄轮询
/// （gamepad_service）以 primaryFocus.context 为派发起点，进全屏后共享
/// _videoFocusNode 被全屏侧 controls 持有——[Actions.maybeInvoke] 沿全屏子树的
/// 元素树向上找不到任何 [GamepadButtonIntent] 处理器：
///   * A → 落进 service 的 [ActivateIntent] 兜底，视频焦点节点无 activate 语义 → 无声；
///   * D-pad → 落进方向焦点遍历兜底，子树内没有可聚焦兄弟 → 无声；
///   * B → 走 navigatorKey.maybePop 全局返回兜底（与焦点树无关）→ 唯一活着的键。
///
/// 修复 = 全屏路由 pageBuilder 的内容包进与窗口模式**同一个**
/// _wrapVideoGamepadControls（见 fullscreen.part.dart，接线由
/// video_fullscreen_gamepad_wiring_static_test.dart 源码守卫锁定）。
///
/// 真实 VideoHibikiPage 无法 headless 加载（media_kit 测试宿主无 libmpv），本文件
/// 沿 video_fullscreen_focus_gate_test.dart 的既定范式，在与页面逐行同构的 harness 上
/// 验证机制本身——所有关键件都用真实实现：真实 [FushiShortcutRegistry]（Windows
/// 默认表）、真实 [videoActionCallbacks] / [VideoPlayerShortcutActions]、真实
/// [dispatchGamepadButtonIntent] / [gamepadMoveFocusInDirection]，service 的
/// 分发决策树按 gamepad_service._dispatchButton 逐分支镜像（私有，无法直接调用）。
void main() {
  testWidgets('修前形态复现：裸全屏路由内 A/D-pad 静默 no-op、仅 B 兜底返回可用',
      (WidgetTester tester) async {
    final _Rig rig = _Rig();
    await rig.pump(tester);

    // 基线：窗口模式 A = 播放/暂停（GamepadButtonIntent 被页面 Actions 消费）。
    expect(rig.dispatchLikeService(GamepadButton.a), isTrue);
    expect(rig.counts[ShortcutAction.videoTogglePlayPause], 1);

    // 进全屏（修前形状：裸路由，不包手柄输入层）。
    rig.state.enterFullscreen(wrapped: false);
    await tester.pumpAndSettle();
    expect(rig.videoNode.hasPrimaryFocus, isTrue,
        reason: '进全屏后共享焦点节点应被全屏侧持有（页面 post-frame 焦点回收同构）');

    // A：GamepadButtonIntent 无人消费 → ActivateIntent 兜底也无语义 → 静默 no-op。
    expect(rig.dispatchLikeService(GamepadButton.a), isFalse,
        reason: '裸全屏子树没有 GamepadButtonIntent 处理器，A 必须落空（BUG-697 复现）');
    expect(rig.counts[ShortcutAction.videoTogglePlayPause], 1,
        reason: '播放/暂停不得被触发——这正是用户看到的「A 键死了」');

    // D-pad：焦点遍历兜底在无可聚焦兄弟的子树里也是 no-op。
    expect(rig.dispatchLikeService(GamepadButton.dpadRight), isFalse);
    expect(rig.counts[ShortcutAction.videoSeekForward], 0,
        reason: 'D-pad 快进不得被触发（BUG-697 复现）');
    expect(rig.videoNode.hasPrimaryFocus, isTrue, reason: '焦点遍历兜底应原地不动（无处可去）');

    // B：navigatorKey.maybePop 兜底与焦点树无关 → 唯一活着的键，退出全屏。
    expect(rig.dispatchLikeService(GamepadButton.b), isFalse,
        reason: 'B 未被页面消费（返回 false），但兜底 maybePop 已生效');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowed-controls')), findsOneWidget,
        reason: 'B 的全局返回兜底必须始终可用（修前唯一退出手段）');
  });

  testWidgets('修后形态：全屏路由包同一手柄输入层 → A/D-pad 恢复窗口模式语义、B 走 globalBack',
      (WidgetTester tester) async {
    final _Rig rig = _Rig();
    await rig.pump(tester);

    // 进全屏（修后形状：与 fullscreen.part.dart 相同，内容包 _wrapVideoGamepadControls）。
    rig.state.enterFullscreen(wrapped: true);
    await tester.pumpAndSettle();
    expect(rig.videoNode.hasPrimaryFocus, isTrue);

    // A = 播放/暂停（与窗口模式同一注册表解析、同一执行体）。
    expect(rig.dispatchLikeService(GamepadButton.a), isTrue,
        reason: '全屏子树现在有 GamepadButtonIntent 处理器，A 必须被消费');
    expect(rig.counts[ShortcutAction.videoTogglePlayPause], 1);

    // D-pad 左右 = 快退/快进，上下 = 音量（video scope 默认映射，TODO-1342 键位表）。
    expect(rig.dispatchLikeService(GamepadButton.dpadRight), isTrue);
    expect(rig.counts[ShortcutAction.videoSeekForward], 1);
    expect(rig.dispatchLikeService(GamepadButton.dpadLeft), isTrue);
    expect(rig.counts[ShortcutAction.videoSeekBackward], 1);
    expect(rig.dispatchLikeService(GamepadButton.dpadUp), isTrue);
    expect(rig.counts[ShortcutAction.videoVolumeUp], 1);
    expect(rig.dispatchLikeService(GamepadButton.dpadDown), isTrue);
    expect(rig.counts[ShortcutAction.videoVolumeDown], 1);

    // B = globalBack「返回上一级」（页面消费，逐级退出；harness 的 escape 同构
    // _exitVideoFullscreen：关全屏路由）。B 返回依旧可用，且升级为页面语义。
    expect(rig.dispatchLikeService(GamepadButton.b), isTrue,
        reason: 'B 现在被页面 globalBack 消费（不再依赖裸 maybePop 兜底）');
    expect(rig.counts[ShortcutAction.globalBack], 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowed-controls')), findsOneWidget,
        reason: 'globalBack 在全屏态必须退出全屏（B 返回始终可用）');
  });
}

/// 组装一套与视频页手柄接线逐行同构的最小台架：真实注册表 + 真实动作回调表 +
/// 真实 intent 派发；[counts] 记录每个被触发的 video 动作次数。
class _Rig {
  _Rig()
      : registry = FushiShortcutRegistry()
          ..loadDefaults(TargetPlatform.windows);

  final FushiShortcutRegistry registry;
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  final FocusNode videoNode = FocusNode(debugLabel: 'videoKeyboard');
  final Map<ShortcutAction, int> counts = <ShortcutAction, int>{
    ShortcutAction.videoTogglePlayPause: 0,
    ShortcutAction.videoSeekBackward: 0,
    ShortcutAction.videoSeekForward: 0,
    ShortcutAction.videoVolumeUp: 0,
    ShortcutAction.videoVolumeDown: 0,
    ShortcutAction.globalBack: 0,
  };

  late final _HarnessState state;

  Future<void> pump(WidgetTester tester) async {
    addTearDown(videoNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: _Harness(rig: this),
      ),
    );
    await tester.pump();
    state = tester.state(find.byType(_Harness));
  }

  /// 与页面 _handleVideoGamepadButton 逐行同构：video scope 注册表解析 →
  /// [videoActionCallbacks] 执行体。命中返回 true（消费），未绑定返回 false。
  bool handleButton(GamepadButton button) {
    // 与页面 _handleVideoGamepadButton 同构：video scope 先解析，未命中兜底
    // universal（「返回上一级」，默认手柄 B）。
    final ShortcutAction? action =
        registry.resolveGamepad(button, scope: ShortcutScope.video) ??
            registry.resolveGamepad(button, scope: ShortcutScope.universal);
    if (action == null) return false;
    final VoidCallback? callback = videoActionCallbacks(_actions())[action];
    if (callback == null) return false;
    callback();
    return true;
  }

  /// 与 gamepad_service 的 _dispatchButton 逐分支镜像（该方法私有且绑在插件轮询上，
  /// 无法直接调用）：① [dispatchGamepadButtonIntent]（真实实现）；② 未消费时
  /// A→ActivateIntent、B→注册表 globalBack 解析后 maybePop、dpad→
  /// [gamepadMoveFocusInDirection]（真实实现）。返回值 = 页面是否消费。
  bool dispatchLikeService(GamepadButton button) {
    final BuildContext? ctx =
        FocusManager.instance.primaryFocus?.context ?? navKey.currentContext;
    if (ctx == null) {
      fail('no dispatch context');
    }
    if (dispatchGamepadButtonIntent(ctx, button)) return true;
    switch (button) {
      case GamepadButton.a:
        Actions.maybeInvoke<ActivateIntent>(ctx, const ActivateIntent());
        return false;
      case GamepadButton.b:
        if (registry.resolveGamepad(button, scope: ShortcutScope.universal) ==
            ShortcutAction.globalBack) {
          navKey.currentState?.maybePop();
        }
        return false;
      case GamepadButton.dpadUp:
        gamepadMoveFocusInDirection(ctx, TraversalDirection.up);
        return false;
      case GamepadButton.dpadDown:
        gamepadMoveFocusInDirection(ctx, TraversalDirection.down);
        return false;
      case GamepadButton.dpadLeft:
        gamepadMoveFocusInDirection(ctx, TraversalDirection.left);
        return false;
      case GamepadButton.dpadRight:
        gamepadMoveFocusInDirection(ctx, TraversalDirection.right);
        return false;
      default:
        return false;
    }
  }

  /// 真实 [VideoPlayerShortcutActions]：被断言的动作计数（escape 同构
  /// _exitVideoFullscreen——全屏在栈上时 pop 根 navigator），其余 no-op。
  VideoPlayerShortcutActions _actions() {
    void bump(ShortcutAction action) => counts[action] = counts[action]! + 1;
    return VideoPlayerShortcutActions(
      togglePlayPause: () => bump(ShortcutAction.videoTogglePlayPause),
      play: _noop,
      pause: _noop,
      previousSubtitle: _noop,
      nextSubtitle: _noop,
      seekBackward: () => bump(ShortcutAction.videoSeekBackward),
      seekForward: () => bump(ShortcutAction.videoSeekForward),
      toggleShaderCompare: _noop,
      volumeUp: () => bump(ShortcutAction.videoVolumeUp),
      volumeDown: () => bump(ShortcutAction.videoVolumeDown),
      toggleMute: _noop,
      speedUp: _noop,
      speedDown: _noop,
      resetSpeed: _noop,
      toggleHoldSpeed: _noop,
      previousFrame: _noop,
      nextFrame: _noop,
      screenshot: _noop,
      toggleFullscreen: _noop,
      toggleSubtitleList: _noop,
      toggleImmersiveLock: _noop,
      toggleSubtitleBlur: _noop,
      cycleSubtitleObscure: _noop,
      toggleSubtitleHide: _noop,
      cycleSecondarySubtitleObscure: _noop,
      toggleSecondarySubtitleHide: _noop,
      toggleFavoriteSentence: _noop,
      replayCurrentSubtitle: _noop,
      replayPreviousSubtitle: _noop,
      previousChapter: _noop,
      nextChapter: _noop,
      openSubtitleAlign: _noop,
      subtitleDelayIncrease: _noop,
      subtitleDelayDecrease: _noop,
      alignSubtitleToPrev: _noop,
      alignSubtitleToNext: _noop,
      enterCaret: () => bump(ShortcutAction.videoEnterCaret),
      escape: () {
        bump(ShortcutAction.globalBack);
        if (state.fullscreenActive) {
          navKey.currentState?.maybePop();
        }
      },
    );
  }

  /// 与页面 _wrapVideoGamepadControls 同构：外层 [Actions] 接桌面轮询派发的
  /// [GamepadButtonIntent]，内层旁观 [Focus] 不夺焦、不参与遍历。
  Widget wrapGamepad(Widget child) {
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) => handleButton(intent.button),
        ),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        child: child,
      ),
    );
  }
}

void _noop() {}

/// 与视频页同构的宿主：窗口侧 controls 持共享 [videoNode]（autofocus），进全屏时
/// 卸载窗口侧（VideoControlsFocusGate 语义，其机制已由
/// video_fullscreen_focus_gate_test.dart 覆盖，这里用等价条件卸载）、全屏路由用
/// 同一节点再挂一个 [Focus]，路由 future 完成复位 + post-frame 归还焦点
/// （与 _pushNeutralizedVideoFullscreen / _onVideoFullscreenRouteClosed 同构）。
class _Harness extends StatefulWidget {
  const _Harness({required this.rig});

  final _Rig rig;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool fullscreenActive = false;

  Widget _controls(Key key) {
    return Focus(
      focusNode: widget.rig.videoNode,
      autofocus: true,
      child: SizedBox.expand(key: key),
    );
  }

  /// [wrapped]=false 复现修前形状（裸路由）；true 为修后形状（内容包
  /// _wrapVideoGamepadControls，与 fullscreen.part.dart 的修复一致）。
  void enterFullscreen({required bool wrapped}) {
    setState(() => fullscreenActive = true);
    final Widget content = Material(
      child: _controls(const Key('fullscreen-controls')),
    );
    Navigator.of(context, rootNavigator: true)
        .push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) =>
            wrapped ? widget.rig.wrapGamepad(content) : content,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    )
        .whenComplete(() {
      if (!mounted) return;
      setState(() => fullscreenActive = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.rig.videoNode.requestFocus();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.rig.videoNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 窗口侧与页面同构：手柄输入层在最外层；全屏期窗口侧 controls 卸载（gate 语义）。
    return widget.rig.wrapGamepad(
      Scaffold(
        body: fullscreenActive
            ? const SizedBox.shrink()
            : _controls(const Key('windowed-controls')),
      ),
    );
  }
}
