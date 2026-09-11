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
/// 修复：合成设备与播放页 State 同生共死——`dispose()` 里派同设备的
/// [PointerRemovedEvent]（`_retireSyntheticHoverDevice`）。不能在每次 hover 后立刻
/// 注销：media_kit fork 的 `onExit` 无条件把控制条藏掉，remove 会触发它。
///
/// 两层守卫：
/// ① 行为层：纯框架部件 + 真 [FushiHoverLift] 复现「不注销 → 下一页中心卡被判 hover」，
///    并证明「随页 dispose 注销 → 不再被判 hover，真实鼠标照常可悬停」（修复同构）。
///    media_kit 视频部件 headless 跑不了，故播放页本体走 ② 源码守卫。
/// ② 源码层：钉住 `dispose()` 调 `_retireSyntheticHoverDevice()`、后者派同设备
///    [PointerRemovedEvent]、`_dispatchPokeHover` 真派发前登记设备在册。
void main() {
  group('行为复现：合成 hover 设备跨页残留（BUG-2453）', () {
    testWidgets('不注销：下一页落在合成位置上的 FushiHoverLift 被判 hover（复现）', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pumpPlayerThenLibrary(
        tester,
        probe: probe,
        retireOnDispose: false,
      );
      expect(
        RendererBinding.instance.mouseTracker.mouseIsConnected,
        isTrue,
        reason: '没派 remove 时合成设备仍在 MouseTracker 在册',
      );
      expect(
        probe.libraryHovered,
        isTrue,
        reason: '幽灵指针停在屏幕中心 → 中心那张卡被当成鼠标悬停（BUG-2453 症状）',
      );
    });

    testWidgets('随页 dispose 注销：下一页卡片不再被幽灵指针悬停，真实鼠标照常可悬停', (
      WidgetTester tester,
    ) async {
      addTearDown(_retireSyntheticDevice);
      final _HoverProbe probe = _HoverProbe();
      await _pumpPlayerThenLibrary(tester, probe: probe, retireOnDispose: true);
      expect(
        RendererBinding.instance.mouseTracker.mouseIsConnected,
        isFalse,
        reason: 'dispose 派了同设备 PointerRemovedEvent → MouseTracker 已无任何设备',
      );
      expect(probe.libraryHovered, isFalse, reason: '合成设备已注销，中心卡不该再被判 hover');

      // 正向对照：真实鼠标移到同一位置，卡片必须照常悬停——证明上面的 isFalse 不是
      // 探针失灵。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(() => mouse.removePointer());
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byType(FushiHoverLift)));
      await tester.pump();
      await tester.pump();
      expect(probe.libraryHovered, isTrue, reason: '真实鼠标悬停仍应生效');
    });
  });

  group('源码守卫：合成设备随播放页 dispose 注销（BUG-2453）', () {
    late String src;
    setUpAll(() {
      src = readVideoFushiSource();
    });

    test('测试用设备号与生产常量一致', () {
      expect(
        src.contains('_syntheticHoverDevice = $_kSyntheticDeviceLiteral;'),
        isTrue,
        reason: '本测试复刻的设备号必须与 _VideoFushiPageState._syntheticHoverDevice 同值',
      );
    });

    test('_VideoFushiPageState.dispose 调用 _retireSyntheticHoverDevice', () {
      // 语料主壳在前，首个 `void dispose()` 即播放页 State 的（另一处是文件末尾的
      // _VideoRepeatGestureButtonState）。
      final String body = methodBody(src, 'void dispose()');
      expect(
        body.contains('_retireSyntheticHoverDevice();'),
        isTrue,
        reason: 'BUG-2453：播放页 dispose 必须注销合成 hover 设备',
      );
    });

    test('_retireSyntheticHoverDevice 派同设备的 PointerRemovedEvent', () {
      final String body = methodBody(src, 'void _retireSyntheticHoverDevice()');
      expect(
        body.contains('PointerRemovedEvent('),
        isTrue,
        reason: '注销只能靠 PointerRemovedEvent：MouseTracker 只认它删设备',
      );
      expect(
        body.contains('device: _VideoFushiPageState._syntheticHoverDevice'),
        isTrue,
        reason: '必须是同一个设备号，否则删不到那条设备状态',
      );
      expect(
        body.contains('kind: PointerDeviceKind.mouse'),
        isTrue,
        reason: 'kind 须与派发时一致（MouseTracker 只跟踪 mouse/stylus）',
      );
      expect(
        body.contains('GestureBinding.instance.handlePointerEvent'),
        isTrue,
        reason: '须经 GestureBinding 派发，走与合成 hover 相同的管线',
      );
      expect(
        body.contains('_pendingPokeHover = null;'),
        isTrue,
        reason: '注销同时丢弃待派发的 poke，杜绝注销后再冒出新设备',
      );
    });

    test('_dispatchPokeHover 真派发前登记设备在册（决定 dispose 要不要注销）', () {
      final String body = methodBody(src, 'void _dispatchPokeHover()');
      final int live = body.indexOf('_syntheticHoverDeviceLive = true;');
      final int dispatch = body.indexOf(
        'GestureBinding.instance.handlePointerEvent(event);',
      );
      expect(
        live,
        greaterThanOrEqualTo(0),
        reason: '真派发过才登记在册；从没派过（移动端）dispose 不往管线塞事件',
      );
      expect(dispatch, greaterThan(live), reason: '登记必须在派发之前，派发抛异常也不能漏注销');
    });
  });
}

