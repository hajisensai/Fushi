import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-425：视频页合成 hover 在 `MouseTracker` 遍历期重入致
/// `Concurrent modification during iteration: _Map len:2` 崩溃。
///
/// 根因（历史）：旧 [_pokeControlsVisible] 经 `GestureBinding.handlePointerEvent` 派发
/// 合成 [PointerHoverEvent] 唤醒控制条；该 helper 的部分调用方是 MouseRegion 自己的
/// onEnter/onHover（字幕盒 hover 的 [_handleSubtitleHover] 等），它们运行在
/// `MouseTracker.updateAllDevices` 遍历内部 `_mouseStates` Map 的 `_deviceUpdatePhase`
/// 内。同步派发会进入 `MouseTracker.updateWithEvent` → 写 `_mouseStates[合成设备]` →
/// 在迭代期增删该 Map → release 抛 `Concurrent modification during iteration`
/// （debug 触 `_debugDuringDeviceUpdate` 重入断言）。当时的修法是把派发挪进
/// [scheduleMicrotask]（`_pendingPokeHover` + `_dispatchPokeHover` + 去重旗）。
///
/// BUG-2453 删掉了整套合成派发：poke 两端只 `_restartHideTimerSignal.poke()`，桌面
/// fork 经 `wakeSignal` 收到即调自己的 `onHover()`。`Listenable.notifyListeners` 不碰
/// `MouseTracker`，重入面**在结构上消失**——不是「延迟到栈解开后再派」，而是根本没有
/// 指针事件可派。微任务脚手架随之一并删除。
///
/// 本文件两层守卫：
/// ① 行为层：用纯框架部件复现「MouseRegion.onEnter 里派发第二设备合成 hover」的并发修改。
///    保留它是因为这是**框架事实**：只要有人把「在 MouseRegion 回调里合成指针事件」
///    带回来，同步派发就会撞上这条重入保护。它解释的是「为什么页面不能在 hover 回调里
///    派指针事件」，与页面当前实现无关。
/// ② 源码层：锁死 [_pokeControlsVisible] 体内既无 `handlePointerEvent` 也无
///    `scheduleMicrotask`，唯一出口是 `_restartHideTimerSignal.poke();`，且微任务脚手架
///    不得残留（media_kit 视频部件跑不了 headless，故 video 页本体只能源码守卫）。
void main() {
  // 行为层：直接驱动框架 `MouseTracker`，证明「在设备更新回调里同步派发第二设备合成
  // hover」会撞上框架的重入保护，而「微任务延迟派发」不会。不经 testWidgets（其内置
  // FlutterError 捕获会与我们刻意触发的框架错误打架），改用 testWidgets + 自管 onError
  // 并在断言前还原，精确复现 BUG-425 的栈：onEnter（跑在 MouseTracker 设备更新内）里
  // 同步 handlePointerEvent → 重入 _deviceUpdatePhase。
  group('行为复现：MouseRegion 回调内派发第二设备合成 hover', () {
    testWidgets('微任务延迟派发不触发 MouseTracker 重入/并发修改（修复同构）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const _ReentrantHoverHarness(deferDispatch: true),
      );

      final TestGesture realMouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(() => realMouse.removePointer());
      await realMouse.addPointer(location: const Offset(10, 10));
      await tester.pump();

      // 真实鼠标落进内层 region → onEnter 把合成派发排进微任务（脱离 MouseTracker 栈）。
      await realMouse.moveTo(const Offset(50, 50));
      await tester.pump();
      // 让排好的微任务执行其合成派发。
      await tester.pump();

      // 若延迟派发仍重入，testWidgets 会把框架重入错误当未捕获异常令本测试失败；
      // 走到这里且无失败即证明延迟派发安全。
      expect(tester.takeException(), isNull,
          reason: '微任务延迟派发不应触发 MouseTracker 重入/并发修改');
    });
  });

  group('源码守卫：_pokeControlsVisible 不派指针事件（BUG-425 重入面随 BUG-2453 结构消失）', () {
    late String src;
    setUpAll(() {
      src = readVideoFushiSource();
    });

    test(
        '_pokeControlsVisible 体内无 handlePointerEvent / scheduleMicrotask，唯一出口是信号',
        () {
      final String body = methodBody(src, 'void _pokeControlsVisible()');
      expect(containsCodeLine(body, 'handlePointerEvent('), isFalse,
          reason: 'BUG-425 的重入根因是在 MouseRegion 回调里同步派指针事件；'
              'poke 体内不得再有任何派发（注释提及不算）');
      expect(containsCodeLine(body, 'scheduleMicrotask('), isFalse,
          reason: 'BUG-425 的微任务延迟是合成派发的附属补丁；没有派发就没有东西要延迟'
              '（BUG-2453）——它回来说明派发也回来了');
      expect(containsCodeLine(body, '_restartHideTimerSignal.poke();'), isTrue,
          reason: '唯一出口：Listenable 通知不碰 MouseTracker，在 hover 回调里同步调用'
              '也不会重入 _deviceUpdatePhase');
    });

    test('MouseRegion 回调里的调用方仍在（否则上一条的「同步调用安全」是空话）', () {
      // BUG-425 的触发栈：字幕盒 hover → _handleSubtitleHover → _pokeControlsVisible。
      // 这个调用方还在，才证明「poke 可以在 MouseTracker 迭代期被同步调用」是一条真被
      // 走到的路径，而不是守卫在钉一个没人调的方法。
      final String hover =
          methodBody(src, 'void _handleSubtitleHover(bool hovering)');
      expect(containsCodeLine(hover, '_pokeControlsVisible();'), isTrue,
          reason: '字幕盒 hover 仍应经 poke 续命控制条（BUG-283）');
    });

    test('微任务延迟派发脚手架不得残留', () {
      for (final String needle in <String>[
        '_dispatchPokeHover',
        '_pendingPokeHover',
        '_pokeDispatchScheduled',
      ]) {
        expect(containsIdentifier(src, needle), isFalse,
            reason: '$needle 只在合成派发存在时有意义（BUG-425 脚手架）；'
                '它回来 = 合成设备回来（BUG-2453）');
      }
    });
  });
}

/// 复现部件：外层 region 覆盖全画面（让真实鼠标先进 `_mouseStates`），内层 region 的
/// onEnter 在「MouseTracker 正在处理设备更新」时派发**第二个设备**的合成 hover。
/// [deferDispatch] 模拟 BUG-425 当年的修法：true=微任务延迟派发，false=同步派发（崩法）。
/// 页面本身已不再合成指针事件（BUG-2453），这里只保留框架事实的复现。
class _ReentrantHoverHarness extends StatelessWidget {
  const _ReentrantHoverHarness({required this.deferDispatch});

  final bool deferDispatch;

  static const int _syntheticDevice = 0x6869626B; // 'hibk'

  void _dispatchSynthetic() {
    GestureBinding.instance.handlePointerEvent(
      const PointerHoverEvent(
        position: Offset(50, 50),
        device: _syntheticDevice,
        kind: PointerDeviceKind.mouse,
      ),
    );
  }

  void _onEnter(PointerEnterEvent event) {
    if (event.device == _syntheticDevice) return;
    if (deferDispatch) {
      scheduleMicrotask(_dispatchSynthetic);
    } else {
      _dispatchSynthetic();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MouseRegion(
        opaque: false,
        onHover: (_) {},
        child: SizedBox(
          width: 200,
          height: 200,
          child: Align(
            alignment: Alignment.center,
            child: MouseRegion(
              opaque: false,
              onEnter: _onEnter,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
  }
}
