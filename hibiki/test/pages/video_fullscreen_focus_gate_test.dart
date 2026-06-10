import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_controls_focus_gate.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// TODO-040/042「视频快捷键失灵」根因与修复的行为测试。
///
/// 根因（框架级，真实 media_kit 结构的最小复现）：media_kit 窗口/全屏两套 controls
/// 共用同一个 [FocusNode]，同一节点被两个 [Focus] widget 同时 attach 时后挂者持有
/// current attachment；退全屏时全屏侧 Focus dispose → detach 把节点摘出焦点树，而
/// 窗口侧只剩 stale attachment（reparent 永远 no-op）→ 节点永久孤儿，requestFocus
/// 静默挂起，空格等全部快捷键死亡——且后续每个对话框/菜单关闭后的 refocus 补丁
/// 一并失效（用户报「设置/导入/点外部后快捷键失灵」打补丁后仍复发的原因）。
///
/// 修复 = [VideoControlsFocusGate]：全屏路由在栈上时卸载窗口侧 controls，保证任意
/// 时刻只有一个 Focus 持有该节点，退全屏后窗口侧重挂、节点重新 attach。
///
/// 真实 `VideoHibikiPage` 无法 headless 加载（media_kit 测试宿主无 libmpv），页面
/// 接线由 `video_page_keyboard_focus_static_test.dart` 源码守卫；本文件在同构 harness
/// 上验证机制本身（与 media_kit material_desktop.dart 同款 CallbackShortcuts→Focus
/// 结构 + 真实 [FullscreenInheritedWidget] + 真实 gate）。
void main() {
  testWidgets('gate: 非全屏期窗口侧 controls 正常挂载', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VideoControlsFocusGate(
          fullscreenRouteActive: false,
          child: SizedBox(key: Key('controls')),
        ),
      ),
    );
    expect(find.byKey(const Key('controls')), findsOneWidget);
  });

  testWidgets('gate: 全屏期窗口侧（无 FullscreenInheritedWidget）controls 卸载',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VideoControlsFocusGate(
          fullscreenRouteActive: true,
          child: SizedBox(key: Key('controls')),
        ),
      ),
    );
    expect(find.byKey(const Key('controls')), findsNothing);
  });

  testWidgets('gate: 全屏路由内（有 FullscreenInheritedWidget）controls 保留',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenInheritedWidget(
          parent: VideoState(),
          child: const VideoControlsFocusGate(
            fullscreenRouteActive: true,
            child: SizedBox(key: Key('controls')),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('controls')), findsOneWidget);
  });

  testWidgets('修复：全屏往返后（gate 卸载窗口侧）空格快捷键仍然存活——路径 D',
      (WidgetTester tester) async {
    final FocusNode sharedNode = FocusNode(debugLabel: 'sharedVideoNode');
    addTearDown(sharedNode.dispose);
    final _Harness harness = _Harness(sharedNode: sharedNode, useGate: true);
    await tester.pumpWidget(MaterialApp(home: harness));
    await tester.pump();
    final _HarnessState state = tester.state(find.byType(_Harness));

    // 基线：windowed controls 持焦点，空格触发播放/暂停回调。
    expect(sharedNode.hasPrimaryFocus, isTrue,
        reason: 'autofocus 应让共享节点持焦（基线前置条件）');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 1);

    // 进全屏：gate 卸载窗口侧，全屏侧用同一节点接管。
    state.enterFullscreen();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowed-controls')), findsNothing,
        reason: '全屏期窗口侧 controls 必须卸载，否则退全屏时共享节点被摘成孤儿');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.fullscreenPresses, 1);
    expect(state.windowedPresses, 1);

    // 退全屏：whenComplete 复位 + 重挂 + 归还焦点（与页面 _onVideoFullscreenRouteClosed 同构）。
    state.exitFullscreen();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowed-controls')), findsOneWidget);
    expect(sharedNode.hasPrimaryFocus, isTrue,
        reason: '退全屏后共享节点必须重新 attach 并拿回焦点');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 2,
        reason: '退全屏后空格必须仍由视频快捷键消费（TODO-040 路径 D）');
  });

  testWidgets('根因对照（无 gate，media_kit 上游原始结构）：全屏往返后节点孤儿、空格死亡',
      (WidgetTester tester) async {
    final FocusNode sharedNode = FocusNode(debugLabel: 'sharedVideoNode');
    addTearDown(sharedNode.dispose);
    final _Harness harness = _Harness(sharedNode: sharedNode, useGate: false);
    await tester.pumpWidget(MaterialApp(home: harness));
    await tester.pump();
    final _HarnessState state = tester.state(find.byType(_Harness));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 1);

    state.enterFullscreen();
    await tester.pumpAndSettle();
    state.exitFullscreen();
    await tester.pumpAndSettle();

    // 模拟页面里所有 _refocusVideo() 补丁：requestFocus 只会静默挂起。
    sharedNode.requestFocus();
    await tester.pumpAndSettle();
    expect(sharedNode.hasPrimaryFocus, isFalse,
        reason: '孤儿节点 requestFocus 永远拿不到焦点——这是补丁失效的根因。'
            '若本断言开始失败，说明 Flutter/media_kit 共享节点语义已变，'
            '可重新评估是否还需要 VideoControlsFocusGate');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 1, reason: '空格不再被视频快捷键消费');
  });

  testWidgets('路径 A/B/C 依赖的框架假设：modal 关闭 whenComplete requestFocus 即归还，空格复活',
      (WidgetTester tester) async {
    final FocusNode sharedNode = FocusNode(debugLabel: 'sharedVideoNode');
    addTearDown(sharedNode.dispose);
    final _Harness harness = _Harness(sharedNode: sharedNode, useGate: true);
    await tester.pumpWidget(MaterialApp(home: harness));
    await tester.pump();
    final _HarnessState state = tester.state(find.byType(_Harness));

    // 打开「设置」式对话框（autofocus 按钮夺走焦点）→ 空格不再控制视频。
    state.openModal();
    await tester.pumpAndSettle();
    expect(sharedNode.hasPrimaryFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 0);

    // 关闭：whenComplete 立即 requestFocus（与页面各 sheet/对话框补丁同构）。
    state.closeModal();
    await tester.pumpAndSettle();
    expect(sharedNode.hasPrimaryFocus, isTrue, reason: '覆盖层关闭后焦点必须回到视频节点');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.windowedPresses, 1,
        reason: '设置/导入遮罩等 modal 关闭后空格必须复活（TODO-040 路径 A/B）');
  });
}

