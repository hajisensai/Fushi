import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// iOS 集成测试里接收**真实触摸**（外部 XCUITest 投递）的会话。
///
/// `flutter test` 的集成测试绑定默认让 iOS 平台视图（WKWebView 等）一次真实触摸
/// 都收不到，原因有两层，缺一不可：
///
/// 1. **引擎同步命中查询被测试绑定吞掉**。Flutter 3.47 起 iOS 的
///    `FlutterTouchInterceptingView.hitTest:` 会同步问框架
///    （`platformViewShouldAcceptTouchAtTouchBeganLocation` → `PlatformDispatcher.onHitTest`），
///    框架答「命中路径里没有平台视图」就把触摸截在自己身上、不交给 WKWebView。
///    `GestureBinding.initInstances` 把 `onHitTest` 设到 `binding.platformDispatcher`
///    上，而测试绑定的那个是 `TestPlatformDispatcher`——它没实现 `onHitTest` 的
///    setter，`noSuchMethod` 直接吞掉；真 `PlatformDispatcher.onHitTest` 于是保持
///    null，引擎拿到 `HitTestResponse.empty`（`hasPlatformView: false`），**任何**
///    平台视图都永远收不到触摸。这里把同一套判定（命中路径含 [NativeHitTestTarget]）
///    直接装到真 dispatcher 上，与生产 `GestureBinding._handleHitTest` 一致。
/// 2. **设备指针事件被丢弃**。`LiveTestWidgetsFlutterBinding` 默认
///    `shouldPropagateDevicePointerEvents = false`，真实触摸不进框架、手势竞技场
///    永远不判给平台视图，`FlutterDelayingGestureRecognizer` 就一直扣着触摸。
///
/// 这两处都只是测试绑定与生产的差异；装上后命中链与正常启动的 app 相同。
/// 用完必须 [dispose]（测试绑定会校验 `shouldPropagateDevicePointerEvents` 在
/// 用例结束时已复位）。
class IosRealTouchSession {
  IosRealTouchSession._(this._binding, this._previousHitTest);

  final IntegrationTestWidgetsFlutterBinding _binding;
  final ui.HitTestCallback? _previousHitTest;
  final List<PointerEvent> _events = <PointerEvent>[];
  int _seq = 0;

  /// 打开会话：装真命中查询 + 放行设备指针事件 + 记录框架收到的每个指针事件。
  static IosRealTouchSession start(
    IntegrationTestWidgetsFlutterBinding binding,
  ) {
    final ui.PlatformDispatcher real = ui.PlatformDispatcher.instance;
    final IosRealTouchSession session = IosRealTouchSession._(
      binding,
      real.onHitTest,
    );
    real.onHitTest = (ui.HitTestRequest request) {
      final HitTestResult result = HitTestResult();
      binding.hitTestInView(result, request.offset, request.view.viewId);
      return ui.HitTestResponse(
        hasPlatformView: result.path.any(
          (HitTestEntry entry) => entry.target is NativeHitTestTarget,
        ),
      );
    };
    binding.shouldPropagateDevicePointerEvents = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(session._record);
    return session;
  }

  void _record(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerUpEvent) {
      _events.add(event);
    }
  }

  /// 框架收到的 Down / Up 指针事件（全局坐标），用于确认触摸真的投到了。
  List<PointerEvent> get events => List<PointerEvent>.unmodifiable(_events);

  /// 请外部 XCUITest 在全局逻辑坐标 [at] 投一次真实触摸，等到框架收到对应的
  /// `PointerUpEvent`（最长 [timeout]）。[pressSeconds] > 0 为长按；[dragTo] 非空时
  /// 按住后拖到该点。返回是否在超时前收到抬起事件。
  ///
  /// 协议：打印一行 `[ios-touch] TAP <seq> <x> <y> [press=<s>] [drag=<x2>,<y2>]`，
  /// 由 `support/run_sim_touch_itest.sh` 的桥转给 `support/ios_touch_tapper`。
  Future<bool> touch(
    WidgetTester tester,
    Offset at, {
    double pressSeconds = 0,
    Offset? dragTo,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _seq++;
    final int before = _events.length;
    final StringBuffer line = StringBuffer(
      '[ios-touch] TAP $_seq ${at.dx.toStringAsFixed(1)} '
      '${at.dy.toStringAsFixed(1)}',
    );
    if (pressSeconds > 0) line.write(' press=$pressSeconds');
    if (dragTo != null) {
      line.write(
        ' drag=${dragTo.dx.toStringAsFixed(1)},${dragTo.dy.toStringAsFixed(1)}',
      );
    }
    debugPrint(line.toString());
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await tester.pump(const Duration(milliseconds: 16));
      if (_events.skip(before).any((PointerEvent e) => e is PointerUpEvent)) {
        return true;
      }
    }
    return false;
  }

  /// 收尾：还原 dispatcher 与绑定的原状态。
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_record);
    _binding.shouldPropagateDevicePointerEvents = false;
    ui.PlatformDispatcher.instance.onHitTest = _previousHitTest;
  }
}
