import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2453：视频播放页的合成 hover 设备退出后不注销，库页中心那张卡被幽灵指针
/// 「悬停」放大——用户报「进视频页时中间附近的卡片显示鼠标放上去的效果，鼠标明明
/// 没放上去」。
///
/// 根因：`_pokeControlsVisible` 为了唤醒 media_kit 控制条，用固定设备号往视频区几何
/// 中心派合成 [PointerHoverEvent]。Flutter `MouseTracker` 会为这个设备建一条**真实的
/// 设备状态**，且只在收到同设备的 [PointerRemovedEvent] 时才删；全仓没人派过。退出
/// 播放器后幽灵指针永远停在屏幕中心，每帧帧末 `updateAllDevices` 都在那一点命中，落在
/// 那的 `MouseRegion`（库页卡片的 [FushiHoverLift]）收到 onEnter → 放大。
///
/// 修复：**删掉合成设备**。media_kit 桌面 fork 加显式 `wakeSignal`（与移动端
/// `restartHideTimerSignal` 同构），收到即调它自己的 `onHover()`（唤起 + 重排隐藏
/// Timer）；`_pokeControlsVisible` 两端都只 `_restartHideTimerSignal.poke()`，页面不再
/// 合成任何指针事件。「注销时机」类修法（dispose / 失去栈顶）被 code review 逐条证伪：
/// finalizeTree 锁态断言、换集误伤新页、边沿一次性 vs 无限次 poke、`removeRoute` 与
/// 弹窗路由收不到动画状态——都是在错的抽象上打补丁。
///
/// 三层守卫：
/// ① 机制层：用纯框架部件证明「合成 hover 不派 remove 就永久在册并悬停下一页中心卡」
///    （BUG 本体）以及「不派合成 hover 就没有幽灵设备」（修复本体：页面不再造设备）。
/// ② 页面源码守卫：视频页语料里不得再出现任何指针事件的构造 / 派发；`_pokeControlsVisible`
///    只发信号；桌面 theme 装配 `wakeSignal: _restartHideTimerSignal`。
/// ③ fork 源码守卫：`wakeSignal` 字段 / 构造 / copyWith / State 绑定与解绑 / 处理调 `onHover()`。
///    真实 fork 需 libmpv，headless 跑不了。
void main() {
  group('机制复现：合成 hover 设备的生命周期（BUG-2453 本体）', () {
    testWidgets('派过合成 hover 而不派 remove → 下一页中心的 FushiHoverLift 被判 hover', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayer(tester, probe);
      final Offset center = tester.getCenter(find.byType(_PlayerStub));
      // 与删除前的 `_dispatchPokeHover` 同构：固定设备号 + mouse kind + 视频区中心。
      GestureBinding.instance.handlePointerEvent(
        PointerHoverEvent(
          position: center,
          device: _kLegacySyntheticDevice,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      expect(probe.playerEntered, isTrue, reason: '合成 hover 先命中播放页桩');
      await _popPlayer(tester);

      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isTrue,
          reason: '没派 remove 时合成设备永久在册');
      expect(probe.libraryHovered, isTrue,
          reason: '幽灵指针停在屏幕中心 → 中心那张卡被当成鼠标悬停（BUG-2453 症状）');
    });

    testWidgets('不合成指针事件（修复本体）→ 退页后没有任何设备在册，中心卡不被判 hover', (
      WidgetTester tester,
    ) async {
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayer(tester, probe);
      // 修复后的页面在这里只会 `_restartHideTimerSignal.poke()`——对 MouseTracker 零事件。
      await _popPlayer(tester);

      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse);
      expect(probe.libraryEverHovered, isFalse);

      // 正向对照：真实鼠标移到同一位置，卡片必须照常悬停——证明探针没失灵。
      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(() => mouse.removePointer());
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byType(FushiHoverLift)));
      await tester.pump();
      await tester.pump();
      expect(probe.libraryHovered, isTrue, reason: '真实鼠标悬停仍应生效');
    });
  });

  group('页面源码守卫：视频页不再合成任何指针事件（BUG-2453）', () {
    late String src;
    setUpAll(() {
      src = readVideoFushiSource();
    });

    test('语料里没有指针事件的构造 / 派发 / 合成设备号', () {
      for (final String needle in <String>[
        'GestureBinding.instance.handlePointerEvent(',
        'PointerHoverEvent(',
        'PointerRemovedEvent(',
        'PointerAddedEvent(',
        '_syntheticHoverDevice',
        '0x6869626B',
      ]) {
        expect(containsCodeLine(src, needle), isFalse,
            reason: '页面不得再造指针事件（$needle）：那是幽灵设备的来源');
      }
    });

    test('_pokeControlsVisible 的唯一出口是 _restartHideTimerSignal.poke()', () {
      final String body = methodBody(src, 'void _pokeControlsVisible()');
      expect(containsCodeLine(body, '_restartHideTimerSignal.poke();'), isTrue,
          reason: '两端都经信号唤起 / 续命');
      // 五条门控仍在（BUG-1798 等）：门控成立时控制条本被遮住 / 压制，唤起只会打架。
      for (final String gate in <String>[
        'if (_immersiveLocked.value) return;',
        'if (_videoSidePanel.value != null) return;',
        'if (_subtitleListVisible.value) return;',
        'if (_videoControlEditMode.value) return;',
        'if (_lookupOverlayActive.value) return;',
      ]) {
        expect(containsCodeLine(body, gate), isTrue, reason: '门控不得丢：$gate');
      }
      // 合成 hover 时代顺带续命侧边锁按钮（经页面根 Listener → _handleVideoControlsHover），
      // 改信号后必须显式补上，否则键盘 seek 时锁按钮不再跟着露出。
      expect(containsCodeLine(body, '_pokeLockButton();'), isTrue);
      expect(containsCodeLine(body, 'scheduleMicrotask('), isFalse,
          reason: 'BUG-425 的微任务延迟随合成派发一起删除');
    });

    test('桌面 theme 装配 wakeSignal，与移动端 restartHideTimerSignal 共用同一信号', () {
      final String desktop = methodBody(
          src, 'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(');
      expect(containsCodeLine(desktop, 'wakeSignal: _restartHideTimerSignal,'),
          isTrue,
          reason: '桌面 fork 不接信号就再也没人唤醒控制条（键盘 seek 后 2 秒消失回归）');
      final String mobile = methodBody(
          src, 'MaterialVideoControlsThemeData _mobileControlsTheme(');
      expect(
        containsCodeLine(
            mobile, 'restartHideTimerSignal: _restartHideTimerSignal,'),
        isTrue,
      );
    });

    test('真实 hover 记账点不再按设备号过滤（过滤对象已不存在）', () {
      expect(containsCodeLine(src, '_isSyntheticControlsHover'), isFalse);
    });
  });

  group('fork 源码守卫：桌面控制条 wakeSignal（BUG-2453）', () {
    late String fork;
    setUpAll(() {
      fork = File(
        '../third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('theme data 暴露 wakeSignal（字段 / 构造 / copyWith）', () {
      expect(containsCodeLine(fork, 'final Listenable? wakeSignal;'), isTrue);
      expect(containsCodeLine(fork, 'this.wakeSignal,'), isTrue);
      expect(containsCodeLine(fork, 'Listenable? wakeSignal,'), isTrue,
          reason: 'copyWith 参数');
      expect(
        containsCodeLine(fork, 'wakeSignal: wakeSignal ?? this.wakeSignal,'),
        isTrue,
        reason: 'copyWith 透传（全屏路由经 normal/fullscreen 复制 theme）',
      );
    });

    test('State 在 didChangeDependencies 绑定、dispose 解绑，处理即 onHover()', () {
      final String bind = methodBody(fork, 'void didChangeDependencies()');
      expect(
        containsCodeLine(bind, '_wakeSignal?.addListener(_onWakeSignal);'),
        isTrue,
      );
      expect(
        containsCodeLine(bind, '_wakeSignal?.removeListener(_onWakeSignal);'),
        isTrue,
        reason: 'theme 换信号身份时先解绑旧的',
      );
      final String handler = methodBody(fork, 'void _onWakeSignal()');
      // 两条调用各钉一行**整行精确**：`containsCodeLine` 是子串匹配，只钉 `onHover();`
      // 会被帧末分支的 `if (mounted) onHover();` 顶替（变异实测：注掉直接调用仍绿）。
      expect(_hasExactCodeLine(handler, 'onHover();'), isTrue,
          reason: '非 build 阶段直接唤醒 = 与真实 hover 完全同一条路径（唤起 + 重排隐藏 Timer）');
      expect(_hasExactCodeLine(handler, 'if (mounted) onHover();'), isTrue,
          reason: 'build/layout 阶段发的信号延到帧末，不能丢');
      expect(containsCodeLine(handler, 'addPostFrameCallback('), isTrue);
      expect(_hasExactCodeLine(handler, 'if (!mounted) return;'), isTrue);
      final String dispose = methodBody(fork, 'void dispose()');
      expect(
        containsCodeLine(
            dispose, '_wakeSignal?.removeListener(_onWakeSignal);'),
        isTrue,
      );
    });
  });
}

