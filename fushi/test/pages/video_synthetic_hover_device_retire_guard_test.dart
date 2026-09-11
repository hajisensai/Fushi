import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/route_top_listener.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2453：视频播放页的合成 hover 设备退出后不注销，库页中心那张卡被幽灵指针
/// 「悬停」放大——用户报「进视频页时中间附近的卡片显示鼠标放上去的效果，鼠标明明
/// 没放上去」。
///
/// 根因：`_pokeControlsVisible` 用固定设备号 `_syntheticHoverDevice` 派合成
/// [PointerHoverEvent] 到视频区几何中心唤醒 media_kit 控制条。Flutter `MouseTracker`
/// 会为这个设备建一条**真实的设备状态**，且只在收到同设备的 [PointerRemovedEvent]
/// 时才删；此前全仓没人派过这个 remove。于是退出播放器后，幽灵指针永远停在屏幕中心，
/// 每帧帧末 `updateAllDevices` 都在那一点命中测试，落在那的 `MouseRegion`（库页卡片
/// 的 [FushiHoverLift]）收到 onEnter → 放大。
///
/// 修复：播放页 build 用 [RouteTopListener] 包住整页，在本页**失去栈顶**那一帧的帧末
/// 派同设备 [PointerRemovedEvent]。**不能**放在 `dispose()` 里同步派：dispose 跑在
/// finalizeTree 锁态内，pop 过渡期间幽灵指针早已进到下层库页的卡上，remove 触发那张卡
/// `onExit → setState` 撞「widget tree was locked」断言；`pushReplacement` 时还会把新页
/// 刚露出的控制条藏掉。也不能在每次 hover 后立刻注销：media_kit fork 的 `onExit`
/// 无条件把控制条藏掉。
///
/// 两层守卫：
/// ① 行为层：真 Navigator（push / pop / pushReplacement 带过渡）+ 真 [RouteTopListener]
///    + 真 [FushiHoverLift]，在 Flutter 真实 `MouseTracker` 上复现「不注销 → pop 后下层
///    中心卡被判 hover」，并证明「失去栈顶时注销 → pop 全程下层卡从未被判 hover、无任何
///    断言、真实鼠标照常可悬停；pushReplacement 时新页 region 从未被幽灵指针进入」，外加
///    [RouteTopListener] 自身的边沿语义。media_kit 视频部件 headless 跑不了，故播放页本体
///    走 ② 源码守卫。
/// ② 源码层：钉住 build 用 [RouteTopListener] 接 `_retireSyntheticHoverDevice`、注销派
///    同设备 remove、`dispose` 不派事件、`_dispatchPokeHover` 派发前登记在册。
void main() {
  group('行为复现：合成 hover 设备跨页残留（BUG-2453）', () {
    testWidgets('不注销：pop 后下层库页中心的 FushiHoverLift 被判 hover（复现）', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayerAndPoke(tester, probe, retire: _RetireMode.never);
      await _popPlayer(tester, probe);

      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isTrue,
          reason: '没派 remove 时合成设备仍在 MouseTracker 在册');
      expect(probe.libraryHovered, isTrue,
          reason: '幽灵指针停在屏幕中心 → 中心那张卡被当成鼠标悬停（BUG-2453 症状）');
    });

    testWidgets('失去栈顶时注销（修复同构）：pop 全程下层卡从未被判 hover，且无锁态断言', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayerAndPoke(tester, probe, retire: _RetireMode.onLostTop);
      await _popPlayer(tester, probe);

      expect(tester.takeException(), isNull,
          reason: '注销不得在 finalizeTree 锁态内触发下层卡 setState');
      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse,
          reason: '帧末派了同设备 PointerRemovedEvent → 设备表已空');
      expect(probe.libraryEverHovered, isFalse,
          reason: '失去栈顶帧末的注销早于 MouseTracker 帧末重命中，'
              'pop 过渡的任何一帧下层卡都不该被判 hover');
      expect(probe.libraryHovered, isFalse);

      // 正向对照：真实鼠标移到同一位置，卡片必须照常悬停——证明上面的 isFalse 不是
      // 探针失灵。
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

    testWidgets('dispose 里同步注销（第一版写法）：pop 时撞 widget tree locked 断言', (
      WidgetTester tester,
    ) async {
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayerAndPoke(tester, probe,
          retire: _RetireMode.syncInDispose);
      // 自管 onError：锁态断言之后框架每帧还会连带报错，testWidgets 会把多个异常包成
      // 一条「Multiple exceptions」，拿不到原始文案；收集全部、断言前还原。
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        await _popPlayer(tester, probe);
      } finally {
        FlutterError.onError = previous;
        // 锁态断言从 `_deviceUpdatePhase` 里抛出，把 MouseTracker 卡在
        // `_debugDuringDeviceUpdate == true`，之后每一帧的 updateAllDevices 都再断言——
        // 连 flutter_test 自己的收尾 runApp 也会红。必须在这里（而不是 tearDown，那已经
        // 晚于收尾 runApp）换一个新 tracker。
        RendererBinding.instance.initMouseTracker();
      }

      expect(
        errors.map((FlutterErrorDetails d) => '${d.exception}'),
        anyElement(contains('locked')),
        reason: 'finalizeTree 锁态内派 remove → 下层卡 onExit → setState 必炸',
      );
    });

    testWidgets('失去栈顶时注销：pushReplacement 换页，新页 region 从未被幽灵指针进入', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pushPlayerAndPoke(tester, probe, retire: _RetireMode.onLostTop);

      final BuildContext playerContext =
          tester.element(find.byKey(const ValueKey<String>('player-A')));
      Navigator.of(playerContext).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => _PlayerStub(
            id: 'B',
            probe: probe,
            retire: _RetireMode.onLostTop,
          ),
        ),
      );
      await _pumpTransition(tester, probe);

      expect(tester.takeException(), isNull);
      expect(probe.entered.contains('B'), isFalse,
          reason: '旧页失去栈顶那一帧帧末就注销了，新页 MouseRegion 不该收到幽灵 onEnter');
      expect(probe.exited.contains('B'), isFalse,
          reason: '新页更不该被 remove 触发 onExit（那会把它刚露出的控制条藏掉）');
      expect(RendererBinding.instance.mouseTracker.mouseIsConnected, isFalse);
    });
  });

  group('RouteTopListener 边沿语义', () {
    testWidgets('被压 → 一次；对方弹走后重回栈顶不回调；自己被 pop → 再一次', (
      WidgetTester tester,
    ) async {
      int lostTop = 0;
      await tester.pumpWidget(
        MaterialApp(home: _Anchor(onLostTop: () => lostTop++)),
      );
      final BuildContext anchor =
          tester.element(find.byKey(const ValueKey<String>('anchor')));
      expect(lostTop, 0, reason: '入场阶段本路由就是栈顶');

      Navigator.of(anchor).push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
      );
      await tester.pumpAndSettle();
      expect(lostTop, 1, reason: '新路由压上来 = 失去栈顶');

      Navigator.of(anchor).pop();
      await tester.pumpAndSettle();
      expect(lostTop, 1, reason: '重回栈顶不是失去栈顶');

      // 重回栈顶后再被压一次 → 再次失去栈顶，边沿再回调一次。
      Navigator.of(anchor).push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()),
      );
      await tester.pumpAndSettle();
      expect(lostTop, 2);
    });

    testWidgets('不在任何路由里（直接 pumpWidget）永不回调', (
      WidgetTester tester,
    ) async {
      int lostTop = 0;
      await tester.pumpWidget(
        RouteTopListener(
          onLostTop: () => lostTop++,
          child: const SizedBox.expand(),
        ),
      );
      await tester.pumpWidget(const SizedBox.expand());
      expect(lostTop, 0);
    });
  });

  group('源码守卫：合成设备随播放页失去栈顶注销（BUG-2453）', () {
    late String src;
    setUpAll(() {
      src = readVideoFushiSource();
    });

    test('测试用设备号与生产常量一致', () {
      expect(
        containsCodeLine(
            src, '_syntheticHoverDevice = $_kSyntheticDeviceLiteral;'),
        isTrue,
        reason: '本测试复刻的设备号必须与 _VideoFushiPageState._syntheticHoverDevice 同值',
      );
    });

    test('build 用 RouteTopListener 包整页，失去栈顶 → _retireSyntheticHoverDevice', () {
      expect(containsCodeLine(src, 'child: RouteTopListener('), isTrue,
          reason: '路由依赖必须落在透传叶子上，不能落在页面 State（每个弹窗整页重建）');
      expect(
        containsCodeLine(src, 'onLostTop: _retireSyntheticHoverDevice,'),
        isTrue,
        reason: 'BUG-2453：注销挂在失去栈顶那一帧的帧末',
      );
      expect(
        containsCodeLine(src, '_attachSyntheticHoverRouteListeners'),
        isFalse,
        reason:
            '页面 State 不再自己 ModalRoute.of 挂监听（审查：整页成为 _ModalScopeStatus 依赖者）',
      );
    });

    test('_retireSyntheticHoverDevice 派同设备的 PointerRemovedEvent', () {
      final String body = methodBody(src, 'void _retireSyntheticHoverDevice()');
      expect(containsCodeLine(body, '_pendingPokeHover = null;'), isTrue,
          reason: '注销同时丢弃待派发的 poke');
      expect(containsCodeLine(body, 'PointerRemovedEvent('), isTrue,
          reason: '注销只能靠 PointerRemovedEvent：MouseTracker 只认它删设备');
      expect(
        containsCodeLine(
            body, 'device: _VideoFushiPageState._syntheticHoverDevice,'),
        isTrue,
        reason: '必须是同一个设备号，否则删不到那条设备状态',
      );
      expect(containsCodeLine(body, 'kind: PointerDeviceKind.mouse,'), isTrue,
          reason: 'kind 须与派发时一致（MouseTracker 只跟踪 mouse/stylus）');
      expect(
        containsCodeLine(body, 'GestureBinding.instance.handlePointerEvent('),
        isTrue,
        reason: '须经 GestureBinding 派发，走与合成 hover 相同的管线',
      );
      final int flagOff = body.indexOf('_syntheticHoverDeviceLive = false;');
      final int dispatch =
          body.indexOf('GestureBinding.instance.handlePointerEvent(');
      expect(flagOff, greaterThanOrEqualTo(0));
      expect(dispatch, greaterThan(flagOff), reason: '「在册」旗在派发前清零，派发抛异常也不会重复派');
    });

    test('dispose 不派任何指针事件（finalizeTree 锁态）', () {
      // 语料主壳在前，首个 `void dispose()` 即播放页 State 的（另一处是文件末尾的
      // _VideoRepeatGestureButtonState）。
      final String body = methodBody(src, 'void dispose()');
      expect(containsCodeLine(body, 'handlePointerEvent('), isFalse,
          reason: 'dispose 跑在锁态内，同步派指针事件会让下层卡 setState 撞断言');
      expect(containsCodeLine(body, '_retireSyntheticHoverDevice();'), isFalse,
          reason: '注销点在失去栈顶，不在 dispose');
    });

    test('_dispatchPokeHover 真派发前登记设备在册（决定要不要注销）', () {
      final String body = methodBody(src, 'void _dispatchPokeHover()');
      expect(
          containsCodeLine(body, '_syntheticHoverDeviceLive = true;'), isTrue,
          reason: '真派发过才登记在册；从没派过（移动端）不往管线塞事件');
      final int live = body.indexOf('_syntheticHoverDeviceLive = true;');
      final int dispatch =
          body.indexOf('GestureBinding.instance.handlePointerEvent(event);');
      expect(dispatch, greaterThan(live), reason: '登记必须在派发之前，派发抛异常也不能漏注销');
    });
  });
}

