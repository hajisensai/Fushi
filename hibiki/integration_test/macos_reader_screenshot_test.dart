import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart'
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

    // develop: book identity is a name-derived String key (not an int id);
    // seedReaderBook returns the bookKey and mediaIdentifierFor takes a String.
    final String bookKey = await seedReaderBook(tester);
    final String seededKey =
        'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
    final Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
    for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(seededEntry, findsOneWidget, reason: 'seeded book on shelf');

    // macOS-only screenshot harness (manual `flutter drive -d macos`): opens the
    // seeded book only to capture reader pixels — no interaction assertion, and
    // this file is only a visual-capture harness, not an interaction assertion.
    await tester.tap(seededEntry); // itest-tap-allow: macOS pixel-capture only
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
