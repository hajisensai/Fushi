import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

void main() {
  // Mirrors the real bookshelf card: a margin (HibikiCard) wrapping an
  // AspectRatio whose ratio equals the grid cell ratio. The grid cell hands
  // down tight constraints, so the bare card must fill (cell - margin).
  // Wrapping the card in BookDragTarget (non-selection mode) must not change
  // that laid-out size; if its Stack used StackFit.loose the AspectRatio would
  // recompute its height from width and the card would shrink vertically,
  // producing the size mismatch between selection and non-selection modes.
  const double aspectRatio = 0.65;
  const double cellW = 200;
  const double cellH = cellW / aspectRatio;
  const double margin = 6;

  Future<Size> measureContent(
    WidgetTester tester, {
    required bool wrapped,
  }) async {
    final Key contentKey = GlobalKey();
    final Widget child = Padding(
      padding: const EdgeInsets.all(margin),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: SizedBox.expand(key: contentKey),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: cellW,
              height: cellH,
              child: wrapped
                  ? BookDragTarget(
                      bookId: 1,
                      onTagDropped: (_) {},
                      child: child,
                    )
                  : child,
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byKey(contentKey));
  }

  testWidgets(
    'BookDragTarget keeps card size identical to a bare card under tight '
    'constraints',
    (WidgetTester tester) async {
      final Size bare = await measureContent(tester, wrapped: false);
      final Size wrapped = await measureContent(tester, wrapped: true);
      expect(wrapped, bare);
    },
  );
}