/// 与 `_VideoFushiPageState._syntheticHoverDevice` 同值（'hibk'）。
const int _kSyntheticDevice = 0x6869626B;
const String _kSyntheticDeviceLiteral = '0x6869626B';

/// 与生产 `_retireSyntheticHoverDevice` 同构的注销；tearDown 里也用它兜底，避免复现用例
/// 把幽灵设备留给同进程的后续测试。对不在册的设备是框架层 no-op。
void _retireSyntheticDevice() {
  GestureBinding.instance.handlePointerEvent(
    const PointerRemovedEvent(
      device: _kSyntheticDevice,
      kind: PointerDeviceKind.mouse,
    ),
  );
}

enum _RetireMode {
  /// 修复前：从不注销。
  never,

  /// 第一版修法：dispose 里同步派 remove（审查打回的形态）。
  syncInDispose,

  /// 修复同构：真 [RouteTopListener] 在失去栈顶帧末派 remove。
  onLostTop,
}

class _HoverProbe {
  /// 各播放页桩 MouseRegion 收到过 onEnter / onExit 的 id。
  final Set<String> entered = <String>{};
  final Set<String> exited = <String>{};

  /// 库页桩里 [FushiHoverLift] 最近一次 build 拿到的 hover 态 / 是否曾为真。
  bool? libraryHovered;
  bool libraryEverHovered = false;
}