/// 与 `_VideoFushiPageState._syntheticHoverDevice` 同值（'hibk'）。
const int _kSyntheticDevice = 0x6869626B;
const String _kSyntheticDeviceLiteral = '0x6869626B';

/// 与生产 `_retireSyntheticHoverDevice` 同构的注销；tearDown 里也用它兜底，避免
/// 复现用例把幽灵设备留给同进程的后续测试。对不在册的设备是框架层 no-op。
void _retireSyntheticDevice() {
  GestureBinding.instance.handlePointerEvent(
    const PointerRemovedEvent(
      device: _kSyntheticDevice,
      kind: PointerDeviceKind.mouse,
    ),
  );
}

class _HoverProbe {
  /// 播放页桩的 MouseRegion 是否收到过合成 hover 的 onEnter（证明 poke 管线本身有效）。
  bool playerHovered = false;

  /// 库页桩里 [FushiHoverLift] 最近一次 build 拿到的 hover 态。
  bool? libraryHovered;
}

/// 先 pump「播放页桩」并派一条与生产同构的合成 hover 到屏幕中心，再整页换成
/// 「库页桩」（触发播放页桩 dispose），返回后 [probe] 里是库页卡片的 hover 态。
Future<void> _pumpPlayerThenLibrary(
  WidgetTester tester, {
  required _HoverProbe probe,
  required bool retireOnDispose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _PlayerStub(probe: probe, retireOnDispose: retireOnDispose),
    ),
  );
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
  expect(
    probe.playerHovered,
    isTrue,
    reason: '合成 hover 应先命中播放页桩的 MouseRegion（管线有效的前提）',
  );

  await tester.pumpWidget(MaterialApp(home: _LibraryStub(probe: probe)));
  // 帧末 MouseTracker.updateAllDevices 重新命中 → onEnter → setState → 再 pump 让
  // builder 拿到新 hover 态。
  await tester.pump();
  await tester.pump();
}

class _PlayerStub extends StatefulWidget {
  const _PlayerStub({required this.probe, required this.retireOnDispose});

  final _HoverProbe probe;
  final bool retireOnDispose;

  @override
  State<_PlayerStub> createState() => _PlayerStubState();
}

class _PlayerStubState extends State<_PlayerStub> {
  @override
  void dispose() {
    if (widget.retireOnDispose) _retireSyntheticDevice();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: MouseRegion(
        onEnter: (_) => widget.probe.playerHovered = true,
        onExit: (_) => widget.probe.playerHovered = false,
        child: const ColoredBox(color: Colors.black),
      ),
    );
  }
}

class _LibraryStub extends StatelessWidget {
  const _LibraryStub({required this.probe});

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
              return const ColoredBox(color: Colors.blue);
            },
          ),
        ),
      ),
    );
  }
}
