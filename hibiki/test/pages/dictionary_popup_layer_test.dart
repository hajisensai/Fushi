import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

import '../widgets/widget_test_helpers.dart';

void main() {
  test('calcPopupPosition stays inside a constrained popup surface', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(2, 2, 1, 1),
      screen: const Size(8, 8),
    );

    expect(popupRect.left, greaterThanOrEqualTo(0));
    expect(popupRect.top, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(8));
    expect(popupRect.bottom, lessThanOrEqualTo(8));
  });

  test('calcPopupPosition keeps desktop popup capped and in bounds', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(730, 520, 20, 20),
      screen: const Size(800, 600),
      maxWidth: 360,
      maxHeight: 480,
    );

    expect(popupRect.width, 360);
    // 高度现在 = availableHeight（受 maxHeight 与屏幕可用空间双重 clamp），不再被
    // 旧的 *0.5 顶死在半屏：480 < (600-余白) 所以取 maxHeight=480。
    expect(popupRect.height, 480);
    expect(popupRect.left, greaterThanOrEqualTo(6));
    expect(popupRect.top, greaterThanOrEqualTo(6));
    expect(popupRect.right, lessThanOrEqualTo(794));
    expect(popupRect.bottom, lessThanOrEqualTo(594));
  });

  test('calcPopupPosition respects bottomReserve', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(100, 500, 20, 20),
      screen: const Size(400, 800),
      bottomReserve: 80,
    );

    expect(popupRect.bottom, lessThanOrEqualTo(800 - 80));
  });

  test('calcPopupPosition survives bottomReserve larger than the surface', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(10, 10, 10, 10),
      screen: const Size(80, 48),
      bottomReserve: 80,
    );

    expect(popupRect.left, greaterThanOrEqualTo(0));
    expect(popupRect.top, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(80));
    expect(popupRect.bottom, lessThanOrEqualTo(48));
  });

  test('dual reserves exceeding screen height do not throw (both modes)', () {
    const Size screen = Size(400, 300);
    const Rect sel = Rect.fromLTWH(180, 140, 30, 30);
    for (final bool vertical in <bool>[false, true]) {
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        topReserve: 250,
        bottomReserve: 250, // 250+250 > 300
        verticalWriting: vertical,
      );
      expect(popup.width, greaterThanOrEqualTo(0));
      expect(popup.height, greaterThanOrEqualTo(0));
      expect(popup.left.isFinite && popup.top.isFinite, isTrue);
    }
  });

  group('calcPopupPosition maxWidth constraint', () {
    const Rect selectionRect = Rect.fromLTWH(400, 300, 40, 24);
    const Size screen = Size(1920, 1080);

    test('small maxWidth caps the popup width to <= maxWidth', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );

      expect(popupRect.width, lessThanOrEqualTo(250));
      expect(popupRect.width, 250);
      expect(popupRect.left, greaterThanOrEqualTo(0));
      expect(popupRect.right, lessThanOrEqualTo(1920));
    });

    test(
        'larger maxWidth yields a wider popup, still bounded by available width',
        () {
      final Rect narrow = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );
      final Rect wide = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 1000,
      );

      expect(wide.width, greaterThan(narrow.width));
      expect(wide.width, 1000);
      expect(wide.width, lessThanOrEqualTo(screen.width));
      expect(wide.right, lessThanOrEqualTo(screen.width));
    });
  });

  group('calcPopupPosition maxHeight constraint (half-screen cap removed)', () {
    // selection 放在靠顶部，留足下方空间，让 height 完全由 maxHeight 决定。
    const Rect selectionRect = Rect.fromLTWH(400, 100, 40, 24);
    const Size screen = Size(1920, 1080);

    test('small maxHeight caps the popup height to <= maxHeight', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 300,
      );

      expect(popupRect.height, 300);
      expect(popupRect.top, greaterThanOrEqualTo(0));
      expect(popupRect.bottom, lessThanOrEqualTo(screen.height));
    });

    test('large maxHeight grows past half-screen (no *0.5 cap)', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 900,
      );

      // 旧实现这里会被 0.5*1080=540 顶死；去掉 *0.5 后真正取到 maxHeight=900。
      expect(popupRect.height, 900);
      expect(popupRect.height, greaterThan(screen.height / 2));
      expect(popupRect.top, greaterThanOrEqualTo(0));
      expect(popupRect.bottom, lessThanOrEqualTo(screen.height));
    });

    test('larger maxHeight yields a taller popup', () {
      final Rect short = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 300,
      );
      final Rect tall = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 700,
      );

      expect(tall.height, greaterThan(short.height));
      expect(tall.height, 700);
    });
  });

  group('calcPopupPosition never covers the selection (BUG-098)', () {
    // selection 在垂直中线偏上：下方空间略大于上方但都装不下整高弹窗。旧实现
    // 走「below」分支后用 top.clamp(maxTop) 把弹窗顶边拉到选区之上 → 盖住选中词。
    test('tight-fit below: popup top stays at/below the selection bottom', () {
      const Rect selectionRect = Rect.fromLTWH(100, 250, 40, 20);
      const Size screen = Size(800, 600);
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 360,
      );

      // 弹窗顶边不得越过选区底边（否则覆盖被查的词）。
      expect(popupRect.top, greaterThanOrEqualTo(selectionRect.bottom));
      // 仍在屏内。
      expect(popupRect.bottom, lessThanOrEqualTo(600));
    });

    test('placed above keeps its bottom at/above the selection top', () {
      // 选区靠近底部：弹窗放上方，底边不得越过选区顶边。
      const Rect selectionRect = Rect.fromLTWH(100, 560, 40, 30);
      const Size screen = Size(800, 600);
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 360,
      );

      expect(popupRect.bottom, lessThanOrEqualTo(selectionRect.top));
      expect(popupRect.top, greaterThanOrEqualTo(0));
    });
  });

  testWidgets('empty popup layer fits a compact surface without overflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 80,
          height: 48,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            onDismiss: () {},
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => false,
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(HibikiPopupSurface), findsOneWidget);
  });

  testWidgets('borderless popup layer still uses shared popup surface', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 240,
          height: 160,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            showBorder: false,
            swipeDismissible: false,
            onDismiss: () {},
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => false,
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);
    expect(find.byType(SwipeDismissWrapper), findsNothing);
    expect(find.byType(HibikiPopupSurface), findsOneWidget);
  });

  group('calcPopupPosition vertical writing avoids the current column', () {
    const Size screen = Size(1000, 800);

    test('vertical-rl prefers the already-read (right) side of the column', () {
      const Rect sel = Rect.fromLTWH(480, 300, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      expect(popup.left, greaterThanOrEqualTo(sel.right),
          reason: '竖排弹窗须在当前列右侧，不压列');
      expect(popup.right, lessThanOrEqualTo(screen.width));
    });

    test('falls to the left side when the right has no room', () {
      const Rect sel = Rect.fromLTWH(960, 300, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      expect(popup.right, lessThanOrEqualTo(sel.left),
          reason: '右侧无空间时弹窗须落在当前列左侧');
      expect(popup.left, greaterThanOrEqualTo(0));
    });

    test('never horizontally overlaps the selection column', () {
      const Rect sel = Rect.fromLTWH(500, 200, 28, 120);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      final bool onRight = popup.left >= sel.right;
      final bool onLeft = popup.right <= sel.left;
      expect(onRight || onLeft, isTrue, reason: '弹窗与当前列不得水平重叠');
    });

    test('stays within vertical reserves in vertical mode', () {
      const Rect sel = Rect.fromLTWH(480, 10, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        topReserve: 100,
        bottomReserve: 120,
        verticalWriting: true,
      );
      expect(popup.top, greaterThanOrEqualTo(100), reason: '竖直方向仍须避让顶部预留');
      expect(popup.bottom, lessThanOrEqualTo(screen.height - 120),
          reason: '竖直方向仍须避让底部预留');
    });

    test('horizontal mode unchanged: still placed above/below selection', () {
      const Rect sel = Rect.fromLTWH(400, 380, 60, 24);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: false,
      );
      final bool below = popup.top >= sel.bottom;
      final bool above = popup.bottom <= sel.top;
      expect(below || above, isTrue, reason: '横排须维持上/下放置，避开当前行');
    });
  });
}