/// 从库页桩 push 播放页桩（真 MaterialPageRoute 过渡），过渡完成后派一条与生产同构的
/// 合成 hover 到屏幕中心。
Future<void> _pushPlayerAndPoke(
  WidgetTester tester,
  _HoverProbe probe, {
  required _RetireMode retire,
}) async {
  await tester.pumpWidget(MaterialApp(home: _LibraryStub(probe: probe)));
  final BuildContext libraryContext =
      tester.element(find.byKey(const ValueKey<String>('library')));
  Navigator.of(libraryContext).push(
    MaterialPageRoute<void>(
      builder: (_) => _PlayerStub(id: 'A', probe: probe, retire: retire),
    ),
  );
  await tester.pumpAndSettle();
  probe.libraryEverHovered = false;

  final Offset center = tester.getCenter(find.byType(_PlayerStub));
  // 与 `_dispatchPokeHover` 同构：固定设备号 + mouse kind + 视频区中心。
  GestureBinding.instance.handlePointerEvent(
    PointerHoverEvent(
      position: center,
      device: _kSyntheticDevice,
      kind: PointerDeviceKind.mouse,
    ),
  );
  await tester.pump();
  expect(probe.entered.contains('A'), isTrue,
      reason: '合成 hover 应先命中播放页桩的 MouseRegion（管线有效的前提）');
}

