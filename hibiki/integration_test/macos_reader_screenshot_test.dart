import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show hibikiMaterialNavKey;

import 'helpers/library_fixture.dart';

/// macOS-only visual capture of the reader inside the default-auto MD3 shell.
/// Seeds a fresh paginated EPUB, opens it, waits for the WebView
/// content, then grabs the engine framebuffer (RepaintBoundary.toImage) so the
/// shot works even when the OS window is parked on a non-active Space.
///
///   flutter drive --driver=test_driver/integration_test_screenshots.dart \
///       --target=integration_test/macos_reader_screenshot_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS reader renders inside the default-auto MD3 shell',
      (tester) async {
    app.main();
    // Same as the sibling macOS harnesses: swallow the app-background
    // UpdateChecker network errors (this build Mac has no GitHub reachability,
    // so those unawaited requests throw into the integration_test zone and
    // would trip the binding pending-exception assert). Normal offline
    // degradation in production, unrelated to what this harness verifies.
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      debugPrint('[macos_reader] swallowed async error: $error');
      return true;
    };
    bool homeReady = false;
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(hibikiMaterialNavKey).evaluate().isNotEmpty) {
        homeReady = true;
        break;
      }
    }
    expect(homeReady, isTrue, reason: 'MD3 home shell within 90s');
    await tester.pump(const Duration(seconds: 2));

    // The books tab is a lazily-built keep-alive tab and the home shell boots
    // on the dashboard tab, so the shelf (and its `book_entry_*` cards) is not
    // in the tree until the tab is selected; select it BEFORE seeding so the
    // fixture's shelf-visibility poll can actually see the card.
    await showBooksTab(tester);

    // develop: book identity is a name-derived String key (not an int id);
    // seedReaderBook returns the bookKey and mediaIdentifierFor takes a String.
    final String bookKey = await seedReaderBook(tester);

    // Open the seeded book through the same production call a shelf-card tap
    // makes (appModel.openMedia). Mirrors abe553a5c: a populated shelf may
    // sort a just-imported fixture outside the viewport, so the exact card
    // widget is not required for this pixel-capture harness.
    await openBookViaProductionPath(tester, bookKey);
    await tester.pump(const Duration(seconds: 3));

    const Key webViewKey = ValueKey<String>('hoshi_webview');
    for (int i = 0; i < 60 && find.byKey(webViewKey).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byKey(webViewKey), findsOneWidget, reason: 'reader WebView');

    const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
    for (int i = 0;
        i < 120 && find.byKey(contentReadyKey).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // Give the WebView a moment to paint the first page even if the ready marker
    // is already present.
    await tester.pump(const Duration(seconds: 2));

    await _captureLargestBoundary(
        tester, '${Directory.systemTemp.path}/macos_reader.png');
    debugPrint('[test] captured macos_reader');
  });
}

Future<void> _captureLargestBoundary(WidgetTester tester, String path) async {
  const double maxDim = 5000;
  RenderRepaintBoundary? best;
  double bestArea = 0;
  for (final Element e in find.byType(RepaintBoundary).evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is RenderRepaintBoundary && ro.hasSize) {
      final Size s = ro.size;
      if (s.width > maxDim || s.height > maxDim || s.height < 100) continue;
      final double area = s.width * s.height;
      if (area > bestArea) {
        bestArea = area;
        best = ro;
      }
    }
  }
  if (best == null) {
    debugPrint('[test] SCREENSHOT_RESULT=no-boundary');
    return;
  }
  final ui.Image image = await best.toImage(pixelRatio: 1.0);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) return;
  final File f = await File(path).create(recursive: true);
  f.writeAsBytesSync(png.buffer.asUint8List());
  debugPrint('[test] SCREENSHOT_RESULT=ok size=${best.size} path=$path');
}
