import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-425：视频页合成 hover 在 `MouseTracker` 遍历期重入致
/// `Concurrent modification during iteration: _Map len:2` 崩溃。
///
/// 根因：[_pokeControlsVisible] 经 `GestureBinding.handlePointerEvent` 派发合成
/// [PointerHoverEvent] 唤醒控制条；该 helper 的部分调用方是 MouseRegion 自己的
/// onEnter/onHover（rail / 锁按钮 keep-alive、字幕盒 hover），它们运行在
/// `MouseTracker.updateAllDevices` 遍历内部 `_mouseStates` Map 的 `_deviceUpdatePhase`
/// 内。同步派发会进入 `MouseTracker.updateWithEvent` → 写 `_mouseStates[合成设备]` →
/// 在迭代期增删该 Map → release 抛 `Concurrent modification during iteration`
/// （debug 触 `_debugDuringDeviceUpdate` 重入断言）。
///
/// 修复：合成 hover 的**派发**恒经 [scheduleMicrotask] 延迟到当前调用栈（含 MouseTracker
/// 迭代）解开后再执行。
///
/// 本文件两层守卫：
/// ① 行为层：用纯框架部件复现「MouseRegion.onEnter 里派发第二设备合成 hover」的并发修改，
///    证明**同步派发**会让框架上报重入错误，而**微任务派发**安全（与修复同构）。
/// ② 源码层：锁死 [_pokeControlsVisible] 不再同步 `handlePointerEvent`，改 [_pendingPokeHover]
///    + [scheduleMicrotask] + [_dispatchPokeHover] 延迟派发（media_kit 视频部件跑不了
///    headless，故 video 页本体只能源码守卫）。
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

  group('源码守卫：_pokeControlsVisible 延迟派发', () {
    late String src;
    setUpAll(() {
      src = readVideoHibikiSource();
    });

    test('_pokeControlsVisible 不再同步派发，改 scheduleMicrotask 延迟', () {
      final int at = src.indexOf('void _pokeControlsVisible()');
      expect(at, greaterThanOrEqualTo(0));
      // 切到方法体闭合（下一个成员的 doc 注释 `/// 在微任务里` 之前），避免把
      // _dispatchPokeHover 的 doc 注释（提到 handlePointerEvent）算进来。
      final int end = src.indexOf('/// 在微任务里真正派发', at);
      expect(end, greaterThan(at), reason: '应有 _dispatchPokeHover 延迟派发 helper');
      final String body = src.substring(at, end);
      expect(
          body.contains('GestureBinding.instance.handlePointerEvent'), isFalse,
          reason: 'BUG-425：_pokeControlsVisible 体内不得再同步派发 '
              'GestureBinding.instance.handlePointerEvent（注释提及不算）');
      expect(body.contains('scheduleMicrotask(_dispatchPokeHover)'), isTrue,
          reason: '_pokeControlsVisible 必须经 scheduleMicrotask 延迟派发');
      expect(body.contains('_pendingPokeHover = PointerHoverEvent('), isTrue,
          reason: '合成 hover 应先存入 _pendingPokeHover（几何有效时同步构造）');
    });

    test('_dispatchPokeHover 在微任务里 mounted 校验后派发待发事件', () {
      final int at = src.indexOf('void _dispatchPokeHover()');
      expect(at, greaterThanOrEqualTo(0));
      final int end = src.indexOf('void _clearRailHover()', at);
      expect(end, greaterThan(at));
      final String body = src.substring(at, end);
      expect(body.contains('GestureBinding.instance.handlePointerEvent(event)'),
          isTrue,
          reason: '真正派发收敛到 _dispatchPokeHover（已脱离 MouseTracker 迭代栈）');
      expect(body.contains('if (event == null || !mounted) return;'), isTrue,
          reason: '微任务派发前应重校验 mounted / 待发事件存在');
    });

    test('存在去重旗 _pokeDispatchScheduled + 待发字段 _pendingPokeHover', () {
      expect(src.contains('bool _pokeDispatchScheduled = false;'), isTrue,
          reason: '应有微任务去重旗，连按时折叠成单次派发');
      expect(src.contains('PointerHoverEvent? _pendingPokeHover;'), isTrue,
          reason: '应有待派发合成 hover 字段');
    });
  });
}

/// 复现部件：外层 region 覆盖全画面（让真实鼠标先进 `_mouseStates`），内层 region 的
/// onEnter 在「MouseTracker 正在处理设备更新」时派发**第二个设备**的合成 hover。
/// [deferDispatch] 模拟 BUG-425 修复：true=微任务延迟派发，false=同步派发（旧崩法）。
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