/// pop 播放页桩并逐帧走完反向过渡（每帧采样库页卡 hover 态），最后再多 pump 两帧让
/// 帧末重命中 / setState 落定。
Future<void> _popPlayer(WidgetTester tester, _HoverProbe probe) async {
  final BuildContext playerContext =
      tester.element(find.byKey(const ValueKey<String>('player-A')));
  Navigator.of(playerContext).pop();
  await _pumpTransition(tester, probe);
}

Future<void> _pumpTransition(WidgetTester tester, _HoverProbe probe) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
  await tester.pump();
  await tester.pump();
}

class _PlayerStub extends StatefulWidget {
  _PlayerStub({required this.id, required this.probe, required this.retire})
      : super(key: ValueKey<String>('player-$id'));

  final String id;
  final _HoverProbe probe;
  final _RetireMode retire;

  @override
  State<_PlayerStub> createState() => _PlayerStubState();
}

/// 播放页桩：只复刻「全画面 MouseRegion + 注销时机」，注销接线用**生产同款**
/// [RouteTopListener]。
class _PlayerStubState extends State<_PlayerStub> {
  @override
  void dispose() {
    if (widget.retire == _RetireMode.syncInDispose) _retireSyntheticDevice();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget region = SizedBox.expand(
      child: MouseRegion(
        onEnter: (_) => widget.probe.entered.add(widget.id),
        onExit: (_) => widget.probe.exited.add(widget.id),
        child: const ColoredBox(color: Colors.black),
      ),
    );
    if (widget.retire != _RetireMode.onLostTop) return region;
    return RouteTopListener(onLostTop: _retireSyntheticDevice, child: region);
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

/// [RouteTopListener] 语义测试用的锚点页。
class _Anchor extends StatelessWidget {
  const _Anchor({required this.onLostTop})
      : super(key: const ValueKey<String>('anchor'));

  final VoidCallback onLostTop;

  @override
  Widget build(BuildContext context) {
    return RouteTopListener(
      onLostTop: onLostTop,
      child: const Scaffold(body: SizedBox.expand()),
    );
  }
}
