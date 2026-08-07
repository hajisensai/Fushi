import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart'
    show hibikiMaterialNavKey;

import 'helpers/library_fixture.dart';

/// TODO-1375 symptom (2): reader re-layout when the viewport grows to
/// fullscreen size. A parked FUSHI_TEST_HIDDEN window cannot enter NATIVE
/// fullscreen, so we drive tester.view.physicalSize to a fullscreen-sized
/// viewport -- exactly the MediaQuery size change a real fullscreen delivers to
/// the reader, which runs didChangeMetrics -> _syncPageSize (re-paginate) and
/// didChangeDependencies (inset re-feed, TODO-1375). Captures the windowed vs
/// fullscreen-sized reader layout for review. Lives in its own file because
/// each integration_test app.main() needs a fresh process (two testWidgets both
/// calling app.main() in one file leaves the second without a fresh home shell).
///
/// PlatformDispatcher.onError swallows the app-background UpdateChecker network
/// errors (no GitHub reachability on this build Mac). Screenshots come off the
/// engine framebuffer (RepaintBoundary.toImage), bypassing Spaces/TCC.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final String tmp = Directory.systemTemp.path;

  testWidgets('TODO-1375 reader re-layout on a fullscreen-sized viewport',
      (WidgetTester tester) async {
    app.main();
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      debugPrint('[t1375b] swallowed async error: $error');
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

    // Books is a lazily-built keep-alive tab and boot lands on the dashboard
    // tab: without selecting it the shelf (and its `book_entry_*` cards) is
    // never in the tree, so seedReaderBook's visibility poll cannot succeed.
    await showBooksTab(tester);

    final String bookKey = await seedReaderBook(tester);
    // Open via the same production call a shelf-card tap makes (openMedia);
    // decoupled from shelf viewport/sorting exactly like abe553a5c.
    await openBookViaProductionPath(tester, bookKey);
    await tester.pump(const Duration(seconds: 3));

    const Key webViewKey = ValueKey<String>('hoshi_webview');
    for (int i = 0; i < 60 && find.byKey(webViewKey).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byKey(webViewKey), findsOneWidget, reason: 'reader WebView');
    const Key readyKey = ValueKey<String>('hoshi_content_ready');
    for (int i = 0; i < 120 && find.byKey(readyKey).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 2));
    await _cap(tester, '$tmp/t1375_r1_windowed.png');

    final Size orig = tester.view.physicalSize;
    addTearDown(tester.view.resetPhysicalSize);
    tester.view.physicalSize = const Size(2560, 1600);
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    debugPrint('[t1375b] resized $orig -> ${tester.view.physicalSize}');
    await _cap(tester, '$tmp/t1375_r2_fullscreen.png');
    debugPrint('[t1375b] DONE');
  });
}

Future<void> _cap(WidgetTester tester, String path) async {
  const double maxDim = 6000;
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
    debugPrint('[t1375b] SCREENSHOT=no-boundary path=$path');
    return;
  }
  final ui.Image image = await best.toImage(pixelRatio: 1.0);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) return;
  final File f = await File(path).create(recursive: true);
  f.writeAsBytesSync(png.buffer.asUint8List());
  debugPrint('[t1375b] SCREENSHOT=ok size=${best.size} path=$path');
}
