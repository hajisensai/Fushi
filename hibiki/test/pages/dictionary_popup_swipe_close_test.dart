import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

import '../widgets/widget_test_helpers.dart';

/// TODO-406/407 守卫：查词弹窗"滑动关闭"边界与"X 关闭"按钮。
///
/// 用 result==null 让弹窗 body 走占位分支（不实例化平台视图 WebView），既能稳定
/// 在 widget 测试里 pump，又保留与生产一致的"body 与可拖顶栏分层"结构。
void main() {
  const Key headerKey = Key('test-popup-header');
  const Key bodyAnchorKey = Key('test-popup-body-anchor');

  Widget popup({
    required VoidCallback onDismiss,
    VoidCallback? onClose,
    bool enableSwipeToClose = true,
  }) {
    return buildTestApp(
      Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            enableSwipeToClose: enableSwipeToClose,
            onClose: onClose,
            // header 给一个明确尺寸的盒子，模拟 reader/video 顶栏；body 占位区放一个
            // 带 key 的锚点，方便手势从"正文区"起手。
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
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );
  }

  // 默认灵敏度 0.6 → 阈值 ≈ 94px；水平拖 240px 必越阈值。
  Future<void> dragHorizontally(WidgetTester tester, Offset start) async {
    final TestGesture gesture = await tester.startGesture(start);
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets(
    'TODO-406: horizontal drag starting on the body does NOT dismiss',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      // 从 body 占位区中心起手水平拖动过阈值——body 不在 swipe 的 Listener 子树内，
      // 不应触发关闭（消除"WebView 正文框选误触滑动关闭"）。
      final Offset bodyCenter = tester.getCenter(find.byKey(bodyAnchorKey));

      // 判别力守卫：body 起手点必须落在 SwipeDismissWrapper（仅裹顶栏）矩形之外，
      // 否则本用例没有意义（手势其实落在了可滑区）。
      final Rect swipeRect = tester.getRect(find.byType(SwipeDismissWrapper));
      expect(swipeRect.contains(bodyCenter), isFalse,
          reason: 'body 起手点须在可滑顶栏区域之外，本用例才有判别力');

      await dragHorizontally(tester, bodyCenter);

      expect(dismissed, isFalse, reason: '正文区起手的水平拖动不得触发滑动关闭');
    },
  );

  testWidgets(
    'TODO-406: horizontal drag on the header DOES dismiss (swipe preserved)',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      final Offset headerCenter = tester.getCenter(find.byKey(headerKey));
      await dragHorizontally(tester, headerCenter);

      expect(dismissed, isTrue, reason: 'header（可拖区）的水平滑动应保留滑动关闭');
    },
  );

  testWidgets('TODO-407①: tapping the X routes through onDismiss', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    await tester.pumpWidget(
      popup(onDismiss: () {}, onClose: () => closed = true),
    );

    // 顶栏右端的 X 关闭按钮。
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, isTrue, reason: 'X 必须调用 onClose（各表面绑定到关闭汇聚点）');
  });

  testWidgets(
    'TODO-485: nested back button remains available when swipe is disabled',
    (WidgetTester tester) async {
      bool backed = false;
      await tester.pumpWidget(
        buildTestApp(
          Center(
            child: SizedBox(
              width: 320,
              height: 360,
              child: DictionaryPopupLayer(
                result: null,
                isSearching: false,
                webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
                enableSwipeToClose: false,
                swipeDismissible: true,
                onBack: () => backed = true,
                onDismiss: () {},
                onTextSelected: (text, rect) {},
                onLinkClick: (query, rect) {},
                onMineEntry: (fields) async => const MinePopupResult(),
                onDuplicateCheck: (expression, reading) async => false,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SwipeDismissWrapper), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(backed, isTrue, reason: '子层返回按钮必须独立于滑动关闭开关可用');
    },
  );

  testWidgets(
    'TODO-407②: enableSwipeToClose=false drops the SwipeDismissWrapper on the '
    'top bar',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        popup(onDismiss: () {}, enableSwipeToClose: false),
      );
      // 平台/偏好禁用滑关时不挂 SwipeDismissWrapper（顶栏只剩 X 兜底）。
      expect(find.byType(SwipeDismissWrapper), findsNothing);
    },
  );

  testWidgets(
    'TODO-407②: enableSwipeToClose=true mounts the SwipeDismissWrapper',
    (WidgetTester tester) async {
      await tester
          .pumpWidget(popup(onDismiss: () {}, enableSwipeToClose: true));
      expect(find.byType(SwipeDismissWrapper), findsOneWidget);
    },
  );

  group('TODO-407②: defaultSwipeToClose platform truth table', () {
    test('desktop Windows/Linux default to false (no swipe-to-close)', () {
      expect(
          ReaderSettings.defaultSwipeToClose(TargetPlatform.windows), isFalse);
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.linux), isFalse);
    });

    test('touch platforms (macOS/iOS/Android) default to true', () {
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.macOS), isTrue);
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.iOS), isTrue);
      expect(
          ReaderSettings.defaultSwipeToClose(TargetPlatform.android), isTrue);
    });

    test('the only false branch is exactly windows||linux', () {
      for (final TargetPlatform p in TargetPlatform.values) {
        final bool expected =
            !(p == TargetPlatform.windows || p == TargetPlatform.linux);
        expect(ReaderSettings.defaultSwipeToClose(p), expected,
            reason: '平台 $p 的默认滑关开关应为 $expected');
      }
    });
  });
}
