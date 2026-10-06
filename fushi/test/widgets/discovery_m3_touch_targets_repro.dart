// Manual review reproduction: run this file explicitly with flutter test.
// Android guidance: touch targets >= 48 x 48 logical pixels; pointer-only
// desktop density is deliberately outside this check.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/utils.dart';

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
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.android,
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
}
