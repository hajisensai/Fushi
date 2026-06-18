import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'continuous reader mouse-drag scrolls from body text in horizontal and vertical modes',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[mouse-drag] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: 'Home must render');
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(appModel.isInitialised, isTrue);

        final Map<String, dynamic> horizontal = await _runCase(
          tester: tester,
          appModel: appModel,
          writingMode: 'horizontal-tb',
          dragDx: 0,
          dragDy: -180,
        );
        debugPrint('[mouse-drag][horizontal] $horizontal');
        expect(horizontal['characterHit'], isTrue,
            reason: 'probe must start over real reader body text');
        expect((horizontal['deltaY'] as num).abs(), greaterThan(20),
            reason: 'horizontal continuous drag over text must scroll Y');
        expect(horizontal['selectionText'], '',
            reason: 'claimed reader drag must not leave native selection');

        final Map<String, dynamic> vertical = await _runCase(
          tester: tester,
          appModel: appModel,
          writingMode: 'vertical-rl',
          dragDx: -180,
          dragDy: 0,
        );
        debugPrint('[mouse-drag][vertical] $vertical');
        expect(vertical['characterHit'], isTrue,
            reason: 'probe must start over real reader body text');
        expect((vertical['deltaX'] as num).abs(), greaterThan(20),
            reason: 'vertical continuous drag over text must scroll X');
        expect(vertical['selectionText'], '',
            reason: 'claimed reader drag must not leave native selection');

        await takeScreenshot(binding, 'reader_mouse_drag_scroll_verified');
        assertStrictErrors(errors);
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

Future<Map<String, dynamic>> _runCase({
  required WidgetTester tester,
  required AppModel appModel,
  required String writingMode,
  required int dragDx,
  required int dragDy,
}) async {
  await appModel.database.setPref('src:reader_ttu:ttu_view_mode', 'continuous');
  await appModel.database
      .setPref('src:reader_ttu:ttu_writing_mode', writingMode);
  await ReaderHibikiSource.readerSettings?.refreshFromDb();

  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: EpubGenerator().generate(),
    fileName: 'mouse_drag_$writingMode.epub',
  );

  final ReaderHibikiSource source = ReaderHibikiSource.instance;
  final MediaItem item = MediaItem(
    mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
    title: bookKey,
    mediaTypeIdentifier: source.mediaType.uniqueKey,
    mediaSourceIdentifier: source.uniqueKey,
    position: 0,
    duration: 0,
    canDelete: false,
    canEdit: true,
  );

  final NavigatorState navigator =
      tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(navigator.push<void>(MaterialPageRoute<void>(
    builder: (_) => source.buildLaunchPage(item: item),
  )));
  await tester.pump(const Duration(seconds: 3));

  const Key webViewKey = ValueKey<String>('hoshi_webview');
  for (int i = 0; i < 80 && find.byKey(webViewKey).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(find.byKey(webViewKey), findsOneWidget,
      reason: '$writingMode reader WebView must mount');

  const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
  bool contentReady = false;
  for (int i = 0; i < 140; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
      contentReady = true;
      break;
    }
  }
  expect(contentReady, isTrue,
      reason: '$writingMode reader content must become ready');
  await tester.pump(const Duration(seconds: 3));

  final Future<dynamic> Function(String source)? eval =
      ReaderHibikiPage.debugEvaluateJavascript;
  expect(eval, isNotNull, reason: 'Reader debug JS hook must be set');

  final dynamic raw = await eval!(_dragProbeJs(dragDx: dragDx, dragDy: dragDy));
  final Map<String, dynamic> result =
      jsonDecode(raw as String) as Map<String, dynamic>;

  navigator.pop();
  await tester.pump(const Duration(seconds: 2));
  for (int i = 0;
      i < 40 && ReaderHibikiPage.debugEvaluateJavascript != null;
      i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }

  return result;
}

String _dragProbeJs({required int dragDx, required int dragDy}) => '''
(function() {
  function visibleTextPoint() {
    var accept = NodeFilter.FILTER_ACCEPT;
    var reject = NodeFilter.FILTER_REJECT;
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node) {
        if (!node.nodeValue || !node.nodeValue.trim()) return reject;
        var parent = node.parentElement;
        if (!parent || parent.closest('rt, rp, script, style')) return reject;
        var range = document.createRange();
        range.selectNodeContents(node);
        var rects = range.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var r = rects[i];
          if (r.width > 4 && r.height > 4 &&
              r.right > 0 && r.bottom > 0 &&
              r.left < window.innerWidth && r.top < window.innerHeight) {
            return accept;
          }
        }
        return reject;
      }
    });
    var node = walker.nextNode();
    while (node) {
      var range = document.createRange();
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 4 && r.height > 4 &&
            r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          return {
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2)),
            text: node.nodeValue.trim().substring(0, 24)
          };
        }
      }
      node = walker.nextNode();
    }
    return null;
  }

  function pointer(type, x, y, buttons, button) {
    var init = {
      bubbles: true,
      cancelable: true,
      pointerType: 'mouse',
      pointerId: 495498,
      isPrimary: true,
      button: button,
      buttons: buttons,
      clientX: x,
      clientY: y
    };
    try {
      return new PointerEvent(type, init);
    } catch (err) {
      var ev = new MouseEvent(type, init);
      Object.defineProperty(ev, 'pointerType', {value: 'mouse'});
      Object.defineProperty(ev, 'pointerId', {value: 495498});
      return ev;
    }
  }

  var point = visibleTextPoint();
  if (!point) return JSON.stringify({ok: false, error: 'no visible text'});
  var characterHit = !!(window.hoshiSelection &&
    window.hoshiSelection.getCharacterAtPoint &&
    window.hoshiSelection.getCharacterAtPoint(point.x, point.y));
  var beforeX = window.scrollX;
  var beforeY = window.scrollY;
  var target = document.elementFromPoint(point.x, point.y) || document.body;
  target.dispatchEvent(pointer('pointerdown', point.x, point.y, 1, 0));
  document.dispatchEvent(pointer(
    'pointermove',
    point.x + $dragDx,
    point.y + $dragDy,
    1,
    0
  ));
  document.dispatchEvent(pointer(
    'pointerup',
    point.x + $dragDx,
    point.y + $dragDy,
    0,
    0
  ));
  var selectionText = window.getSelection ? String(window.getSelection()) : '';
  return JSON.stringify({
    ok: true,
    writingMode: window.getComputedStyle(document.body).writingMode,
    sample: point.text,
    characterHit: characterHit,
    beforeX: beforeX,
    afterX: window.scrollX,
    deltaX: window.scrollX - beforeX,
    beforeY: beforeY,
    afterY: window.scrollY,
    deltaY: window.scrollY - beforeY,
    selectionText: selectionText
  });
})()
''';
