import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';

void main() {
  final String text = List<String>.generate(
    400,
    (int i) => String.fromCharCode(0x4e00 + i),
  ).join();

  final GlobalKey coordinateKey = GlobalKey();

  Widget subject({
    required ScrollController controller,
    required void Function(String, Rect, int) onLookup,
    SourceLookupHighlight? highlight,
    int initialCharIndex = 0,
    double height = 100,
    String? source,
    ScrollController? outerController,
  }) => MaterialApp(
    home: Scaffold(
      key: coordinateKey,
      body: SingleChildScrollView(
        controller: outerController,
        child: Column(
          children: <Widget>[
            if (outerController != null) const SizedBox(height: 200),
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: BoundedSourceLookupViewport(
                  maxHeight: height,
                  scrollKey: const ValueKey<String>('viewport'),
                  controller: controller,
                  child: SourceLookupTextPanel(
                    text: source ?? text,
                    coordinateSpaceKey: coordinateKey,
                    highlight: highlight,
                    initialCharIndex: initialCharIndex,
                    revealHighlight: true,
                    onLookup: onLookup,
                  ),
                ),
              ),
            ),
            if (outerController != null) const SizedBox(height: 1200),
          ],
        ),
      ),
    ),
  );

  testWidgets('long source scrolls without firing a glyph lookup', (
    tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    int lookups = 0;
    await tester.pumpWidget(
      subject(controller: controller, onLookup: (_, _, _) => lookups++),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('viewport'))).height,
      100,
    );
    expect(controller.position.maxScrollExtent, greaterThan(100));
    await tester.drag(
      find.byKey(const ValueKey<String>('viewport')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(lookups, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short source keeps its natural height', (tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      subject(controller: controller, source: 'short', onLookup: (_, _, _) {}),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('viewport'))).height,
      lessThan(100),
    );
    expect(controller.position.maxScrollExtent, 0);
  });

  testWidgets('initial selection near the end is inside the source viewport', (
    tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      subject(
        controller: controller,
        initialCharIndex: 360,
        onLookup: (_, _, _) {},
      ),
    );
    await tester.pump();
    final Rect viewport = tester.getRect(
      find.byKey(const ValueKey<String>('viewport')),
    );
    final Rect selected = tester.getRect(find.text(text[360]));
    expect(controller.offset, greaterThan(0));
    expect(viewport.contains(selected.topLeft), isTrue);
    expect(
      viewport.contains(selected.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
    );
  });

  testWidgets('scrolled glyph keeps its text index and visible lookup anchor', (
    tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    int? index;
    Rect? anchor;
    String? query;
    await tester.pumpWidget(
      subject(
        controller: controller,
        initialCharIndex: 360,
        onLookup: (String value, Rect rect, int offset) {
          query = value;
          anchor = rect;
          index = offset;
        },
      ),
    );
    await tester.pump();
    await tester.tap(find.text(text[360]));
    expect(index, 360);
    expect(query, text.substring(360));
    final Rect visible = tester.getRect(find.text(text[360]));
    expect(anchor!.topLeft, visible.topLeft);
  });

  testWidgets(
    'changed highlight is revealed without moving an outer scroll view',
    (tester) async {
      final ScrollController controller = ScrollController();
      final ScrollController outer = ScrollController(initialScrollOffset: 100);
      addTearDown(controller.dispose);
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        subject(
          controller: controller,
          outerController: outer,
          onLookup: (_, _, _) {},
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        subject(
          controller: controller,
          outerController: outer,
          highlight: const SourceLookupHighlight(start: 390, length: 2),
          onLookup: (_, _, _) {},
        ),
      );
      await tester.pump();
      final Rect viewport = tester.getRect(
        find.byKey(const ValueKey<String>('viewport')),
      );
      expect(viewport.contains(tester.getCenter(find.text(text[390]))), isTrue);
      expect(outer.offset, 100);
    },
  );
}