/// 剥注释后是否存在一行（trim 后）**恰好等于** [line] 的代码行。与 [containsCodeLine] 的
/// 子串匹配互补：钉「某条语句独立成行存在」而不被含它的更长语句顶替。
bool _hasExactCodeLine(String body, String line) => maskComments(body)
    .split('\n')
    .any((String candidate) => candidate.trim() == line);

/// 删除前 `_VideoFushiPageState._syntheticHoverDevice` 的值（'hibk'），只用于机制复现。
const int _kLegacySyntheticDevice = 0x6869626B;

/// 兜底注销，避免复现用例把幽灵设备留给同进程的后续测试。对不在册的设备是框架层 no-op。
void _retireSyntheticDevice() {
  GestureBinding.instance.handlePointerEvent(
    const PointerRemovedEvent(
      device: _kLegacySyntheticDevice,
      kind: PointerDeviceKind.mouse,
    ),
  );
}

class _HoverProbe {
  bool playerEntered = false;
  bool? libraryHovered;
  bool libraryEverHovered = false;
}

Future<void> _pushPlayer(WidgetTester tester, _HoverProbe probe) async {
  await tester.pumpWidget(MaterialApp(home: _LibraryStub(probe: probe)));
  final BuildContext libraryContext =
      tester.element(find.byKey(const ValueKey<String>('library')));
  Navigator.of(libraryContext).push(
    MaterialPageRoute<void>(builder: (_) => _PlayerStub(probe: probe)),
  );
  await tester.pumpAndSettle();
}

Future<void> _popPlayer(WidgetTester tester) async {
  final BuildContext playerContext =
      tester.element(find.byKey(const ValueKey<String>('player')));
  Navigator.of(playerContext).pop();
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
  await tester.pump();
  await tester.pump();
}

class _PlayerStub extends StatelessWidget {
  const _PlayerStub({required this.probe})
      : super(key: const ValueKey<String>('player'));

  final _HoverProbe probe;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: MouseRegion(
        onEnter: (_) => probe.playerEntered = true,
        child: const ColoredBox(color: Colors.black),
      ),
    );
  }
}

class _LibraryStub extends StatelessWidget {
  const _LibraryStub({required this.probe})
      : super(key: const ValueKey<String>('library'));

  final _HoverProbe probe;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 240,
          height: 320,
          child: FushiHoverLift(
            builder: (BuildContext _, bool hovering) {
              probe.libraryHovered = hovering;
              if (hovering) probe.libraryEverHovered = true;
              return const ColoredBox(color: Colors.blue);
            },
          ),
        ),
      ),
    );
  }
}
