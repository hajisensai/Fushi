// 反馈 5hnsRtTrQj：视频查词弹窗（Android Hybrid Composition 的 InAppWebView，热槽
// 复用）偶发「滑不动、点词不触发、选区菜单关不掉，关掉重开仍坏」。
//
// 根因：[parkedPopupLayer] 按「本层被上层盖住没有」增删 [PopupOccluderClip] 这一层
// 包装（[PopupOccluderClip] 自己也按条件直接返回 child）。子弹窗入场就位 / 关闭会让
// 父层的 occluders 在空与非空之间翻转，父层里带 GlobalKey 的 WebView 被搬家；平台
// 视图 RenderBox 的 detach 调 `_gestureRecognizer.reset()`，正在转发的指针被直接丢掉、
// 不补 cancel，这根手指的 UP 再也到不了平台视图——controller 指针表里留下幽灵手指。
//
// 这里用真 [parkedPopupLayer] + 真 [PlatformViewSurface]（与生产同类的
// PlatformViewRenderBox 与手势转发），锁两件事：祖先结构恒定（RenderObject 不被
// detach），以及手指按住期间 occluders 翻转后，平台视图仍收到这根手指的抬起。

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:material_ui/material_ui.dart';

class _RecordingController extends PlatformViewController {
  final List<PointerEvent> events = <PointerEvent>[];

  @override
  int get viewId => 7;

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {
    events.add(event);
  }

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispose() async {}
}

/// 记录 detach 次数的叶子 RenderBox：祖先结构一变（搬家）就会被 detach。
class _DetachProbe extends LeafRenderObjectWidget {
  const _DetachProbe({super.key});

  @override
  _RenderDetachProbe createRenderObject(BuildContext context) =>
      _RenderDetachProbe();
}

class _RenderDetachProbe extends RenderBox {
  int detaches = 0;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void detach() {
    detaches++;
    super.detach();
  }
}

const Rect _pos = Rect.fromLTWH(20, 20, 300, 300);
const Size _screen = Size(800, 600);

Widget _host({
  required TargetPlatform platform,
  required bool visible,
  required List<Rect> occluders,
  required Widget child,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: Stack(
    clipBehavior: Clip.none,
    children: <Widget>[
      parkedPopupLayer(
        pos: _pos,
        visible: visible,
        screen: _screen,
        occluders: occluders,
        child: child,
      ),
    ],
  ),
);

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('$platform：occluders / visible 翻转不搬动弹窗内容', (
      WidgetTester tester,
    ) async {
      final GlobalKey probeKey = GlobalKey();
      Widget build({required bool visible, required List<Rect> occluders}) =>
          _host(
            platform: platform,
            visible: visible,
            occluders: occluders,
            child: _DetachProbe(key: probeKey),
          );
      await tester.pumpWidget(build(visible: true, occluders: const <Rect>[]));
      final _RenderDetachProbe box = tester.renderObject<_RenderDetachProbe>(
        find.byKey(probeKey),
      );
      const Rect child = Rect.fromLTWH(100, 100, 300, 300);
      for (final (bool visible, List<Rect> occluders) step
          in <(bool, List<Rect>)>[
            (true, const <Rect>[child]),
            (true, const <Rect>[]),
            (false, const <Rect>[child]),
            (true, const <Rect>[child]),
            (true, const <Rect>[]),
          ]) {
        await tester.pumpWidget(build(visible: step.$1, occluders: step.$2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.renderObject<_RenderDetachProbe>(find.byKey(probeKey)),
          same(box),
        );
      }
      expect(box.detaches, 0, reason: '平台视图上方的祖先结构必须恒定');
    });
  }

  testWidgets('手指按住期间子弹窗就位（occluders 翻转），平台视图仍收到这根手指的抬起', (
    WidgetTester tester,
  ) async {
    final _RecordingController controller = _RecordingController();
    final GlobalKey surfaceKey = GlobalKey();
    Widget build(List<Rect> occluders) => _host(
      platform: TargetPlatform.android,
      visible: true,
      occluders: occluders,
      child: PlatformViewSurface(
        key: surfaceKey,
        controller: controller,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
          Factory<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new,
          ),
        },
      ),
    );
    await tester.pumpWidget(build(const <Rect>[]));
    final TestGesture finger = await tester.startGesture(_pos.center);
    // 竖滑让平台视图的手势组胜出，开始把这根手指转发给 controller。
    await finger.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(controller.events.whereType<PointerDownEvent>(), hasLength(1));

    // 手指还按着：子弹窗淡入就位，父层 occluders 由空变非空。
    await tester.pumpWidget(
      build(const <Rect>[Rect.fromLTWH(120, 120, 300, 300)]),
    );
    await tester.pump();
    await finger.up();
    await tester.pump();

    final int downs = controller.events.whereType<PointerDownEvent>().length;
    final int ends = controller.events
        .where(
          (PointerEvent e) => e is PointerUpEvent || e is PointerCancelEvent,
        )
        .length;
    expect(ends, downs, reason: '每根按下的手指都要以抬起 / 取消收尾，不能留下幽灵手指');
  });
}