/// 与 media_kit `material_desktop.dart` 同构的最小 harness：
/// `CallbackShortcuts(空格) → Focus(共享节点, autofocus)`，窗口/全屏两套实例共用
/// [sharedNode]；[useGate] 控制是否启用 [VideoControlsFocusGate]（对照组复现上游
/// 原始结构）。
class _Harness extends StatefulWidget {
  const _Harness({required this.sharedNode, required this.useGate});

  final FocusNode sharedNode;
  final bool useGate;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool fullscreenActive = false;
  int windowedPresses = 0;
  int fullscreenPresses = 0;

  Widget _controls(Key key, VoidCallback onSpace) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): onSpace,
      },
      child: Focus(
        focusNode: widget.sharedNode,
        autofocus: true,
        child: SizedBox.expand(key: key),
      ),
    );
  }

  /// 与页面 [_pushNeutralizedVideoFullscreen] 同构：置位 → push 全屏路由（push 后
  /// post-frame 归还焦点，等共享节点被全屏侧 attach 完）→ 路由 future 完成时复位 +
  /// 下一帧归还焦点。
  ///
  /// 路由内不包真实 [FullscreenInheritedWidget]：它自带的 PopScope 在 pop 时要求
  /// [VideoStateInheritedWidget] 祖先（headless 无法构造完整 media_kit 状态），而
  /// gate 在全屏路由内本来就是透传——透传语义已由上面带真实 inherited widget 的
  /// 单元测试覆盖；本 harness 只需「第二个 Focus 在独立路由里共享同一节点」这一
  /// 机制本身。
  void enterFullscreen() {
    setState(() => fullscreenActive = true);
    Navigator.of(context, rootNavigator: true)
        .push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => _controls(
          const Key('fullscreen-controls'),
          () => fullscreenPresses++,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    )
        .whenComplete(() {
      if (!mounted) return;
      setState(() => fullscreenActive = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.sharedNode.requestFocus();
      });
    });
    // 镜像页面 _pushNeutralizedVideoFullscreen 的 finally：post-frame 归还焦点
    // （路由 build 后节点已在全屏侧，requestFocus 才能落地——同步调用会被随后的
    // reparent 冲掉，primary 落到全屏路由 ModalScope）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.sharedNode.requestFocus();
    });
  }

  void exitFullscreen() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  void openModal() {
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(
        content:
            TextButton(autofocus: true, onPressed: _noop, child: Text('x')),
      ),
    ).whenComplete(() {
      widget.sharedNode.requestFocus();
    });
  }

  void closeModal() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  Widget _maybeGate({
    required bool fullscreenRouteActive,
    required Widget child,
  }) {
    if (!widget.useGate) return child;
    return VideoControlsFocusGate(
      fullscreenRouteActive: fullscreenRouteActive,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _maybeGate(
      fullscreenRouteActive: fullscreenActive,
      child: _controls(const Key('windowed-controls'), () => windowedPresses++),
    );
  }
}

void _noop() {}
