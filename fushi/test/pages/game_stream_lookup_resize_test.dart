import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// iPad landscape window from the report (logical points).
const Size _ipadLandscape = Size(1389, 970);

void main() {
  group('lookup rail resize (feedback VpZ7sr2qU8)', () {
    testWidgets('dragging the line edge grows the area and zooms the text, '
        'and persists once on release', (WidgetTester tester) async {
      final List<GameStreamLookupLayout> saved = <GameStreamLookupLayout>[];
      await _pumpPage(tester, onChanged: saved.add);
      expect(_lineHeight(tester), GameStreamLookupLayout.defaultLineHeight);
      expect(_lineFontSize(tester), GameStreamLookupLayout.baseFontSize);

      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      expect(_lineHeight(tester), 280);
      expect(_lineFontSize(tester), 28);
      expect(saved, const <GameStreamLookupLayout>[
        GameStreamLookupLayout(lineHeight: 280),
      ]);
    });

    testWidgets('line area stops at its minimum and maximum', (
      WidgetTester tester,
    ) async {
      final List<GameStreamLookupLayout> saved = <GameStreamLookupLayout>[];
      await _pumpPage(tester, onChanged: saved.add);

      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, 800),
      );
      await tester.pumpAndSettle();
      expect(_lineHeight(tester), GameStreamLookupLayout.maxLineHeight);
      expect(_lineFontSize(tester), GameStreamLookupLayout.maxFontSize);

      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(_lineHeight(tester), GameStreamLookupLayout.minLineHeight);
      expect(_lineFontSize(tester), GameStreamLookupLayout.minFontSize);
      expect(saved.last.lineHeight, GameStreamLookupLayout.minLineHeight);
    });

    testWidgets('line area leaves the dictionary its minimum height', (
      WidgetTester tester,
    ) async {
      // A short window: the rail is 400 tall, so the limit is 400 - 120.
      await _pumpPage(tester, size: const Size(1000, 400));
      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      expect(
        _lineHeight(tester),
        400 - GameStreamLookupLayout.minDictionaryHeight,
      );
    });

    testWidgets('dragging the rail edge widens the side panel within limits', (
      WidgetTester tester,
    ) async {
      final List<GameStreamLookupLayout> saved = <GameStreamLookupLayout>[];
      await _pumpPage(tester, onChanged: saved.add);
      expect(_railWidth(tester), GameStreamLookupLayout.defaultRailWidth);

      await tester.drag(
        find.byKey(GameStreamPage.railResizeHandleKey),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 460);
      expect(saved.last.railWidth, 460);

      await tester.drag(
        find.byKey(GameStreamPage.railResizeHandleKey),
        const Offset(-900, 0),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), GameStreamLookupLayout.maxRailWidth);

      await tester.drag(
        find.byKey(GameStreamPage.railResizeHandleKey),
        const Offset(900, 0),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), GameStreamLookupLayout.minRailWidth);
      expect(saved.last.railWidth, GameStreamLookupLayout.minRailWidth);
    });

    testWidgets('rail leaves the video its minimum width', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester, size: const Size(800, 600));
      await tester.drag(
        find.byKey(GameStreamPage.railResizeHandleKey),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(GameStreamPage.videoKey)).width,
        GameStreamLookupLayout.minVideoWidth,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stored layout is restored when the page opens', (
      WidgetTester tester,
    ) async {
      await _pumpPage(
        tester,
        layout: const GameStreamLookupLayout(railWidth: 520, lineHeight: 210),
      );
      expect(_railWidth(tester), 520);
      expect(_lineHeight(tester), 210);
      expect(_lineFontSize(tester), 21);
    });

    testWidgets('handles have 48dp touch targets and resize cursors', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester);
      final Finder line = find.byKey(GameStreamPage.lineResizeHandleKey);
      final Finder rail = find.byKey(GameStreamPage.railResizeHandleKey);
      expect(tester.getSize(line).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(rail).width, greaterThanOrEqualTo(48));

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(line));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeUpDown,
      );
      await mouse.moveTo(tester.getCenter(rail));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeLeftRight,
      );
    });

    testWidgets('mouse drag on the line edge resizes like touch', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester);
      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, 60),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(_lineHeight(tester), 200);
    });

    testWidgets('a focused handle resizes with arrow keys', (
      WidgetTester tester,
    ) async {
      final List<GameStreamLookupLayout> saved = <GameStreamLookupLayout>[];
      await _pumpPage(tester, onChanged: saved.add);
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameStreamPage.lineResizeHandleKey),
            matching: find.byType(MouseRegion),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _lineHeight(tester),
        GameStreamLookupLayout.defaultLineHeight +
            GameStreamLookupLayout.keyboardStep,
      );

      Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameStreamPage.railResizeHandleKey),
            matching: find.byType(MouseRegion),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      // Left moves the edge left: a wider rail.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        _railWidth(tester),
        GameStreamLookupLayout.defaultRailWidth +
            GameStreamLookupLayout.keyboardStep,
      );
      expect(saved.length, 2);
    });

    testWidgets('portrait layout keeps the line resize handle', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester, size: const Size(600, 900));
      expect(find.byKey(GameStreamPage.railResizeHandleKey), findsNothing);
      await tester.drag(
        find.byKey(GameStreamPage.lineResizeHandleKey),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(_lineHeight(tester), 180);
    });
  });

  group('GameStreamLookupLayout', () {
    test('json round-trips and clamps hostile values', () {
      const GameStreamLookupLayout layout = GameStreamLookupLayout(
        railWidth: 444,
        lineHeight: 222,
      );
      expect(GameStreamLookupLayout.fromJson(layout.toJson()), layout);
      expect(
        GameStreamLookupLayout.fromJson(const <String, Object?>{
          'railWidth': 99999,
          'lineHeight': -5,
        }),
        const GameStreamLookupLayout(
          railWidth: GameStreamLookupLayout.maxRailWidth,
          lineHeight: GameStreamLookupLayout.minLineHeight,
        ),
      );
      expect(
        GameStreamLookupLayout.fromJson(const <String, Object?>{
          'railWidth': 'wide',
        }),
        const GameStreamLookupLayout(),
      );
      expect(
        GameStreamLookupLayout.fromJson('garbage'),
        const GameStreamLookupLayout(),
      );
    });

    test('persists through preferences and stays on this device', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      expect(prefs.gameStreamLookupLayout, const GameStreamLookupLayout());
      const GameStreamLookupLayout layout = GameStreamLookupLayout(
        railWidth: 500,
        lineHeight: 260,
      );
      await prefs.setGameStreamLookupLayout(layout);
      prefs.dispose();

      final PreferencesRepository reopened = PreferencesRepository(db);
      await reopened.loadFromDb();
      addTearDown(reopened.dispose);
      expect(reopened.gameStreamLookupLayout, layout);
      expect(
        SyncRepository.deviceLocalPrefKeys,
        contains(kGameStreamLookupLayoutPrefKey),
      );
    });
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  Size size = _ipadLandscape,
  GameStreamLookupLayout layout = const GameStreamLookupLayout(),
  ValueChanged<GameStreamLookupLayout>? onChanged,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final GameStreamLookupController controller =
      GameStreamLookupController(
        lookupClient: _Lookup(),
        streamClient: FushiGameStreamClient(transport: _Transport()),
        clientId: 'c1',
      )..applyTextEvent(
        GameStreamTextEvent(
          sessionId: 's1',
          lineId: 'line-1',
          text: 'みたいなもの',
          timestampMs: 1,
        ),
      );
  addTearDown(controller.dispose);
  final GameStreamInputComposer composer = GameStreamInputComposer(
    sessionId: 's1',
    clientId: 'c1',
    sender: (_) async => null,
  );
  addTearDown(composer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: GameStreamPage(
        sessionId: 's1',
        clientId: 'c1',
        inputComposer: composer,
        lookupController: controller,
        videoPlaceholder: const Text('frame'),
        lookupLayout: layout,
        onLookupLayoutChanged: onChanged,
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

double _lineHeight(WidgetTester tester) => tester
    .getSize(
      find.ancestor(
        of: find.byKey(GameStreamPage.transcriptKey),
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .height;

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(GameStreamPage.dictionaryKey)).width;

double? _lineFontSize(WidgetTester tester) {
  final InlineSpan span = tester
      .widget<RichText>(find.byKey(GameStreamPage.transcriptTextKey))
      .text;
  double? size = span.style?.fontSize;
  span.visitChildren((InlineSpan child) {
    size ??= child.style?.fontSize;
    return size == null;
  });
  return size;
}

class _Lookup implements GameStreamDictionaryLookup {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;
}

class _Transport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => const GameStreamPostResult(json: null);
}
