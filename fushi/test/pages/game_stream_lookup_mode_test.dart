import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
  group('gameStreamLookupCaretRight', () {
    test('steps one grapheme without a match', () {
      expect(
        gameStreamLookupCaretRight(
          caret: 2,
          lookupStart: null,
          matchedLength: 0,
          lineLength: 6,
        ),
        3,
      );
    });

    test('jumps past the word just looked up', () {
      expect(
        gameStreamLookupCaretRight(
          caret: 1,
          lookupStart: 1,
          matchedLength: 3,
          lineLength: 8,
        ),
        4,
      );
    });

    test('steps one grapheme once the cursor left the looked-up word', () {
      expect(
        gameStreamLookupCaretRight(
          caret: 2,
          lookupStart: 1,
          matchedLength: 3,
          lineLength: 8,
        ),
        3,
      );
    });

    test('stops at the last grapheme and handles an empty line', () {
      expect(
        gameStreamLookupCaretRight(
          caret: 4,
          lookupStart: 4,
          matchedLength: 5,
          lineLength: 6,
        ),
        5,
      );
      expect(
        gameStreamLookupCaretRight(
          caret: 0,
          lookupStart: null,
          matchedLength: 0,
          lineLength: 0,
        ),
        0,
      );
    });
  });

  testWidgets('Select enters lookup mode; buttons drive the line, B returns', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    await h.press(LogicalKeyboardKey.gameButtonSelect);
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsOneWidget);
    expect(find.text(t.game_stream_lookup_mode), findsOneWidget);

    // A looks up from the cursor (start of the line).
    await h.press(LogicalKeyboardKey.gameButtonA);
    // D-pad right (arrows count as the D-pad in lookup mode) then A.
    await h.press(LogicalKeyboardKey.arrowRight);
    await h.press(LogicalKeyboardKey.gameButtonA);
    // L1/R1 jump to the line's start / end.
    await h.press(LogicalKeyboardKey.gameButtonRight1);
    await h.press(LogicalKeyboardKey.gameButtonA);
    expect(h.lookup.terms, <String>['猫がいる', 'がいる', 'る']);
    expect(h.sent, isEmpty, reason: 'Nothing reaches the game in lookup mode');

    await h.press(LogicalKeyboardKey.gameButtonB);
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsNothing);
    expect(find.text(t.game_stream_game_mode), findsOneWidget);
    await h.press(LogicalKeyboardKey.gameButtonA);
    expect(h.sent.map((GameStreamInputEvent e) => e.button), <String?>[
      'confirm',
      'confirm',
    ]);
  });

  testWidgets('Select also leaves lookup mode', (WidgetTester tester) async {
    final _Harness h = await _Harness.pump(tester);
    await h.press(LogicalKeyboardKey.gameButtonSelect);
    await h.press(LogicalKeyboardKey.gameButtonSelect);
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsNothing);
  });

  testWidgets('entering lookup mode lifts buttons held for the game', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    // R2 holds Control (skip) by default.
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.gameButtonRight2,
      platform: 'android',
    );
    await tester.pump();
    await h.press(LogicalKeyboardKey.gameButtonSelect);
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.gameButtonRight2,
      platform: 'android',
    );
    await tester.pump();
    expect(
      h.sent.map((GameStreamInputEvent e) => '${e.action.name}:${e.key}'),
      <String>['down:Control', 'up:Control'],
    );
  });

  testWidgets('a new line resets the cursor', (WidgetTester tester) async {
    final _Harness h = await _Harness.pump(tester);
    await h.press(LogicalKeyboardKey.gameButtonSelect);
    await h.press(LogicalKeyboardKey.gameButtonRight1);
    h.controller.applyTextEvent(
      GameStreamTextEvent(
        sessionId: 's1',
        lineId: 'line-2',
        text: '犬が来た',
        timestampMs: 2,
      ),
    );
    await tester.pumpAndSettle();
    await h.press(LogicalKeyboardKey.gameButtonA);
    expect(h.lookup.terms, <String>['犬が来た']);
    expect(
      find.byKey(GameStreamPage.lookupModeHintKey),
      findsOneWidget,
      reason: 'The mode stays on for the next line',
    );
  });

  testWidgets('a tapped word enters lookup mode once a controller was used', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _Harness.pump(tester);
    expect(
      find.byKey(GameStreamPage.modeChipKey),
      findsNothing,
      reason: 'Touch-only users never see controller hints',
    );
    await tester.tap(find.byKey(GameStreamPage.transcriptTextKey));
    await tester.pumpAndSettle();
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsNothing);

    // Any controller button reveals the chip; then a tap switches modes.
    await h.press(LogicalKeyboardKey.gameButtonLeft1);
    expect(find.byKey(GameStreamPage.modeChipKey), findsOneWidget);
    await tester.tap(find.byKey(GameStreamPage.transcriptTextKey));
    await tester.pumpAndSettle();
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsOneWidget);

    // The chip switches back.
    await tester.tap(find.byKey(GameStreamPage.modeChipKey));
    await tester.pumpAndSettle();
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsNothing);
  });

  testWidgets('a custom toggle button leaves lookup mode instead of its '
      'lookup role', (WidgetTester tester) async {
    final _Harness h = await _Harness.pump(
      tester,
      profile: const GameStreamButtonProfile().withAction(
        GameStreamPhysicalButton.r3,
        const GameStreamAppAction(GameStreamReceiverAction.toggleLookupMode),
      ),
    );
    await h.press(LogicalKeyboardKey.gameButtonThumbRight);
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsOneWidget);
    await h.press(LogicalKeyboardKey.gameButtonThumbRight);
    expect(find.byKey(GameStreamPage.lookupModeHintKey), findsNothing);
  });
}

class _Harness {
  _Harness(this.tester, this.sent, this.lookup, this.controller);

  final WidgetTester tester;
  final List<GameStreamInputEvent> sent;
  final _Lookup lookup;
  final GameStreamLookupController controller;

  static Future<_Harness> pump(
    WidgetTester tester, {
    GameStreamButtonProfile profile = const GameStreamButtonProfile(),
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final _Lookup lookup = _Lookup();
    final GameStreamLookupController controller =
        GameStreamLookupController(
          lookupClient: lookup,
          streamClient: FushiGameStreamClient(transport: _Transport()),
          clientId: 'c1',
        )..applyTextEvent(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'line-1',
            text: '猫がいる',
            timestampMs: 1,
          ),
        );
    addTearDown(controller.dispose);
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );
    addTearDown(composer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          lookupController: controller,
          buttonProfile: profile,
          videoPlaceholder: const Text('frame'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return _Harness(tester, sent, lookup, controller);
  }

  Future<void> press(LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(key, platform: 'android');
    await tester.sendKeyUpEvent(key, platform: 'android');
    await tester.pumpAndSettle();
  }
}

class _Lookup implements GameStreamDictionaryLookup {
  final List<String> terms = <String>[];

  @override
  DictionaryPopupResourceSource? get popupResources => null;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    terms.add(term);
    return null;
  }
}

class _Transport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => const GameStreamPostResult(json: null);
}
