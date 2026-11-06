import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 平台视图纹理按「屏幕上真实的物理像素密度」栅格化（复习卡面发糊）。
///
/// 根因：纹理尺寸 / WebView2 栅格倍率只用 `View.devicePixelRatio`，而 app 的「界面大小」
/// 在整棵树外包了一层 `FittedBox` 缩放（桌面自动值 0.88~1.16）。按 dpr 栅格化的纹理被
/// 再放大 1.06~1.16 倍显示（`Texture` 默认 `FilterQuality.none`），整面文字发糊。
/// 修复后尺寸上报的倍率 = dpr × 祖先缩放；位置上报仍是 dpr（native 用它还原窗口坐标与
/// 滚轮倍率）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('surfaceRasterScale', () {
    test('无祖先缩放 = dpr', () {
      expect(
        surfaceRasterScale(
          devicePixelRatio: 1.5,
          transform: Matrix4.translationValues(10, 20, 0),
          size: const Size(300, 200),
        ),
        1.5,
      );
    });

    test('祖先等比缩放乘进栅格倍率', () {
      expect(
        surfaceRasterScale(
          devicePixelRatio: 1.25,
          transform: Matrix4.diagonal3Values(1.16, 1.16, 1),
          size: const Size(300, 200),
        ),
        closeTo(1.25 * 1.16, 1e-9),
      );
    });

    test('缩放又中和回来的浮点残差按 1 算（不让 native 取整少 1 像素）', () {
      const double s = 1.155;
      expect(
        surfaceRasterScale(
          devicePixelRatio: 1.5,
          transform: Matrix4.diagonal3Values(s * (1 / s), s * (1 / s), 1)
            ..scaleByDouble(1 - 1e-12, 1 - 1e-12, 1, 1),
          size: const Size(800, 600),
        ),
        1.5,
      );
    });

    test('两轴不等取较大的一轴（不欠采样）', () {
      expect(
        surfaceRasterScale(
          devicePixelRatio: 1,
          transform: Matrix4.diagonal3Values(0.9, 1.2, 1),
          size: const Size(300, 200),
        ),
        closeTo(1.2, 1e-9),
      );
    });

    test('退化变换（缩到 0 / 不足 1 物理像素）退回 dpr', () {
      expect(
        surfaceRasterScale(
          devicePixelRatio: 2,
          transform: Matrix4.diagonal3Values(0, 0, 1),
          size: const Size(300, 200),
        ),
        2,
      );
      expect(
        surfaceRasterScale(
          devicePixelRatio: 1,
          transform: Matrix4.diagonal3Values(0.001, 0.001, 1),
          size: const Size(300, 200),
        ),
        1,
      );
    });
  });

  group('CustomPlatformView 在缩放子树里', () {
    const MethodChannel manager = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_manager',
    );
    const MethodChannel view = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_7',
    );
    const MethodChannel events = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_7_events',
    );
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(manager, (MethodCall call) async {
        if (call.method == 'createInAppWebView') return 7;
        return null;
      });
      messenger.setMockMethodCallHandler(view, (MethodCall call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (MethodCall call) async {
        return null;
      });
    });

    tearDown(() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final MethodChannel c in <MethodChannel>[manager, view, events]) {
        messenger.setMockMethodCallHandler(c, null);
      }
    });

    Widget host(double scale) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topLeft,
          child: const SizedBox(
            width: 200,
            height: 100,
            child: CustomPlatformView(),
          ),
        ),
      ),
    );

    List<List<Object?>> argsOf(String method) => <List<Object?>>[
      for (final MethodCall c in calls)
        if (c.method == method) (c.arguments as List<Object?>),
    ];

    testWidgets('尺寸按 dpr × 祖先缩放上报，位置仍按 dpr', (WidgetTester tester) async {
      final double dpr = tester.view.devicePixelRatio;
      await tester.pumpWidget(host(1.25));
      await tester.pump();
      await tester.pump();

      final List<List<Object?>> sizes = argsOf('setSize');
      expect(sizes, isNotEmpty);
      expect(sizes.last[0], 200);
      expect(sizes.last[1], 100);
      expect(sizes.last[2] as double, closeTo(dpr * 1.25, 1e-9));

      final List<List<Object?>> positions = argsOf('setPosition');
      expect(positions, isNotEmpty);
      expect(positions.last[2], dpr);
    });

    testWidgets('祖先缩放变了：稳定一帧后按新倍率重报一次，动画中途不逐帧重报', (WidgetTester tester) async {
      final double dpr = tester.view.devicePixelRatio;
      await tester.pumpWidget(host(1.25));
      await tester.pump();
      await tester.pump();
      calls.clear();

      // 布局尺寸不变（Transform 不改布局），只有绘制缩放变：没有 SizeChanged 通知。
      await tester.pumpWidget(host(1.5));
      expect(argsOf('setSize'), isEmpty, reason: '第一帧量到新倍率，尚未确认稳定');
      await tester.pump();
      final List<List<Object?>> sizes = argsOf('setSize');
      expect(sizes, hasLength(1));
      expect(sizes.single[2] as double, closeTo(dpr * 1.5, 1e-9));

      // 静止后不再重报（去重）。
      await tester.pump();
      await tester.pump();
      expect(argsOf('setSize'), hasLength(1));
    });
  });
}
