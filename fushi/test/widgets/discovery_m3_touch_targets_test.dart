// HBK-AUDIT-020 regression: on touch platforms the discovery search field keeps
// its 40-tall capsule look but its hit / semantics region is >= 48 (Android
// guidance); pointer-only desktop density stays at the compact 40.
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/utils.dart';

Future<void> _pumpHeader(
  WidgetTester tester, {
  required TargetPlatform platform,
  required TextEditingController controller,
  required FocusNode focus,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          platform: platform,
          splashFactory: NoSplash.splashFactory,
        ),
        home: Scaffold(
          body: Center(
            child: DiscoveryHeaderControls(
              sources: const <DiscoverySourceOption>[
                DiscoverySourceOption(id: 'source', label: 'Source'),
              ],
              selectedSourceId: kDiscoveryAllSourcesId,
              onSourceSelected: (String _) {},
              searchController: controller,
              searchFocusNode: focus,
              searchHintText: 'Search books',
              onSearchSubmitted: (String _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Android discovery search and source controls meet touch targets',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final TextEditingController controller = TextEditingController(
        text: 'book',
      );
      final FocusNode focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await _pumpHeader(
          tester,
          platform: TargetPlatform.android,
          controller: controller,
          focus: focus,
        );
        expect(tester.takeException(), isNull);
        final Finder clear = find.byKey(
          const ValueKey<String>('discovery_search_clear'),
        );
        expect(clear, findsOneWidget);
        // Check the semantic hit regions, not the painted icon dimensions.
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    },
  );
  testWidgets(
    'touch margin around the 40-tall capsule still focuses the field',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final TextEditingController controller = TextEditingController();
      final FocusNode focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await _pumpHeader(
        tester,
        platform: TargetPlatform.android,
        controller: controller,
        focus: focus,
      );
      final Rect field = tester.getRect(
        find.byKey(const ValueKey<String>('discovery_search_field')),
      );
      // The painted capsule keeps the compact toolbar height.
      expect(field.height, kFushiSearchFieldHeight);
      expect(focus.hasFocus, isFalse);
      // A tap in the reserved margin just above the capsule lands on the field.
      await tester.tapAt(field.topCenter - const Offset(0, 2));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      // The bottom margin is symmetric: Size.contains excludes the bottom edge,
      // so the forwarded point must land strictly inside the capsule.
      focus.unfocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.tapAt(field.bottomCenter + const Offset(0, 2));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop pointer density keeps the compact 40-tall field', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final TextEditingController controller = TextEditingController();
    final FocusNode focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await _pumpHeader(
      tester,
      platform: TargetPlatform.windows,
      controller: controller,
      focus: focus,
    );
    final Finder field = find.byKey(
      const ValueKey<String>('discovery_search_field'),
    );
    expect(tester.getSize(field).height, kFushiSearchFieldHeight);
    expect(
      find.ancestor(of: field, matching: find.byType(FushiTouchTargetPadding)),
      findsOneWidget,
    );
    // No extra layout space is reserved for a precise pointer.
    expect(
      tester
          .getSize(
            find.ancestor(
              of: field,
              matching: find.byType(FushiTouchTargetPadding),
            ),
          )
          .height,
      kFushiSearchFieldHeight,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 2026-10-24：清除 / 粘贴钮外观 26，以前在语义树里根本不出现（外层多包的
  // Tooltip + Semantics 把节点弄丢了），这条守卫等于空过；露出来后实测命中区
  // 只有 26×26。现在每枚各占一列 48 宽、不互相覆盖，竖向借搜索框外扩的触控
  // 带撑到 48，胶囊高度与图标外观不变。
  testWidgets(
    'Android search suffix actions each own a 48x48 target reachable from the margin',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final TextEditingController controller = TextEditingController(
        text: 'book',
      );
      final FocusNode focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await _pumpHeader(
        tester,
        platform: TargetPlatform.android,
        controller: controller,
        focus: focus,
      );
      final Finder fieldFinder = find.byKey(
        const ValueKey<String>('discovery_search_field'),
      );
      final Rect field = tester.getRect(fieldFinder);
      expect(field.height, kFushiSearchFieldHeight, reason: '胶囊高度不变');
      final List<Element> buttons = find
          .descendant(of: fieldFinder, matching: find.byType(IconButton))
          .evaluate()
          .toList();
      expect(buttons, hasLength(2), reason: '清除 + 粘贴');
      Rect? previous;
      for (final Element button in buttons) {
        final RenderBox box = button.renderObject! as RenderBox;
        final Rect rect = box.localToGlobal(Offset.zero) & box.size;
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        // 图标外观仍是紧凑尺寸。
        final Rect icon = tester.getRect(
          find.descendant(
            of: find.byWidget(button.widget),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.width, lessThan(24));
        if (previous != null) {
          expect(rect.overlaps(previous), isFalse, reason: '并排的两枚命中区不能互相覆盖');
        }
        previous = rect;
        // 胶囊上下外扩边距里的触点落到这枚按钮上。
        for (final Offset point in <Offset>[
          Offset(rect.center.dx, field.top - 2),
          Offset(rect.center.dx, field.bottom + 2),
        ]) {
          final HitTestResult hit = tester.hitTestOnBinding(point);
          expect(
            hit.path.any((e) => e.target == box),
            isTrue,
            reason: '$point 应命中 ${(button.widget as IconButton).tooltip}',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
