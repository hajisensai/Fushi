// BUG-1451 调查副产物，转成常驻守卫：查词弹窗 Windows 右键菜单的**锚点**必须贴住
// 鼠标，在「界面大小≠100%」下也不例外。
//
// 为什么值得单独锁：这是 BUG-129/260/261/381/781 反复回归的同一族——菜单永远渲染在
// **中和器之外**（showMenu 把 PopupMenuRoute 推到根 Overlay，而根 Overlay 在全局
// HibikiAppUiScale 的 FittedBox 之内 = 缩放画布空间），而查词浮层子树在**中和器之内**
// （净缩放=1 = 真实视口空间）。两套坐标差一个 factor=scale，把真实视口坐标直接当
// RelativeRect 喂 showMenu，菜单就渲染在「点击点×scale」处。
//
// 本测试复刻真实层级：根 Overlay 手动 insert 的 entry + HibikiAppUiScaleNeutralizer +
// 弹窗 Positioned 盒，然后按 dictionary_popup_webview.dart `_showWindowsContextMenu`
// 的同一算法定位，断言菜单贴住点击点。
//
// 度量纪律：Flutter 在点击点靠近右/下边缘时会把菜单反向展开（右边缘/底边对齐点击点），
// 这是**正确**行为。所以断言用「点到菜单矩形的距离」，不是 topLeft 差值。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

/// 与 `_showWindowsContextMenu` 完全同形的锚点算法（保持两处一致；算法一旦在实现里
/// 改坏，这里的断言不会自动跟着坏 —— 故实现侧另有源码扫描守卫盯 `globalToLocal`）。
Future<void> _showMenuLikePopup(
    BuildContext context, Offset globalPosition) async {
  final RenderObject? overlayObject =
      Overlay.of(context).context.findRenderObject();
  if (overlayObject is! RenderBox || !overlayObject.hasSize) return;
  final Offset anchor = overlayObject.globalToLocal(globalPosition);
  final Size overlaySize = overlayObject.size;
  final RelativeRect position = RelativeRect.fromLTRB(
    anchor.dx,
    anchor.dy,
    overlaySize.width - anchor.dx,
    overlaySize.height - anchor.dy,
  );
  await showMenu<String>(
    context: context,
    position: position,
    items: const <PopupMenuEntry<String>>[
      PopupMenuItem<String>(value: 'search', child: Text('SEARCH')),
      PopupMenuItem<String>(value: 'copy', child: Text('COPY')),
    ],
  );
}

class _HostPage extends StatefulWidget {
  const _HostPage();

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    // 镜像 video_hibiki_page._ensurePopupOverlay：插到**根** Overlay，跨路由生存。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
      _entry = entry;
      overlay.insert(entry);
    });
  }

  // 镜像 video_hibiki_page._buildPopupOverlay：整棵浮层子树中和回真实视口。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    return HibikiAppUiScaleNeutralizer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: 150,
                top: 150,
                width: 400,
                height: 300,
                child: Builder(
                  builder: (BuildContext popupContext) => GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapDown: (TapDownDetails details) =>
                        _showMenuLikePopup(
                            popupContext, details.globalPosition),
                    child: const ColoredBox(color: Color(0xFF224466)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: ColoredBox(color: Color(0xFF000000)));
}

/// 度量：菜单左上角相对点击点的偏移。
///
/// 刻意**不**用「点到菜单矩形的距离」——缩小方向（scale<1）下锚点算错时菜单会渲染在
/// 点击点的左上方、矩形反而把点击点包进去，距离恒为 0 = 假绿（本守卫的变异实测踩到过）。
/// 菜单左上角是唯一对两个方向都敏感的量。
///
/// 只在「点击点远离视口右/下边缘」时才是正确判据：贴边时 Flutter 会把菜单反向展开
/// （右/下边缘对齐点击点），那是**正确**行为。本测试的点击点固定在中央，不触发反向展开。
Offset _menuTopLeftOffset(Offset tapAt, Rect menu) => menu.topLeft - tapAt;

Future<Rect> _rightClickAndMeasureMenu(
    WidgetTester tester, double scale, Offset tapAt) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          HibikiAppUiScale(scale: scale, child: child!),
      home: const _HostPage(),
    ),
  );
  await tester.pumpAndSettle();

  final TestGesture gesture = await tester.startGesture(
    tapAt,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pumpAndSettle();

  expect(find.text('COPY'), findsOneWidget, reason: '右键必须弹出弹窗自己的菜单');
  // 菜单整体矩形：取两项的并集。
  final Rect first = tester.getRect(find.ancestor(
    of: find.text('SEARCH'),
    matching: find.byType(PopupMenuItem<String>),
  ));
  final Rect second = tester.getRect(find.ancestor(
    of: find.text('COPY'),
    matching: find.byType(PopupMenuItem<String>),
  ));
  return first.expandToInclude(second);
}

void main() {
  // 菜单与点击点之间只应隔着 PopupMenu 自己的 vertical padding（8 逻辑像素），
  // 它渲染在缩放画布里，故屏幕上表现为 8×scale。留一点余量吸收 Material 版本差异。
  double tolerance(double scale) => 8 * scale + 4;

  /// 菜单左上角必须与点击点对齐（x 同列，y 只隔菜单自己的 vertical padding）。
  void expectAnchored(Offset tapAt, Rect menu, double scale) {
    final Offset delta = _menuTopLeftOffset(tapAt, menu);
    final double tol = tolerance(scale);
    expect(delta.dx.abs(), lessThanOrEqualTo(tol),
        reason: '菜单左边缘应与点击点同列，实测偏移=$delta 菜单矩形=$menu');
    expect(delta.dy, inInclusiveRange(0, tol),
        reason: '菜单应紧贴点击点下方（只隔 8×scale 的 padding），'
            '实测偏移=$delta 菜单矩形=$menu');
  }

  testWidgets('界面大小=100%：右键菜单贴住鼠标', (WidgetTester tester) async {
    const Offset tapAt = Offset(300, 250);
    expectAnchored(
        tapAt, await _rightClickAndMeasureMenu(tester, 1.0, tapAt), 1.0);
  });

  testWidgets('界面大小=150%：菜单仍贴住鼠标（不得偏 factor=scale）',
      (WidgetTester tester) async {
    // 回归形态：锚点没换算时菜单渲染在 (300,250)×1.5=(450,375) 附近，远超容差。
    const Offset tapAt = Offset(300, 250);
    expectAnchored(
        tapAt, await _rightClickAndMeasureMenu(tester, 1.5, tapAt), 1.5);
  });

  testWidgets('界面大小=80%：菜单仍贴住鼠标', (WidgetTester tester) async {
    // 回归形态：菜单渲染在 (300,250)×0.8=(240,200)，落在点击点**左上方**。
    const Offset tapAt = Offset(300, 250);
    expectAnchored(
        tapAt, await _rightClickAndMeasureMenu(tester, 0.8, tapAt), 0.8);
  });
}
