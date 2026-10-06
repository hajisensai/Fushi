import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/reader/popup_swipe_close_script.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-2770：Windows 触屏不能滑动关闭查词弹窗。
///
/// `enable_swipe_to_close` 在 Windows/Linux 默认 false（BUG-299：鼠标框选与横拖同形），
/// 但这条默认值此前连**触摸**一起关掉了——正文触摸横拖检测器、顶栏 / 整卡
/// [SwipeDismissWrapper]、遮罩横拖、覆盖窗顶部下拉全部跟着失效。
///
/// 修复后的契约（本文件逐条钉住）：
///   * 未设置：触摸 / 触控笔所有平台默认能滑关；鼠标 / 触控板仍按平台默认
///     （Windows/Linux 关）。
///   * 显式关：触摸与鼠标都不能滑关。
///   * 显式开：触摸与鼠标都能滑关（与修复前相同）。
void main() {
  const Key headerKey = Key('bug2770-header');
  const Key bodyAnchorKey = Key('bug2770-body-anchor');
  const String prefKey = 'enable_swipe_to_close';

  final ReaderFushiSource source = ReaderFushiSource.instance;

  Future<void> resetPref() => source.deletePreference(key: prefKey);

  /// 与生产调用点（base_source_page / dictionary_page_mixin）同一种接法：两个开关
  /// 都直接取自 [ReaderFushiSource]，所以本测试走的是「偏好 → 弹窗」整条链。
  Widget popup({required VoidCallback onDismiss}) {
    return buildTestApp(
      Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            enableSwipeToClose: source.enableSwipeToClose,
            enableTouchSwipeToClose: source.enableTouchSwipeToClose,
            onClose: () {},
            headerWidget: const SizedBox(
              key: headerKey,
              height: 44,
              width: double.infinity,
              child: Center(child: Text('HEADER')),
            ),
            overlayWidget: const Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(key: bodyAnchorKey, height: 120, width: 200),
            ),
            onDismiss: onDismiss,
            onTextSelected: (String text, Rect rect) {},
            onLinkClick: (String query, Rect rect) {},
            onMineEntry: (Map<String, String> fields) async =>
                const MinePopupResult(),
            onDuplicateCheck: (String expression, String reading) async =>
                false,
          ),
        ),
      ),
    );
  }

  /// 推过滑动关闭的 200ms 位移动画（或回弹）。不用 pumpAndSettle：result==null
  /// 的 body 是延迟加载层（加载指示器常驻动画），永远等不到静止。
  Future<void> pumpPastSwipeAnimation(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> dragHorizontally(
    WidgetTester tester,
    Offset start, {
    required PointerDeviceKind kind,
    double distance = 240,
  }) async {
    final TestGesture gesture = await tester.startGesture(start, kind: kind);
    const int steps = 12;
    for (int i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(distance / steps, 0));
      await tester.pump();
    }
    await gesture.up();
    await pumpPastSwipeAnimation(tester);
  }

  Future<void> panZoomHorizontally(WidgetTester tester, Offset start) async {
    final TestPointer pointer = TestPointer(2770, PointerDeviceKind.trackpad);
    tester.binding.handlePointerEvent(pointer.panZoomStart(start));
    await tester.pump();
    double pan = 0;
    for (int i = 0; i < 12; i++) {
      pan += 20;
      tester.binding.handlePointerEvent(
        pointer.panZoomUpdate(start, pan: Offset(pan, 0)),
      );
      await tester.pump();
    }
    tester.binding.handlePointerEvent(pointer.panZoomEnd());
    await pumpPastSwipeAnimation(tester);
  }

  final TargetPlatformVariant windows = TargetPlatformVariant.only(
    TargetPlatform.windows,
  );

  group('ReaderFushiSource: 同一偏好键的鼠标 / 触摸两半', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Windows 未设置：鼠标关、触摸开，且与读取顺序无关', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await resetPref();
      // 先读鼠标半边：旧 getPreference 会把平台默认 false 回填进缓存，
      // 触摸半边随后就读成「用户显式关」。
      expect(source.enableSwipeToClose, isFalse);
      expect(source.enableTouchSwipeToClose, isTrue);
      expect(source.enableSwipeToClose, isFalse);
    });

    test('Android 未设置：两半都开', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await resetPref();
      expect(source.enableSwipeToClose, isTrue);
      expect(source.enableTouchSwipeToClose, isTrue);
    });

    test('显式关：两半都关；显式开：两半都开', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await source.setEnableSwipeToClose(false);
      expect(source.enableSwipeToClose, isFalse);
      expect(source.enableTouchSwipeToClose, isFalse);
      await source.setEnableSwipeToClose(true);
      expect(source.enableSwipeToClose, isTrue);
      expect(source.enableTouchSwipeToClose, isTrue);
      await resetPref();
    });

    test('BUG-299 鼠标防线的平台真值表不变', () {
      expect(
        ReaderSettings.defaultSwipeToClose(TargetPlatform.windows),
        isFalse,
      );
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.linux), isFalse);
    });
  });

  group('DictionaryPopupLayer：Windows 未设置偏好', () {
    testWidgets('触摸横拖顶栏能关', (WidgetTester tester) async {
      await resetPref();
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
        kind: PointerDeviceKind.touch,
      );
      expect(dismissed, isTrue);
    }, variant: windows);

    testWidgets('触摸横拖正文能关', (WidgetTester tester) async {
      await resetPref();
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      final Offset body = tester.getCenter(find.byKey(bodyAnchorKey));
      // 判别力：正文起手点在顶栏包装之外，证明关窗来自正文检测器。
      expect(
        tester.getRect(find.byType(SwipeDismissWrapper)).contains(body),
        isFalse,
      );
      await dragHorizontally(tester, body, kind: PointerDeviceKind.touch);
      expect(dismissed, isTrue);
    }, variant: windows);

    testWidgets('触控笔横拖顶栏能关', (WidgetTester tester) async {
      await resetPref();
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
        kind: PointerDeviceKind.stylus,
      );
      expect(dismissed, isTrue);
    }, variant: windows);

    testWidgets('鼠标横拖顶栏 / 正文都不关（BUG-299）', (WidgetTester tester) async {
      await resetPref();
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
        kind: PointerDeviceKind.mouse,
      );
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(bodyAnchorKey)),
        kind: PointerDeviceKind.mouse,
      );
      expect(dismissed, isFalse);
    }, variant: windows);

    testWidgets('触控板双指横扫顶栏不关', (WidgetTester tester) async {
      await resetPref();
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      await panZoomHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
      );
      expect(dismissed, isFalse);
    }, variant: windows);
  });

  group('DictionaryPopupLayer：Windows 显式设置', () {
    testWidgets('显式关：触摸横拖顶栏 / 正文都不关', (WidgetTester tester) async {
      await source.setEnableSwipeToClose(false);
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      expect(find.byType(SwipeDismissWrapper), findsNothing);
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
        kind: PointerDeviceKind.touch,
      );
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(bodyAnchorKey)),
        kind: PointerDeviceKind.touch,
      );
      expect(dismissed, isFalse);
      await resetPref();
    }, variant: windows);

    testWidgets('显式开：鼠标横拖顶栏也能关', (WidgetTester tester) async {
      await source.setEnableSwipeToClose(true);
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));
      await dragHorizontally(
        tester,
        tester.getCenter(find.byKey(headerKey)),
        kind: PointerDeviceKind.mouse,
      );
      expect(dismissed, isTrue);
      await resetPref();
    }, variant: windows);
  });

  group('SwipeDismissWrapper.touchOnly', () {
    Widget wrapper({required VoidCallback onDismiss}) {
      return buildTestApp(
        Center(
          child: SwipeDismissWrapper(
            touchOnly: true,
            sensitivity: 0.6,
            onDismiss: onDismiss,
            child: const SizedBox(width: 300, height: 100),
          ),
        ),
      );
    }

    for (final PointerDeviceKind kind in <PointerDeviceKind>[
      PointerDeviceKind.touch,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
    ]) {
      testWidgets('$kind 横拖能关', (WidgetTester tester) async {
        bool dismissed = false;
        await tester.pumpWidget(wrapper(onDismiss: () => dismissed = true));
        await dragHorizontally(
          tester,
          tester.getCenter(find.byType(SwipeDismissWrapper)),
          kind: kind,
        );
        expect(dismissed, isTrue);
      });
    }

    testWidgets('鼠标横拖不关', (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(wrapper(onDismiss: () => dismissed = true));
      await dragHorizontally(
        tester,
        tester.getCenter(find.byType(SwipeDismissWrapper)),
        kind: PointerDeviceKind.mouse,
      );
      expect(dismissed, isFalse);
    });

    testWidgets('触控板 pan-zoom 不关', (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(wrapper(onDismiss: () => dismissed = true));
      await panZoomHorizontally(
        tester,
        tester.getCenter(find.byType(SwipeDismissWrapper)),
      );
      expect(dismissed, isFalse);
    });
  });

  group('LookupDismissBarrier.touchSwipeEnabled', () {
    Widget barrier({
      required VoidCallback onSwipeDismiss,
      required bool swipeEnabled,
      bool? touchSwipeEnabled,
    }) {
      return buildTestApp(
        SizedBox.expand(
          child: LookupDismissBarrier(
            onTapDismiss: (_) {},
            onSwipeDismiss: onSwipeDismiss,
            swipeEnabled: swipeEnabled,
            touchSwipeEnabled: touchSwipeEnabled,
            sensitivity: 0.6,
          ),
        ),
      );
    }

    testWidgets('鼠标关、触摸开：触摸横拖关一层，鼠标不关', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(
        barrier(
          onSwipeDismiss: () => dismissed++,
          swipeEnabled: false,
          touchSwipeEnabled: true,
        ),
      );
      final Offset start = tester.getCenter(find.byType(LookupDismissBarrier));
      await dragHorizontally(tester, start, kind: PointerDeviceKind.mouse);
      expect(dismissed, 0);
      await dragHorizontally(tester, start, kind: PointerDeviceKind.touch);
      expect(dismissed, 1);
    });

    testWidgets('未传触摸开关：跟随 swipeEnabled=false，触摸也不关', (
      WidgetTester tester,
    ) async {
      int dismissed = 0;
      await tester.pumpWidget(
        barrier(onSwipeDismiss: () => dismissed++, swipeEnabled: false),
      );
      await dragHorizontally(
        tester,
        tester.getCenter(find.byType(LookupDismissBarrier)),
        kind: PointerDeviceKind.touch,
      );
      expect(dismissed, 0);
    });
  });

  group('popupTopPullDismissAllowed（Windows 覆盖窗顶部下拉）', () {
    test('触摸 / 笔看触摸半边，鼠标看鼠标半边', () {
      for (final String kind in <String>['touch', 'pen']) {
        expect(
          popupTopPullDismissAllowed(
            pointerKind: kind,
            mouseSwipeEnabled: false,
            touchSwipeEnabled: true,
          ),
          isTrue,
        );
        expect(
          popupTopPullDismissAllowed(
            pointerKind: kind,
            mouseSwipeEnabled: false,
            touchSwipeEnabled: false,
          ),
          isFalse,
        );
      }
      expect(
        popupTopPullDismissAllowed(
          pointerKind: 'mouse',
          mouseSwipeEnabled: false,
          touchSwipeEnabled: true,
        ),
        isFalse,
      );
      expect(
        popupTopPullDismissAllowed(
          pointerKind: 'mouse',
          mouseSwipeEnabled: true,
          touchSwipeEnabled: true,
        ),
        isTrue,
      );
    });

    test('缺省 / 认不出的种类按鼠标保守处理', () {
      for (final Object? kind in <Object?>[null, '', 'finger', 3]) {
        expect(
          popupTopPullDismissAllowed(
            pointerKind: kind,
            mouseSwipeEnabled: false,
            touchSwipeEnabled: true,
          ),
          isFalse,
        );
      }
    });

    test('JS 上报时带上指针种类', () {
      expect(
        kPopupTopPullReleaseJs,
        contains("callHandler('topPullReleased', kind)"),
      );
      expect(kPopupTopPullReleaseJs, contains("fire('touch')"));
      expect(
        kPopupTopPullReleaseJs,
        contains("fire(e.pointerType === 'pen' ? 'pen' : 'mouse')"),
      );
    });
  });
}
