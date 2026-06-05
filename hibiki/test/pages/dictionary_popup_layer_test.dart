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
}
