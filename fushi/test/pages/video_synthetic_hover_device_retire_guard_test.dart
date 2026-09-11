import 'package:flutter/foundation.dart';
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
/// 根因：`_pokeControlsVisible` 用固定设备号 `_syntheticHoverDevice` 派合成
/// [PointerHoverEvent] 到视频区几何中心唤醒 media_kit 控制条。Flutter `MouseTracker`
/// 会为这个设备建一条**真实的设备状态**，且只在收到同设备的 [PointerRemovedEvent]
/// 时才删；此前全仓没人派过这个 remove。于是退出播放器后，幽灵指针永远停在屏幕中心，
/// 每帧帧末 `updateAllDevices` 都在那一点命中测试，落在那的 `MouseRegion`（库页卡片
/// 的 [FushiHoverLift]）收到 onEnter → 放大。
///
/// 修复：在本页**失去栈顶**那一刻（自己路由的动画进入 `reverse` = 被 pop；次动画进入
/// `forward` = 新路由压上来 / `pushReplacement` 替换）排一个 post-frame 派同设备
/// [PointerRemovedEvent]。**不能**放在 `dispose()` 里同步派：dispose 跑在 finalizeTree
/// 锁态内，pop 过渡期间幽灵指针早已进到下层库页的卡上，remove 触发那张卡
/// `onExit → setState` 撞「widget tree was locked」断言；`pushReplacement` 时还会把新页
/// 刚露出的控制条藏掉。也不能在每次 hover 后立刻注销：media_kit fork 的 `onExit`
/// 无条件把控制条藏掉。
///
/// 两层守卫：
/// ① 行为层：真 Navigator（push / pop / pushReplacement 带过渡）+ 真 [FushiHoverLift]，
///    在 Flutter 真实 `MouseTracker` 上复现「不注销 → pop 后下层中心卡被判 hover」，
///    并证明「失去栈顶时注销（修复同构）→ pop 全程下层卡从未被判 hover、无任何断言、
///    真实鼠标照常可悬停；pushReplacement 时新页 region 从未被幽灵指针进入」。
///    media_kit 视频部件 headless 跑不了，故播放页本体走 ② 源码守卫。
/// ② 源码层：钉住 `didChangeDependencies` 挂路由监听、两条监听各看哪个状态、
///    注销走 post-frame、`dispose` 只摘监听不派事件、`_dispatchPokeHover` 派发前登记在册。
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
          reason: 'post-frame 派了同设备 PointerRemovedEvent → 设备表已空');
      expect(probe.libraryEverHovered, isFalse,
          reason: 'post-frame 注销早于 MouseTracker 帧末重命中，'
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

    test('didChangeDependencies 给本页路由挂失去栈顶监听', () {
      final String body = methodBody(src, 'void didChangeDependencies()');
      expect(
        containsCodeLine(body,
            '_attachSyntheticHoverRouteListeners(ModalRoute.of(context));'),
        isTrue,
        reason: 'BUG-2453：注销判据挂在本页路由的动画状态上',
      );
    });

    test('两条监听各看正确的状态：自身 reverse = 被 pop，覆盖者 forward = 被压 / 被替换', () {
      final String own =
          methodBody(src, 'void _onSyntheticHoverOwnRouteStatus(');
      expect(containsCodeLine(own, 'AnimationStatus.reverse'), isTrue);
      expect(containsCodeLine(own, '_retireSyntheticHoverDevice();'), isTrue);
      final String covering =
          methodBody(src, 'void _onSyntheticHoverCoveringRouteStatus(');
      expect(containsCodeLine(covering, 'AnimationStatus.forward'), isTrue);
      expect(
          containsCodeLine(covering, '_retireSyntheticHoverDevice();'), isTrue);
      final String attach =
          methodBody(src, 'void _attachSyntheticHoverRouteListeners(');
      expect(
        containsCodeLine(attach,
            'route?.animation?.addStatusListener(_onSyntheticHoverOwnRouteStatus);'),
        isTrue,
        reason: '自身动画 → own 监听',
      );
      expect(
        containsCodeLine(attach,
            '?.addStatusListener(_onSyntheticHoverCoveringRouteStatus);'),
        isTrue,
        reason: '次动画 → covering 监听',
      );
    });

    test('_retireSyntheticHoverDevice 在 post-frame 里派同设备 PointerRemovedEvent',
        () {
      final String body = methodBody(src, 'void _retireSyntheticHoverDevice()');
      expect(containsCodeLine(body, '_pendingPokeHover = null;'), isTrue,
          reason: '注销同时丢弃待派发的 poke');
      expect(
        containsCodeLine(body, 'WidgetsBinding.instance.addPostFrameCallback('),
        isTrue,
        reason: '派发必须延到帧末：调用点可能在 MouseTracker 迭代栈里，'
            '且 post-frame 早于 MouseTracker 帧末重命中',
      );
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
      final int flagOff = body.indexOf('_syntheticHoverDeviceLive = false;');
      final int postFrame = body.indexOf('addPostFrameCallback(');
      expect(flagOff, greaterThan(postFrame),
          reason: '「在册」旗在真正派发那一刻清零（排队到派发之间的 poke 也会被删掉）');
    });

    test('dispose 只摘路由监听、不派任何指针事件（finalizeTree 锁态）', () {
      // 语料主壳在前，首个 `void dispose()` 即播放页 State 的（另一处是文件末尾的
      // _VideoRepeatGestureButtonState）。
      final String body = methodBody(src, 'void dispose()');
      expect(containsCodeLine(body, '_detachSyntheticHoverRouteListeners();'),
          isTrue,
          reason: '路由监听随 State 摘掉');
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

/// tearDown 兜底：避免复现用例把幽灵设备留给同进程的后续测试。对不在册的设备是框架层
/// no-op。
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

  /// 修复同构：失去栈顶那一刻排 post-frame 派 remove。
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
  // 入场期间库页在下层，可能被空的设备表之外的东西……不会：此时还没有任何设备。
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

/// 与生产 `_attachSyntheticHoverRouteListeners` / `_retireSyntheticHoverDevice` 同构。
class _PlayerStubState extends State<_PlayerStub> {
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _detach();
    _route = route;
    if (widget.retire == _RetireMode.onLostTop) {
      route?.animation?.addStatusListener(_onOwnStatus);
      route?.secondaryAnimation?.addStatusListener(_onCoveringStatus);
    }
  }

  void _onOwnStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _retireOnLostTop();
  }

  void _onCoveringStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward) _retireOnLostTop();
  }

  void _retireOnLostTop() {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _retireSyntheticDevice());
  }

  void _detach() {
    _route?.animation?.removeStatusListener(_onOwnStatus);
    _route?.secondaryAnimation?.removeStatusListener(_onCoveringStatus);
    _route = null;
  }

  @override
  void dispose() {
    _detach();
    if (widget.retire == _RetireMode.syncInDispose) _retireSyntheticDevice();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: MouseRegion(
        onEnter: (_) => widget.probe.entered.add(widget.id),
        onExit: (_) => widget.probe.exited.add(widget.id),
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
