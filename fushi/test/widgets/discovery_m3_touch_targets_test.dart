// HBK-AUDIT-020 regression: on touch platforms the discovery search field keeps
// its 40-tall capsule look but its hit / semantics region is >= 48 (Android
// guidance); pointer-only desktop density stays at the compact 40.
import 'package:flutter/material.dart';
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
}
