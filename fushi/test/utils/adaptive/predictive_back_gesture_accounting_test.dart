// Android 侧滑返回（预测性返回）手势记账守卫。
//
// 背景：Flutter 3.44 自带的 PredictiveBackPageTransitionsBuilder 把平台的
// start/commit/cancel 事件直接转成 NavigatorState 的全局手势计数增减，没有任何配对
// 保证。计数一旦卡在 >0，`_ModalScope` 会把每一层路由都 IgnorePointer 掉
// （widgets/routes.dart 的 `_shouldIgnoreFocusRequest`）——画面正常、动画照跑，但整个
// app 点不动、焦点也拿不到，用户只能杀进程。用户实报：安卓平板设置页进次级页面后
// **侧滑**返回即全屏点击失效（点左上角箭头返回则正常）。
//
// 本测试把三条会让自带实现失配的平台事件序列固化下来，断言换用
// FushiPredictiveBackPageTransitionsBuilder 之后计数恒回零、界面仍可点击，同时断言
// 正常的手势返回、以及首页 PopScope 拦截返回的语义都没被改变。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/predictive_back_page_transitions.dart';

/// 把一条预测性返回事件投进 framework，与平台侧走同一条 channel。
Future<void> _sendBackGesture(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? arguments,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, arguments),
    ),
    (ByteData? _) {},
  );
}

Map<String, Object?> _gestureEvent(double progress) => <String, Object?>{
      'touchOffset': <Object?>[10.0, 100.0],
      'progress': progress,
      'swipeEdge': 0,
    };

/// 首页：恒挂 `PopScope(canPop:false)`，与设置 tab 的返回拦截同构（BUG-236）。
class _HomeShell extends StatelessWidget {
  const _HomeShell({required this.onBlockedPop});

  final VoidCallback onBlockedPop;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) onBlockedPop();
      },
      child: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext _) => const Scaffold(
                  body: Center(child: Text('subpage')),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}

NavigatorState _navigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator).first);

/// 首页的按钮此刻是否真的可点（失配时整层被 IgnorePointer，点了没有任何反应）。
Future<bool> _homeButtonStillWorks(WidgetTester tester) async {
  await tester.tap(
    find.text('open', skipOffstage: false),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
  final bool opened = find.text('subpage').evaluate().isNotEmpty;
  if (opened) {
    _navigator(tester).pop();
    await tester.pumpAndSettle();
  }
  return opened;
}

void main() {
  // 平台 override 必须在测试体内复位：_verifyInvariants 早于 tearDown 执行。
  void useAndroid() =>
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
  void resetPlatform() => debugDefaultTargetPlatformOverride = null;

  Future<int> pumpHomeAndOpenSubpage(
    WidgetTester tester, {
    bool openSubpage = true,
  }) async {
    useAndroid();
    var blockedPops = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android:
                  FushiPredictiveBackPageTransitionsBuilder(),
            },
          ),
        ),
        home: _HomeShell(onBlockedPop: () => blockedPops++),
      ),
    );
    if (openSubpage) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('subpage'), findsOneWidget);
    }
    return blockedPops;
  }

  testWidgets('正常侧滑返回：子页被 pop，手势计数归零，界面仍可点', (WidgetTester tester) async {
    await pumpHomeAndOpenSubpage(tester);

    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    await _sendBackGesture(
      tester,
      'updateBackGestureProgress',
      _gestureEvent(0.6),
    );
    await tester.pump();
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.text('subpage'), findsNothing, reason: '手势返回必须真的 pop 掉子页');
    expect(_navigator(tester).userGestureInProgress, isFalse);
    expect(await _homeButtonStillWorks(tester), isTrue);
    resetPlatform();
  });

  testWidgets('平台重发起始事件（start→start→commit）不再让手势计数卡死',
      (WidgetTester tester) async {
    await pumpHomeAndOpenSubpage(tester);

    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    // 自带实现在这里会再 didStartUserGesture() 一次，而 commit 只减一次 → 永久 >0。
    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.1));
    await tester.pump();
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(
      _navigator(tester).userGestureInProgress,
      isFalse,
      reason: '重复的起始事件只能计一次手势',
    );
    expect(await _homeButtonStillWorks(tester), isTrue);
    resetPlatform();
  });

  testWidgets('手势中途路由被程序化 pop，手势计数仍归零', (WidgetTester tester) async {
    await pumpHomeAndOpenSubpage(tester);

    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    // 自带实现把 didStopUserGesture 挂在路由动画的 status listener 上，路由随即销毁、
    // controller 一并 dispose，那次减法永远不会发生 → 永久 >0。
    _navigator(tester).pop();
    await tester.pumpAndSettle();
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(_navigator(tester).userGestureInProgress, isFalse);
    expect(await _homeButtonStillWorks(tester), isTrue);
    resetPlatform();
  });

  testWidgets('commit 之后重发 cancel 被丢弃，不会把手势计数减成负数',
      (WidgetTester tester) async {
    await pumpHomeAndOpenSubpage(tester);

    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pump();
    // 自带实现在这里会二次 didStopUserGesture()：debug 踩
    // assert(_userGesturesInProgress > 0)，release 静默变负。
    await _sendBackGesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();

    expect(_navigator(tester).userGestureInProgress, isFalse);
    // 计数若已变负，下一次完整手势会被整段吞掉（加回 0 仍不 >0），故再跑一轮验证。
    await tester.tap(find.text('open', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.text('subpage'), findsOneWidget);
    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    expect(
      _navigator(tester).userGestureInProgress,
      isTrue,
      reason: '手势计数被减成负数后，后续手势会静默失效',
    );
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(_navigator(tester).userGestureInProgress, isFalse);
    resetPlatform();
  });

  testWidgets('栈底 + PopScope(canPop:false)：侧滑不接管，仍走拦截回调',
      (WidgetTester tester) async {
    // 首页的返回语义（消费系统返回、切回来源 tab）必须原样保留：本 detector 在
    // popGestureEnabled 为假时不接管，事件回落到框架的普通 pop 路径。
    useAndroid();
    var blockedPops = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android:
                  FushiPredictiveBackPageTransitionsBuilder(),
            },
          ),
        ),
        home: _HomeShell(onBlockedPop: () => blockedPops++),
      ),
    );

    await _sendBackGesture(tester, 'startBackGesture', _gestureEvent(0.0));
    await tester.pump();
    await _sendBackGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(blockedPops, 1, reason: '首页侧滑仍须由 PopScope 消费（切回来源 tab）');
    expect(_navigator(tester).userGestureInProgress, isFalse);
    expect(await _homeButtonStillWorks(tester), isTrue);
    resetPlatform();
  });
}
